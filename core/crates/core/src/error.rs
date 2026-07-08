use std::fmt;

/// Errors surfaced across the FFI boundary. Kept minimal for Phase 1.
#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    /// A line in `events.jsonl` could not be parsed. `line` is 1-based.
    Parse { line: u32, message: String },
    /// A template JSON document could not be parsed or violated an invariant.
    InvalidTemplate { message: String },
    /// A SQLite / library operation failed.
    Db { message: String },
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Parse { line, message } => {
                write!(f, "failed to parse events.jsonl at line {line}: {message}")
            }
            CoreError::InvalidTemplate { message } => {
                write!(f, "invalid template: {message}")
            }
            CoreError::Db { message } => write!(f, "database error: {message}"),
        }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Db { message: e.to_string() }
    }
}

impl std::error::Error for CoreError {}
