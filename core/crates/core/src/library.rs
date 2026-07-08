//! SQLite-backed library (SPEC §3.1) — projects/recordings/renders/templates. Lives
//! in the core (rusqlite), so persistence stays portable. Phase 2 implements the
//! schema + template CRUD; other tables are created and filled in later phases.
//!
//! Timestamps are caller-provided epoch milliseconds, keeping the core deterministic
//! (no system clock) and testable.

use crate::error::CoreError;
use rusqlite::{Connection, OptionalExtension};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TemplateRow {
    pub id: String,
    pub name: String,
    /// Template document as JSON (see `template` module / SPEC §3.2).
    pub definition: String,
    pub is_builtin: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Handle to the on-disk (or in-memory) library database.
#[derive(uniffi::Object)]
pub struct Library {
    conn: Mutex<Connection>,
}

#[uniffi::export]
impl Library {
    /// Open (creating if needed) the library at `path`, applying migrations.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        Self::init(Connection::open(path)?)
    }

    /// Open a throwaway in-memory library (tests / previews).
    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Arc<Self>, CoreError> {
        Self::init(Connection::open_in_memory()?)
    }

    /// Insert or update a template by id.
    pub fn upsert_template(&self, row: TemplateRow) -> Result<(), CoreError> {
        let conn = self.conn.lock().expect("library mutex poisoned");
        conn.execute(
            "INSERT INTO templates (id, name, definition, is_builtin, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET name = ?2, definition = ?3, is_builtin = ?4, updated_at = ?6",
            rusqlite::params![
                row.id, row.name, row.definition, row.is_builtin as i64, row.created_at, row.updated_at
            ],
        )?;
        Ok(())
    }

    pub fn get_template(&self, id: String) -> Result<Option<TemplateRow>, CoreError> {
        let conn = self.conn.lock().expect("library mutex poisoned");
        let row = conn
            .query_row(
                "SELECT id, name, definition, is_builtin, created_at, updated_at FROM templates WHERE id = ?1",
                [id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    pub fn list_templates(&self) -> Result<Vec<TemplateRow>, CoreError> {
        let conn = self.conn.lock().expect("library mutex poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, name, definition, is_builtin, created_at, updated_at FROM templates ORDER BY name",
        )?;
        let rows = stmt.query_map([], Self::map_row)?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn delete_template(&self, id: String) -> Result<(), CoreError> {
        let conn = self.conn.lock().expect("library mutex poisoned");
        conn.execute("DELETE FROM templates WHERE id = ?1", [id])?;
        Ok(())
    }
}

impl Library {
    fn init(conn: Connection) -> Result<Arc<Self>, CoreError> {
        conn.execute_batch(MIGRATION)?;
        Ok(Arc::new(Self { conn: Mutex::new(conn) }))
    }

    fn map_row(r: &rusqlite::Row) -> rusqlite::Result<TemplateRow> {
        Ok(TemplateRow {
            id: r.get(0)?,
            name: r.get(1)?,
            definition: r.get(2)?,
            is_builtin: r.get::<_, i64>(3)? != 0,
            created_at: r.get(4)?,
            updated_at: r.get(5)?,
        })
    }
}

const MIGRATION: &str = r#"
CREATE TABLE IF NOT EXISTS templates (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  definition TEXT NOT NULL,
  is_builtin INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  template_id   TEXT REFERENCES templates(id),
  zoom_config   TEXT NOT NULL,
  export_config TEXT NOT NULL,
  audio_config  TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS recordings (
  id             TEXT PRIMARY KEY,
  project_id     TEXT REFERENCES projects(id) ON DELETE CASCADE,
  screen_path    TEXT NOT NULL,
  camera_path    TEXT,
  audio_mic_path TEXT,
  audio_sys_path TEXT,
  event_log_path TEXT NOT NULL,
  duration_ms    INTEGER NOT NULL,
  capture_w      INTEGER NOT NULL,
  capture_h      INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS render_jobs (
  id          TEXT PRIMARY KEY,
  project_id  TEXT REFERENCES projects(id) ON DELETE CASCADE,
  status      TEXT NOT NULL,
  progress    REAL NOT NULL DEFAULT 0,
  output_path TEXT,
  settings    TEXT NOT NULL,
  error       TEXT,
  created_at  INTEGER NOT NULL,
  finished_at INTEGER
);
CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"#;

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, name: &str) -> TemplateRow {
        TemplateRow {
            id: id.into(),
            name: name.into(),
            definition: "{}".into(),
            is_builtin: false,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[test]
    fn open_in_memory_creates_schema() {
        assert!(Library::open_in_memory().is_ok());
    }

    #[test]
    fn upsert_then_get_roundtrips() {
        let lib = Library::open_in_memory().unwrap();
        let r = row("t1", "Dark");
        lib.upsert_template(r.clone()).unwrap();
        assert_eq!(lib.get_template("t1".into()).unwrap(), Some(r));
    }

    #[test]
    fn get_missing_is_none() {
        let lib = Library::open_in_memory().unwrap();
        assert_eq!(lib.get_template("nope".into()).unwrap(), None);
    }

    #[test]
    fn upsert_same_id_updates_in_place() {
        let lib = Library::open_in_memory().unwrap();
        lib.upsert_template(row("t1", "A")).unwrap();
        let mut r2 = row("t1", "B");
        r2.updated_at = 2;
        lib.upsert_template(r2).unwrap();
        assert_eq!(lib.list_templates().unwrap().len(), 1);
        assert_eq!(lib.get_template("t1".into()).unwrap().unwrap().name, "B");
    }

    #[test]
    fn list_orders_by_name() {
        let lib = Library::open_in_memory().unwrap();
        lib.upsert_template(row("t1", "Zeta")).unwrap();
        lib.upsert_template(row("t2", "Alpha")).unwrap();
        let names: Vec<_> = lib.list_templates().unwrap().into_iter().map(|t| t.name).collect();
        assert_eq!(names, vec!["Alpha", "Zeta"]);
    }

    #[test]
    fn delete_removes() {
        let lib = Library::open_in_memory().unwrap();
        lib.upsert_template(row("t1", "A")).unwrap();
        lib.delete_template("t1".into()).unwrap();
        assert!(lib.list_templates().unwrap().is_empty());
    }
}
