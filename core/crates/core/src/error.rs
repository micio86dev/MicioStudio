use std::fmt;

/// Errors surfaced across the FFI boundary. Kept minimal for Phase 1.
#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    /// A line in `events.jsonl` could not be parsed. `line` is 1-based.
    Parse { line: u32, message: String },
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Parse { line, message } => {
                write!(f, "failed to parse events.jsonl at line {line}: {message}")
            }
        }
    }
}

impl std::error::Error for CoreError {}
