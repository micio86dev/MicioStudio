//! Auto-zoom engine (SPEC §4). Deterministic: clicks → zoom keyframes, 100% testable
//! offline. The compositor interpolates the keyframes as a transform on the full-res
//! screen texture BEFORE downscale (SPEC §2.1). No OS APIs here.

use crate::event_log::{EventKind, InputEvent};
use serde::{Deserialize, Serialize};

/// Interpolation curve for a keyframe segment (applied approaching this keyframe).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum EaseCurve {
    EaseInOut,
    EaseOut,
    Smooth,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ZoomConfig {
    pub enabled: bool,
    pub level: f32,
    pub ease_ms: u32,
    pub curve: EaseCurve,
    pub hold_ms: u32,
    pub debounce_ms: u32,
    pub max_zooms_per_10s: u8,
}

impl Default for ZoomConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            level: 2.0,
            ease_ms: 450,
            curve: EaseCurve::EaseInOut,
            hold_ms: 1800,
            debounce_ms: 500,
            max_zooms_per_10s: 4,
        }
    }
}

/// A target state the compositor interpolates toward: at `t_ms`, be centered at
/// (`center_x`,`center_y`) (normalized 0..1) with `scale` (1.0 = no zoom).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ZoomKeyframe {
    pub t_ms: u64,
    pub center_x: f32,
    pub center_y: f32,
    pub scale: f32,
    pub curve: EaseCurve,
}

#[uniffi::export]
pub fn default_zoom_config() -> ZoomConfig {
    ZoomConfig::default()
}

/// Lead time before a click at which the zoom-in begins (SPEC §4 step 2, ~150ms).
const LEAD_MS: u64 = 150;
/// Clicks farther apart than this (normalized) start a new cluster even within debounce.
const CLUSTER_DIST: f32 = 0.08;

#[derive(Debug, Clone, Copy)]
struct Cluster {
    t_ms: u64, // first click time
    cx: f32,
    cy: f32,
    count: u32,
}

/// Generate zoom keyframes from input events (SPEC §4).
#[uniffi::export]
pub fn generate_zoom_keyframes(events: Vec<InputEvent>, config: ZoomConfig) -> Vec<ZoomKeyframe> {
    if !config.enabled {
        return vec![];
    }
    let mut clicks: Vec<&InputEvent> = events.iter().filter(|e| e.kind == EventKind::Click).collect();
    clicks.sort_by_key(|e| e.t_ms);
    if clicks.is_empty() {
        return vec![];
    }
    let clusters = cluster_clicks(&clicks, config.debounce_ms as u64);
    let clusters = apply_cap(clusters, config.max_zooms_per_10s);
    build_keyframes(&clusters, &config)
}

/// Group consecutive clicks that are close in time (<= debounce) AND space into one
/// cluster whose center is the mean (SPEC §4 step 1).
fn cluster_clicks(clicks: &[&InputEvent], debounce_ms: u64) -> Vec<Cluster> {
    let mut out: Vec<Cluster> = vec![];
    // (first_t, sum_x, sum_y, count, last_t)
    let mut cur: Option<(u64, f32, f32, u32, u64)> = None;
    for c in clicks {
        if let Some((first_t, sx, sy, count, last_t)) = cur {
            let mean_x = sx / count as f32;
            let mean_y = sy / count as f32;
            let dist = ((c.x - mean_x).powi(2) + (c.y - mean_y).powi(2)).sqrt();
            if c.t_ms - last_t <= debounce_ms && dist <= CLUSTER_DIST {
                cur = Some((first_t, sx + c.x, sy + c.y, count + 1, c.t_ms));
                continue;
            }
            out.push(Cluster { t_ms: first_t, cx: sx / count as f32, cy: sy / count as f32, count });
        }
        cur = Some((c.t_ms, c.x, c.y, 1, c.t_ms));
    }
    if let Some((first_t, sx, sy, count, _)) = cur {
        out.push(Cluster { t_ms: first_t, cx: sx / count as f32, cy: sy / count as f32, count });
    }
    out
}

/// Enforce max zooms per 10s window, dropping the lowest-importance (fewest-click)
/// clusters in an over-full window (SPEC §4 step 5).
fn apply_cap(clusters: Vec<Cluster>, max: u8) -> Vec<Cluster> {
    if max == 0 {
        return clusters;
    }
    use std::collections::HashMap;
    let mut buckets: HashMap<u64, Vec<Cluster>> = HashMap::new();
    for c in clusters {
        buckets.entry(c.t_ms / 10_000).or_default().push(c);
    }
    let mut kept: Vec<Cluster> = vec![];
    for (_, mut group) in buckets {
        if group.len() > max as usize {
            group.sort_by(|a, b| b.count.cmp(&a.count).then(a.t_ms.cmp(&b.t_ms)));
            group.truncate(max as usize);
        }
        kept.extend(group);
    }
    kept.sort_by_key(|c| c.t_ms);
    kept
}

/// Turn clusters into keyframes: zoom-in (lead → ease to level), hold, and either a
/// glide to the next cluster (if it lands within the hold) or a zoom-out (SPEC §4 2-4).
fn build_keyframes(clusters: &[Cluster], config: &ZoomConfig) -> Vec<ZoomKeyframe> {
    let level = config.level;
    let ease = config.ease_ms as u64;
    let hold = config.hold_ms as u64;
    let curve = config.curve;
    let mut kfs: Vec<ZoomKeyframe> = vec![];
    let mut hold_end: u64 = 0;
    let mut zoomed = false;
    let mut last_center = (0.5_f32, 0.5_f32);

    for cluster in clusters {
        let center = clamp_center(cluster.cx, cluster.cy, level);
        let tc = cluster.t_ms;

        if zoomed && tc < hold_end {
            // Glide: move toward the new cluster without zooming out.
            kfs.push(kf(tc, center, level, curve));
            hold_end = tc + hold;
            last_center = center;
            continue;
        }
        if zoomed {
            // Previous hold ended before this cluster → zoom out first.
            kfs.push(kf(hold_end, last_center, level, curve));
            kfs.push(kf(hold_end + ease, last_center, 1.0, curve));
        }
        let start = tc.saturating_sub(LEAD_MS);
        kfs.push(kf(start, center, 1.0, curve));
        kfs.push(kf(start + ease, center, level, curve));
        hold_end = start + ease + hold;
        zoomed = true;
        last_center = center;
    }
    if zoomed {
        kfs.push(kf(hold_end, last_center, level, curve));
        kfs.push(kf(hold_end + ease, last_center, 1.0, curve));
    }
    kfs
}

fn kf(t_ms: u64, center: (f32, f32), scale: f32, curve: EaseCurve) -> ZoomKeyframe {
    ZoomKeyframe { t_ms, center_x: center.0, center_y: center.1, scale, curve }
}

fn clamp_center(cx: f32, cy: f32, scale: f32) -> (f32, f32) {
    let half = 0.5 / scale.max(1.0);
    (
        cx.clamp(half, 1.0 - half),
        cy.clamp(half, 1.0 - half),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn click(t_ms: u64, x: f32, y: f32) -> InputEvent {
        InputEvent { t_ms, x, y, kind: EventKind::Click }
    }
    fn mv(t_ms: u64, x: f32, y: f32) -> InputEvent {
        InputEvent { t_ms, x, y, kind: EventKind::Move }
    }

    fn max_scale(kfs: &[ZoomKeyframe]) -> f32 {
        kfs.iter().map(|k| k.scale).fold(1.0, f32::max)
    }
    // Count zoom-in events = transitions from scale≈1 up to >1.
    fn zoom_in_count(kfs: &[ZoomKeyframe]) -> usize {
        let mut n = 0;
        let mut prev = 1.0_f32;
        for k in kfs {
            if prev <= 1.01 && k.scale > 1.01 {
                n += 1;
            }
            prev = k.scale;
        }
        n
    }

    #[test]
    fn disabled_yields_no_keyframes() {
        let cfg = ZoomConfig { enabled: false, ..Default::default() };
        assert!(generate_zoom_keyframes(vec![click(1000, 0.5, 0.5)], cfg).is_empty());
    }

    #[test]
    fn no_clicks_yields_no_keyframes() {
        let cfg = ZoomConfig::default();
        let events = vec![mv(0, 0.1, 0.1), mv(100, 0.2, 0.2)];
        assert!(generate_zoom_keyframes(events, cfg).is_empty());
    }

    #[test]
    fn single_click_zooms_in_holds_and_out() {
        let cfg = ZoomConfig::default();
        let kfs = generate_zoom_keyframes(vec![click(2000, 0.5, 0.5)], cfg);
        assert!(!kfs.is_empty());
        assert!((max_scale(&kfs) - cfg.level).abs() < 0.01, "reaches configured level");
        assert_eq!(zoom_in_count(&kfs), 1, "exactly one zoom-in");
        assert!((kfs.last().unwrap().scale - 1.0).abs() < 0.01, "ends zoomed out");
        // keyframes are time-ordered
        assert!(kfs.windows(2).all(|w| w[0].t_ms <= w[1].t_ms));
    }

    #[test]
    fn double_click_within_debounce_and_close_is_one_zoom() {
        let cfg = ZoomConfig::default();
        let kfs = generate_zoom_keyframes(
            vec![click(2000, 0.5, 0.5), click(2200, 0.52, 0.51)], cfg);
        assert_eq!(zoom_in_count(&kfs), 1, "one cluster → one zoom-in");
    }

    #[test]
    fn click_during_hold_glides_without_zooming_out() {
        let cfg = ZoomConfig::default();
        // Second click far away but within the hold window of the first.
        let kfs = generate_zoom_keyframes(
            vec![click(2000, 0.3, 0.3), click(2800, 0.7, 0.7)], cfg);
        assert_eq!(zoom_in_count(&kfs), 1, "glide, not a second zoom-in");
        // Scale never returns to 1 between the two clicks (t in 2000..2800).
        let between = kfs.iter().filter(|k| k.t_ms >= 2000 && k.t_ms <= 2800);
        assert!(between.clone().all(|k| k.scale > 1.01), "no zoom-out during glide");
        // The center moves toward the second click.
        assert!(kfs.iter().any(|k| k.center_x > 0.5), "center glided toward 0.7");
    }

    #[test]
    fn burst_respects_max_zooms_per_10s() {
        let mut cfg = ZoomConfig::default();
        cfg.max_zooms_per_10s = 3;
        cfg.hold_ms = 100; // short hold so each is a separate zoom, not a glide
        cfg.debounce_ms = 50;
        // 8 well-separated clicks within 10s.
        let events: Vec<_> = (0..8).map(|i| click(1000 + i * 1000, 0.2 + 0.05 * i as f32, 0.5)).collect();
        let kfs = generate_zoom_keyframes(events, cfg);
        assert!(zoom_in_count(&kfs) <= 3, "cap respected, got {}", zoom_in_count(&kfs));
    }

    #[test]
    fn edge_click_center_is_clamped_into_frame() {
        let cfg = ZoomConfig::default(); // level 2.0 → half viewport = 0.25
        let kfs = generate_zoom_keyframes(vec![click(2000, 0.0, 1.0)], cfg);
        let half = 0.5 / cfg.level;
        for k in &kfs {
            assert!(k.center_x >= half - 0.001 && k.center_x <= 1.0 - half + 0.001, "cx clamped");
            assert!(k.center_y >= half - 0.001 && k.center_y <= 1.0 - half + 0.001, "cy clamped");
        }
    }
}
