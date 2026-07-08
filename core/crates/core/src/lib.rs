//! MicioStudio portable core. NO system APIs — pure data only (SPEC §1).
//!
//! Phase 1 surface: the event-log data model (SPEC §5.2) with JSONL
//! serialization, exposed to Swift via UniFFI proc-macros (no `.udl`).

uniffi::setup_scaffolding!();

mod error;
mod event_log;

pub use error::CoreError;
pub use event_log::{
    append_event_line, parse_events_jsonl, serialize_events_jsonl, sort_by_t_ms, EventKind,
    InputEvent,
};
