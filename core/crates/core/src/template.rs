//! Template document model (SPEC §3.2). A template is stored as JSON and owned by
//! the core: the core parses, validates the invariants, and re-serializes it. Geometry
//! is normalized 0..1. Invariants: at most one active background; rects within 0..1.

use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// A template is a named collection of scenes; each scene is a full layout the user
/// can switch to (with a transition) during recording.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Template {
    pub version: u32,
    pub scenes: Vec<Scene>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Scene {
    pub name: String,
    pub canvas: Canvas,
    pub layers: Vec<Layer>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Canvas {
    pub width: u32,
    pub height: u32,
}

/// Normalized rectangle, each component in 0..1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    fn is_normalized(&self) -> bool {
        [self.x, self.y, self.w, self.h].iter().all(|v| *v >= 0.0 && *v <= 1.0)
            && self.w > 0.0
            && self.h > 0.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Shadow {
    #[serde(default)]
    pub radius: f32,
    #[serde(default)]
    pub opacity: f32,
    #[serde(default)]
    pub dy: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Visible {
    #[serde(default)]
    pub start_ms: u64,
    #[serde(default)]
    pub end_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Layer {
    Background(Background),
    Screen(ScreenLayer),
    Camera(CameraLayer),
    Image(ImageLayer),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "lowercase")]
pub enum Background {
    Screen {
        #[serde(default)]
        blur: f32,
        #[serde(default)]
        darken: f32,
    },
    Color {
        color: String,
    },
    Image {
        path: String,
        #[serde(default)]
        fit: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenLayer {
    pub rect: Rect,
    #[serde(default)]
    pub corner_radius: f32,
    #[serde(default)]
    pub shadow: Option<Shadow>,
    /// Which display feeds this layer (SCDisplay id as string). None = primary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub locked: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraLayer {
    pub rect: Rect,
    #[serde(default)]
    pub corner_radius: f32,
    #[serde(default)]
    pub mirror: bool,
    #[serde(default)]
    pub shadow: Option<Shadow>,
    /// Which camera feeds this layer (AVCaptureDevice uniqueID). None = default camera.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    /// Virtual background: none | blurLight | blurMedium | blurStrong | image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bg_mode: Option<String>,
    /// Cover image path when bg_mode == image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bg_image: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub locked: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageLayer {
    pub path: String,
    pub rect: Rect,
    #[serde(default = "one")]
    pub opacity: f32,
    #[serde(default)]
    pub visible: Option<Visible>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub locked: bool,
}

fn one() -> f32 {
    1.0
}

fn is_false(b: &bool) -> bool {
    !*b
}

impl Layer {
    fn rect(&self) -> Option<&Rect> {
        match self {
            Layer::Screen(l) => Some(&l.rect),
            Layer::Camera(l) => Some(&l.rect),
            Layer::Image(l) => Some(&l.rect),
            Layer::Background(_) => None,
        }
    }
}

/// Validate a template's invariants (SPEC §3.2): positive canvas, at most one active
/// background, and every layer rect normalized within 0..1.
pub fn validate(template: &Template) -> Result<(), CoreError> {
    if template.scenes.is_empty() {
        return Err(CoreError::InvalidTemplate {
            message: "template must have at least one scene".into(),
        });
    }
    for scene in &template.scenes {
        if scene.canvas.width == 0 || scene.canvas.height == 0 {
            return Err(CoreError::InvalidTemplate {
                message: "canvas dimensions must be positive".into(),
            });
        }
        let backgrounds = scene
            .layers
            .iter()
            .filter(|l| matches!(l, Layer::Background(_)))
            .count();
        if backgrounds > 1 {
            return Err(CoreError::InvalidTemplate {
                message: format!("a scene allows at most one background, found {backgrounds}"),
            });
        }
        for layer in &scene.layers {
            if let Some(rect) = layer.rect() {
                if !rect.is_normalized() {
                    return Err(CoreError::InvalidTemplate {
                        message: "layer rect must be normalized within 0..1 with positive size".into(),
                    });
                }
            }
        }
    }
    Ok(())
}

/// Parse a template JSON document into the model. Accepts the current scenes format
/// AND the legacy single-layout format ({canvas, layers}) — migrating the latter into a
/// one-scene template so old saved templates keep working.
pub fn parse(json: &str) -> Result<Template, CoreError> {
    #[derive(Deserialize)]
    struct RawTemplate {
        #[serde(default = "default_version")]
        version: u32,
        #[serde(default)]
        scenes: Option<Vec<Scene>>,
        #[serde(default)]
        canvas: Option<Canvas>,
        #[serde(default)]
        layers: Option<Vec<Layer>>,
    }
    fn default_version() -> u32 {
        1
    }
    let raw: RawTemplate = serde_json::from_str(json)
        .map_err(|e| CoreError::InvalidTemplate { message: e.to_string() })?;
    // A present `scenes` key (even empty) is the new format — validate handles empties.
    if let Some(scenes) = raw.scenes {
        return Ok(Template { version: raw.version, scenes });
    }
    let canvas = raw.canvas.unwrap_or(Canvas { width: 1920, height: 1080 });
    let layers = raw.layers.unwrap_or_default();
    Ok(Template {
        version: raw.version,
        scenes: vec![Scene { name: "Scene 1".into(), canvas, layers }],
    })
}

/// Parse + validate a template JSON document (the FFI entry point for the editor).
#[uniffi::export]
pub fn validate_template_json(json: String) -> Result<(), CoreError> {
    let template = parse(&json)?;
    validate(&template)
}

/// Serialize a template model back to pretty JSON.
pub fn serialize(template: &Template) -> String {
    serde_json::to_string_pretty(template).expect("Template is always serializable")
}

/// Parse + validate + re-serialize a template JSON, normalizing its formatting. The
/// editor uses this to validate and canonicalize a document before saving it.
#[uniffi::export]
pub fn normalize_template_json(json: String) -> Result<String, CoreError> {
    let template = parse(&json)?;
    validate(&template)?;
    Ok(serialize(&template))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"{
      "version": 1,
      "canvas": { "width": 1920, "height": 1080 },
      "layers": [
        { "type": "background", "source": "screen", "blur": 55, "darken": 0.35 },
        { "type": "screen", "rect": { "x": 0.03, "y": 0.12, "w": 0.72, "h": 0.76 }, "cornerRadius": 16,
          "shadow": { "radius": 40, "opacity": 0.45, "dy": 12 } },
        { "type": "camera", "rect": { "x": 0.77, "y": 0.62, "w": 0.20, "h": 0.26 }, "cornerRadius": 20, "mirror": true },
        { "type": "image", "path": "assets/logo.png", "rect": { "x": 0.80, "y": 0.04, "w": 0.16, "h": 0.10 }, "opacity": 0.9 }
      ]
    }"#;

    // New scenes-format document. r##"…"## because the color hex contains `"#`.
    const VALID_SCENES: &str = r##"{
      "version": 1,
      "scenes": [
        { "name": "Intro", "canvas": { "width": 1920, "height": 1080 }, "layers": [
          { "type": "background", "source": "color", "color": "#101018" } ] },
        { "name": "Main", "canvas": { "width": 1920, "height": 1080 }, "layers": [
          { "type": "background", "source": "screen", "blur": 40, "darken": 0.3 },
          { "type": "camera", "rect": { "x": 0.75, "y": 0.6, "w": 0.2, "h": 0.26 } } ] }
      ]
    }"##;

    #[test]
    fn parses_the_spec_example() {
        let t = parse(VALID).expect("should parse");
        assert_eq!(t.version, 1);
        assert_eq!(t.scenes.len(), 1);
        assert_eq!(t.scenes[0].canvas, Canvas { width: 1920, height: 1080 });
        assert_eq!(t.scenes[0].layers.len(), 4);
    }

    #[test]
    fn camelcase_fields_map() {
        let t = parse(VALID).unwrap();
        match &t.scenes[0].layers[1] {
            Layer::Screen(s) => assert_eq!(s.corner_radius, 16.0),
            other => panic!("expected screen, got {other:?}"),
        }
    }

    #[test]
    fn legacy_layout_migrates_to_one_scene() {
        let t = parse(VALID).unwrap();
        assert_eq!(t.scenes.len(), 1, "old {{canvas,layers}} becomes one scene");
        assert_eq!(t.scenes[0].name, "Scene 1");
    }

    #[test]
    fn new_scenes_format_parses_and_validates() {
        let t = parse(VALID_SCENES).expect("should parse scenes");
        assert_eq!(t.scenes.len(), 2);
        assert_eq!(t.scenes[0].name, "Intro");
        assert_eq!(t.scenes[1].layers.len(), 2);
        assert!(validate_template_json(VALID_SCENES.to_string()).is_ok());
    }

    #[test]
    fn empty_scenes_is_rejected() {
        let json = r#"{ "version": 1, "scenes": [] }"#;
        assert!(validate_template_json(json.to_string()).is_err(), "no scenes must fail");
    }

    #[test]
    fn hidden_and_locked_survive_normalize() {
        let json = r##"{ "version":1, "scenes":[ { "name":"S", "canvas":{"width":1920,"height":1080}, "layers":[
            {"type":"background","source":"color","color":"#000000"},
            {"type":"camera","rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"hidden":true,"locked":true} ] } ] }"##;
        let out = normalize_template_json(json.to_string()).expect("valid");
        assert!(out.contains("\"hidden\": true"), "hidden must survive normalize");
        assert!(out.contains("\"locked\": true"), "locked must survive normalize");
    }

    #[test]
    fn valid_template_passes_validation() {
        assert!(validate_template_json(VALID.to_string()).is_ok());
    }

    #[test]
    fn two_backgrounds_is_rejected() {
        // r##"…"## because the color hex contains `"#`, which would close r#"…"#.
        let json = r##"{ "version":1, "canvas":{"width":1920,"height":1080}, "layers":[
            {"type":"background","source":"color","color":"#000"},
            {"type":"background","source":"screen","blur":10,"darken":0.2} ] }"##;
        assert!(validate_template_json(json.to_string()).is_err(), "two backgrounds must fail");
    }

    #[test]
    fn out_of_range_rect_is_rejected() {
        let json = r#"{ "version":1, "canvas":{"width":1920,"height":1080}, "layers":[
            {"type":"screen","rect":{"x":0.0,"y":0.0,"w":1.5,"h":0.5}} ] }"#;
        assert!(validate_template_json(json.to_string()).is_err(), "w=1.5 must fail");
    }

    #[test]
    fn zero_canvas_is_rejected() {
        let json = r#"{ "version":1, "canvas":{"width":0,"height":1080}, "layers":[] }"#;
        assert!(validate_template_json(json.to_string()).is_err(), "zero width must fail");
    }

    #[test]
    fn unknown_layer_type_is_rejected() {
        let json = r#"{ "version":1, "canvas":{"width":1920,"height":1080}, "layers":[
            {"type":"hologram"} ] }"#;
        assert!(validate_template_json(json.to_string()).is_err(), "unknown type must fail to parse");
    }

    #[test]
    fn roundtrip_preserves_the_model() {
        let t = parse(VALID).unwrap();
        let reparsed = parse(&serialize(&t)).unwrap();
        assert_eq!(t, reparsed);
    }

    #[test]
    fn per_layer_device_id_roundtrips_and_multiple_cameras_ok() {
        let json = r#"{ "version":1, "canvas":{"width":1920,"height":1080}, "layers":[
            {"type":"camera","rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"deviceId":"cam-A"},
            {"type":"camera","rect":{"x":0.5,"y":0.5,"w":0.2,"h":0.2},"deviceId":"cam-B"} ] }"#;
        let t = parse(json).unwrap();
        let out = serialize(&t);
        assert!(out.contains("cam-A") && out.contains("cam-B"), "deviceId must survive normalize");
        assert!(validate(&t).is_ok(), "two cameras with different devices is valid");
    }
}
