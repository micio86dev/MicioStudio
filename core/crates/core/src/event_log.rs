//! Event-log data model (SPEC §5.1/§5.2). Swift captures raw clicks + 60Hz cursor
//! samples, converts them to `t_ms` offsets from t0, and asks the core to produce
//! the exact JSONL line to append. The core OWNS the wire format so the writer
//! (Swift, Phase 1) and the reader (the zoom engine, Phase 4) can never drift.

use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// Kind of input event. Serializes as the exact string tag `"Click"` / `"Move"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum EventKind {
    Click,
    Move,
}

/// A single input event, normalized. `t_ms` is the offset from t0 in milliseconds
/// (SPEC §5.2); `x`/`y` are normalized 0..1 on the screen frame.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct InputEvent {
    pub t_ms: u64,
    pub x: f32,
    pub y: f32,
    pub kind: EventKind,
}

impl InputEvent {
    /// A copy with `x`/`y` clamped to the normalized [0,1] range, enforcing the
    /// on-disk invariant regardless of what the caller passes.
    fn clamped(self) -> Self {
        Self {
            x: self.x.clamp(0.0, 1.0),
            y: self.y.clamp(0.0, 1.0),
            ..self
        }
    }
}

/// Serialize one event to a single compact JSONL line (NO trailing newline).
/// Coordinates are clamped to [0,1]. The Swift writer appends `"\n"` itself.
#[uniffi::export]
pub fn append_event_line(event: InputEvent) -> String {
    // Serialization of a fixed-shape struct with finite numeric fields cannot fail.
    serde_json::to_string(&event.clamped()).expect("InputEvent is always serializable")
}

/// Serialize a batch of events to JSONL — lines joined by `"\n"`, no trailing newline.
#[uniffi::export]
pub fn serialize_events_jsonl(events: Vec<InputEvent>) -> String {
    events
        .iter()
        .map(|e| serde_json::to_string(&e.clamped()).expect("InputEvent is always serializable"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Parse JSONL text into events. Blank/whitespace-only lines are skipped so a
/// partially-flushed file (e.g. after a crash) still parses. A malformed line
/// returns [`CoreError::Parse`] carrying the 1-based line number.
#[uniffi::export]
pub fn parse_events_jsonl(text: String) -> Result<Vec<InputEvent>, CoreError> {
    let mut out = Vec::new();
    for (idx, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let event: InputEvent = serde_json::from_str(line).map_err(|e| CoreError::Parse {
            line: (idx + 1) as u32,
            message: e.to_string(),
        })?;
        out.push(event);
    }
    Ok(out)
}

/// Stable-sort events by ascending `t_ms` (helper for the future zoom engine).
#[uniffi::export]
pub fn sort_by_t_ms(events: Vec<InputEvent>) -> Vec<InputEvent> {
    let mut events = events;
    events.sort_by_key(|e| e.t_ms); // sort_by_key is stable
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(t_ms: u64, x: f32, y: f32, kind: EventKind) -> InputEvent {
        InputEvent { t_ms, x, y, kind }
    }

    #[test]
    fn roundtrip_single_click() {
        let e = ev(1234, 0.51, 0.42, EventKind::Click);
        let parsed = parse_events_jsonl(append_event_line(e)).unwrap();
        assert_eq!(parsed, vec![e]);
    }

    #[test]
    fn roundtrip_mixed_sequence_preserves_order() {
        let events = vec![
            ev(0, 0.1, 0.1, EventKind::Move),
            ev(10, 0.2, 0.2, EventKind::Click),
            ev(20, 0.3, 0.3, EventKind::Move),
        ];
        let parsed = parse_events_jsonl(serialize_events_jsonl(events.clone())).unwrap();
        assert_eq!(parsed, events);
    }

    #[test]
    fn jsonl_is_one_object_per_line_no_trailing_newline() {
        let events = vec![
            ev(0, 0.0, 0.0, EventKind::Click),
            ev(1, 0.0, 0.0, EventKind::Click),
            ev(2, 0.0, 0.0, EventKind::Click),
        ];
        let text = serialize_events_jsonl(events);
        assert_eq!(text.lines().count(), 3);
        assert!(!text.ends_with('\n'), "no trailing newline expected");
    }

    #[test]
    fn parse_skips_blank_lines() {
        // Leading, internal, and trailing blank lines (simulates a partial flush).
        let text = "\n{\"t_ms\":0,\"x\":0.0,\"y\":0.0,\"kind\":\"Click\"}\n\n\
                    {\"t_ms\":5,\"x\":0.0,\"y\":0.0,\"kind\":\"Move\"}\n"
            .to_string();
        let parsed = parse_events_jsonl(text).unwrap();
        assert_eq!(parsed.len(), 2);
    }

    #[test]
    fn parse_rejects_malformed_line_with_line_number() {
        let text = "{\"t_ms\":0,\"x\":0.0,\"y\":0.0,\"kind\":\"Click\"}\nNOT JSON\n".to_string();
        match parse_events_jsonl(text).unwrap_err() {
            CoreError::Parse { line, .. } => assert_eq!(line, 2),
            other => panic!("expected Parse error, got {other:?}"),
        }
    }

    #[test]
    fn kind_serializes_as_exact_string_tag() {
        let click = append_event_line(ev(0, 0.0, 0.0, EventKind::Click));
        assert!(click.contains("\"kind\":\"Click\""), "got: {click}");
        let mv = append_event_line(ev(0, 0.0, 0.0, EventKind::Move));
        assert!(mv.contains("\"kind\":\"Move\""), "got: {mv}");
    }

    #[test]
    fn append_line_clamps_coords_to_unit_range() {
        let parsed = parse_events_jsonl(append_event_line(ev(0, 1.5, -0.3, EventKind::Move))).unwrap();
        assert_eq!(parsed[0].x, 1.0);
        assert_eq!(parsed[0].y, 0.0);
    }

    #[test]
    fn half_coord_roundtrips_exactly() {
        let parsed = parse_events_jsonl(append_event_line(ev(0, 0.5, 0.5, EventKind::Click))).unwrap();
        assert_eq!(parsed[0].x, 0.5);
        assert_eq!(parsed[0].y, 0.5);
    }

    #[test]
    fn sort_by_t_ms_orders_and_is_stable() {
        let events = vec![
            ev(20, 0.0, 0.0, EventKind::Click),
            ev(10, 0.1, 0.1, EventKind::Click),
            ev(10, 0.2, 0.2, EventKind::Move), // same t_ms → relative order must hold
            ev(0, 0.0, 0.0, EventKind::Move),
        ];
        let sorted = sort_by_t_ms(events);
        assert_eq!(
            sorted.iter().map(|e| e.t_ms).collect::<Vec<_>>(),
            vec![0, 10, 10, 20]
        );
        assert_eq!(sorted[1].x, 0.1, "stable sort keeps first t_ms==10 first");
        assert_eq!(sorted[2].x, 0.2);
    }
}
