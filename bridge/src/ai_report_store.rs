//! Feature-local SQLite persistence for AI report settings and latest results.
//!
//! Only validated public report DTOs are serialized. Credentials, outbound
//! prompts, and raw provider responses never enter these tables.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, params};

use crate::ai_recap::AiRecapDto;

const MAX_REPORT_JSON_BYTES: usize = 64 * 1024;
const CREATE_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS ai_report_settings (
    setting_key TEXT PRIMARY KEY NOT NULL,
    setting_value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ai_latest_reports (
    scope TEXT PRIMARY KEY NOT NULL CHECK (scope IN ('daily', 'weekly', 'monthly')),
    schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
    generated_at_utc TEXT NOT NULL,
    report_json TEXT NOT NULL
);
"#;

/// Redacted local persistence failure.
#[derive(Debug, thiserror::Error)]
pub enum AiReportStoreError {
    /// The feature-local report store could not be initialized.
    #[error("AI report storage is unavailable")]
    Unavailable,
    /// SQLite could not complete an operation.
    #[error("AI report database operation failed")]
    Database(#[from] rusqlite::Error),
    /// A lock was poisoned by a previous panic.
    #[error("AI report database lock is unavailable")]
    LockUnavailable,
    /// A report could not be serialized within the feature bound.
    #[error("AI report payload is invalid")]
    InvalidReport,
}

/// Narrow persistence port for at most one report per report type.
pub trait AiReportStore: Send + Sync {
    /// Whether report persistence is available for complete operations.
    fn is_available(&self) -> bool {
        true
    }
    /// Loads up to three latest report DTOs without network access.
    fn load_latest_reports(&self) -> Result<Vec<AiRecapDto>, AiReportStoreError>;
    /// Atomically replaces the latest report for its scope.
    fn save_latest_report(&self, report: &AiRecapDto) -> Result<(), AiReportStoreError>;
    /// Clears all persisted report results but preserves settings.
    fn clear_latest_reports(&self) -> Result<(), AiReportStoreError>;
    /// Loads the persisted default model, if present.
    fn load_default_model(&self) -> Result<Option<String>, AiReportStoreError>;
    /// Persists the validated default model.
    fn save_default_model(&self, model: &str) -> Result<(), AiReportStoreError>;
}

/// Fail-closed store used when AI tables cannot be initialized.
///
/// Keeping this behind the report-store port lets TimeTrace tracking start
/// normally while every AI operation remains locally unavailable.
pub struct UnavailableAiReportStore;

impl AiReportStore for UnavailableAiReportStore {
    fn is_available(&self) -> bool {
        false
    }

    fn load_latest_reports(&self) -> Result<Vec<AiRecapDto>, AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }

    fn save_latest_report(&self, _report: &AiRecapDto) -> Result<(), AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }

    fn clear_latest_reports(&self) -> Result<(), AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }

    fn load_default_model(&self) -> Result<Option<String>, AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }

    fn save_default_model(&self, _model: &str) -> Result<(), AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }
}

/// SQLite implementation stored alongside the TimeTrace usage database.
pub struct SqliteAiReportStore {
    connection: Mutex<Connection>,
}

impl SqliteAiReportStore {
    /// Opens the feature tables in the existing TimeTrace database.
    pub fn open(path: PathBuf) -> Result<Self, AiReportStoreError> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection)
    }

    fn from_connection(connection: Connection) -> Result<Self, AiReportStoreError> {
        connection.busy_timeout(Duration::from_millis(500))?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        connection.pragma_update(None, "cache_size", -256_i64)?;
        connection.execute_batch(CREATE_SCHEMA)?;
        let has_schema_version = {
            let mut statement = connection.prepare("PRAGMA table_info(ai_latest_reports)")?;
            let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
            columns
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|column| column == "schema_version")
        };
        if !has_schema_version {
            connection.execute(
                "ALTER TABLE ai_latest_reports ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1",
                [],
            )?;
        }
        // Remove the pre-release setting that could suppress the documented
        // secure-store -> environment fallback. P0 intentionally persists only
        // the non-secret default model in this table.
        connection.execute(
            "DELETE FROM ai_report_settings WHERE setting_key = 'environment_fallback_enabled'",
            [],
        )?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, AiReportStoreError> {
        self.connection
            .lock()
            .map_err(|_| AiReportStoreError::LockUnavailable)
    }

    fn load_setting(&self, key: &str) -> Result<Option<String>, AiReportStoreError> {
        let connection = self.lock()?;
        connection
            .query_row(
                "SELECT setting_value FROM ai_report_settings WHERE setting_key = ?1",
                [key],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    fn save_setting(&self, key: &str, value: &str) -> Result<(), AiReportStoreError> {
        let connection = self.lock()?;
        connection.execute(
            "INSERT INTO ai_report_settings (setting_key, setting_value) VALUES (?1, ?2) \
             ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value",
            params![key, value],
        )?;
        Ok(())
    }
}

impl AiReportStore for SqliteAiReportStore {
    fn load_latest_reports(&self) -> Result<Vec<AiRecapDto>, AiReportStoreError> {
        let connection = self.lock()?;
        let mut statement = connection.prepare(
            "SELECT scope, report_json FROM ai_latest_reports \
             WHERE schema_version = 1 AND scope IN ('daily', 'weekly', 'monthly') \
             ORDER BY generated_at_utc DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut reports = Vec::with_capacity(3);
        for row in rows {
            let (scope, json) = row?;
            if json.len() > MAX_REPORT_JSON_BYTES {
                tracing::warn!("ignored oversized persisted AI report");
                continue;
            }
            match serde_json::from_str::<AiRecapDto>(&json) {
                Ok(report) if report.scope == scope => reports.push(report),
                Ok(_) => tracing::warn!("ignored mismatched persisted AI report scope"),
                Err(_) => tracing::warn!("ignored malformed persisted AI report"),
            }
        }
        Ok(reports)
    }

    fn save_latest_report(&self, report: &AiRecapDto) -> Result<(), AiReportStoreError> {
        if !matches!(report.scope.as_str(), "daily" | "weekly" | "monthly") {
            return Err(AiReportStoreError::InvalidReport);
        }
        let json = serde_json::to_string(report).map_err(|_| AiReportStoreError::InvalidReport)?;
        if json.len() > MAX_REPORT_JSON_BYTES {
            return Err(AiReportStoreError::InvalidReport);
        }
        let mut connection = self.lock()?;
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO ai_latest_reports (scope, schema_version, generated_at_utc, report_json) \
             VALUES (?1, 1, ?2, ?3) \
             ON CONFLICT(scope) DO UPDATE SET \
               schema_version = 1, \
               generated_at_utc = excluded.generated_at_utc, \
               report_json = excluded.report_json",
            params![report.scope, report.generated_at_utc, json],
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn clear_latest_reports(&self) -> Result<(), AiReportStoreError> {
        self.lock()?.execute("DELETE FROM ai_latest_reports", [])?;
        Ok(())
    }

    fn load_default_model(&self) -> Result<Option<String>, AiReportStoreError> {
        self.load_setting("default_model")
    }

    fn save_default_model(&self, model: &str) -> Result<(), AiReportStoreError> {
        self.save_setting("default_model", model)
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::{Connection, params};

    use super::{AiReportStore, AiReportStoreError, MAX_REPORT_JSON_BYTES, SqliteAiReportStore};
    use crate::ai_recap::{AiRecapDto, AiRecapEvidenceDto, AiRecapStatementDto};

    fn report(scope: &str, generated_at_utc: &str) -> AiRecapDto {
        let statement = AiRecapStatementDto {
            text: "本期共记录15分钟活动。".to_owned(),
            evidence: vec![AiRecapEvidenceDto {
                app_name: "编辑器".to_owned(),
                active_seconds: 900,
            }],
        };
        AiRecapDto {
            scope: scope.to_owned(),
            start_date: "2026-08-24".to_owned(),
            end_date: "2026-08-24".to_owned(),
            generated_at_utc: generated_at_utc.to_owned(),
            model: "deepseek-v4-flash".to_owned(),
            summary: statement.clone(),
            highlights: vec![statement.clone()],
            suggestions: vec![statement],
            top_applications: vec![AiRecapEvidenceDto {
                app_name: "编辑器".to_owned(),
                active_seconds: 900,
            }],
            total_active_seconds: 900,
            application_count: 1,
        }
    }

    #[test]
    fn settings_and_latest_report_survive_store_reloads() {
        let store = SqliteAiReportStore::from_connection(
            Connection::open_in_memory().expect("in-memory database"),
        )
        .expect("create report store");

        assert_eq!(store.load_default_model().expect("load model"), None);
        store
            .save_default_model("deepseek-v4-pro")
            .expect("save model");
        store
            .save_latest_report(&report("daily", "2026-08-24T10:00:00Z"))
            .expect("save daily report");
        store
            .save_latest_report(&report("daily", "2026-08-24T11:00:00Z"))
            .expect("replace daily report");

        assert_eq!(
            store.load_default_model().expect("reload model").as_deref(),
            Some("deepseek-v4-pro")
        );
        let reports = store.load_latest_reports().expect("load reports");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].generated_at_utc, "2026-08-24T11:00:00Z");

        store.clear_latest_reports().expect("clear reports");
        assert!(
            store
                .load_latest_reports()
                .expect("load cleared reports")
                .is_empty()
        );
        assert_eq!(
            store
                .load_default_model()
                .expect("settings preserved")
                .as_deref(),
            Some("deepseek-v4-pro")
        );
    }

    #[test]
    fn opening_store_removes_pre_release_fallback_override() {
        let connection = Connection::open_in_memory().expect("in-memory database");
        connection
            .execute_batch(
                "CREATE TABLE ai_report_settings (\
                   setting_key TEXT PRIMARY KEY NOT NULL,\
                   setting_value TEXT NOT NULL\
                 );\
                 INSERT INTO ai_report_settings (setting_key, setting_value)\
                 VALUES ('environment_fallback_enabled', 'false');",
            )
            .expect("seed legacy setting");

        let store = SqliteAiReportStore::from_connection(connection).expect("open report store");
        let legacy_setting = store
            .load_setting("environment_fallback_enabled")
            .expect("query legacy setting");

        assert_eq!(legacy_setting, None);
    }

    #[test]
    fn one_malformed_report_does_not_hide_other_valid_types() {
        let store = SqliteAiReportStore::from_connection(
            Connection::open_in_memory().expect("in-memory database"),
        )
        .expect("create report store");
        for (scope, generated_at) in [
            ("daily", "2026-08-24T10:00:00Z"),
            ("weekly", "2026-08-24T11:00:00Z"),
            ("monthly", "2026-08-24T12:00:00Z"),
        ] {
            store
                .save_latest_report(&report(scope, generated_at))
                .expect("save valid report");
        }
        store
            .lock()
            .expect("lock report store")
            .execute(
                "UPDATE ai_latest_reports SET report_json = '{' WHERE scope = 'weekly'",
                [],
            )
            .expect("corrupt one report");

        let reports = store.load_latest_reports().expect("load valid reports");
        let scopes = reports
            .iter()
            .map(|report| report.scope.as_str())
            .collect::<Vec<_>>();
        assert_eq!(scopes, vec!["monthly", "daily"]);
    }

    #[test]
    fn reports_over_64_kib_are_rejected_on_write_and_ignored_on_read() {
        let store = SqliteAiReportStore::from_connection(
            Connection::open_in_memory().expect("in-memory database"),
        )
        .expect("create report store");
        let mut oversized = report("daily", "2026-08-24T10:00:00Z");
        oversized.summary.text = "x".repeat(MAX_REPORT_JSON_BYTES);
        assert!(matches!(
            store.save_latest_report(&oversized),
            Err(AiReportStoreError::InvalidReport)
        ));

        store
            .save_latest_report(&report("daily", "2026-08-24T10:00:00Z"))
            .expect("save daily report");
        store
            .save_latest_report(&report("weekly", "2026-08-24T11:00:00Z"))
            .expect("save weekly report");
        store
            .lock()
            .expect("lock report store")
            .execute(
                "UPDATE ai_latest_reports SET report_json = ?1 WHERE scope = 'daily'",
                ["x".repeat(MAX_REPORT_JSON_BYTES + 1)],
            )
            .expect("inject oversized persisted report");

        let reports = store.load_latest_reports().expect("load bounded reports");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].scope, "weekly");
    }

    #[test]
    fn loader_filters_unknown_scopes_and_future_schema_versions() {
        let connection = Connection::open_in_memory().expect("in-memory database");
        connection
            .execute_batch(
                "CREATE TABLE ai_latest_reports (\
                    scope TEXT PRIMARY KEY NOT NULL, \
                    schema_version INTEGER NOT NULL, \
                    generated_at_utc TEXT NOT NULL, \
                    report_json TEXT NOT NULL\
                );",
            )
            .expect("create permissive legacy table");
        for (scope, schema_version, generated_at) in [
            ("daily", 1_i64, "2026-08-24T10:00:00Z"),
            ("weekly", 2_i64, "2026-08-24T11:00:00Z"),
            ("yearly", 1_i64, "2026-08-24T12:00:00Z"),
        ] {
            let json = serde_json::to_string(&report(scope, generated_at))
                .expect("serialize fixture report");
            connection
                .execute(
                    "INSERT INTO ai_latest_reports \
                     (scope, schema_version, generated_at_utc, report_json) \
                     VALUES (?1, ?2, ?3, ?4)",
                    params![scope, schema_version, generated_at, json],
                )
                .expect("seed permissive table");
        }
        let store =
            SqliteAiReportStore::from_connection(connection).expect("open permissive legacy table");

        let reports = store.load_latest_reports().expect("load filtered reports");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].scope, "daily");
    }
}
