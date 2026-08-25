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
const LOCAL_PROVIDER_ID: &str = "local_summary";
const LOCAL_MODEL_ID: &str = "local-summary-v1";
const DEEPSEEK_PROVIDER_ID: &str = "deepseek";
const DEEPSEEK_DEFAULT_MODEL_ID: &str = "deepseek-v4-flash";
const DEEPSEEK_PRO_MODEL_ID: &str = "deepseek-v4-pro";
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
    /// A provider/model preference was outside the feature allowlist.
    #[error("AI report provider selection is invalid")]
    InvalidSelection,
}

/// Persisted, non-secret provider/model selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiProviderSelectionRecord {
    /// Closed provider identifier.
    pub provider_id: String,
    /// Closed model identifier belonging to the provider.
    pub model_id: String,
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
    /// Loads the atomically persisted provider/model selection.
    fn load_provider_selection(&self) -> Result<AiProviderSelectionRecord, AiReportStoreError>;
    /// Atomically persists one validated provider/model pair.
    fn save_provider_selection(
        &self,
        provider_id: &str,
        model_id: &str,
    ) -> Result<(), AiReportStoreError>;
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

    fn load_provider_selection(&self) -> Result<AiProviderSelectionRecord, AiReportStoreError> {
        Err(AiReportStoreError::Unavailable)
    }

    fn save_provider_selection(
        &self,
        _provider_id: &str,
        _model_id: &str,
    ) -> Result<(), AiReportStoreError> {
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

    fn from_connection(mut connection: Connection) -> Result<Self, AiReportStoreError> {
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
        if provider_settings_need_migration(&connection)? {
            migrate_provider_settings(&mut connection)?;
        }
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
}

fn provider_settings_need_migration(connection: &Connection) -> Result<bool, AiReportStoreError> {
    let (current_settings, legacy_settings) = connection.query_row(
        "SELECT \
           COALESCE(SUM(CASE WHEN setting_key IN \
             ('selected_provider', 'model.local_summary', 'model.deepseek') \
             THEN 1 ELSE 0 END), 0), \
           COALESCE(SUM(CASE WHEN setting_key IN \
             ('default_model', 'environment_fallback_enabled') \
             THEN 1 ELSE 0 END), 0) \
         FROM ai_report_settings",
        [],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
    )?;
    Ok(current_settings != 3 || legacy_settings != 0)
}

fn migrate_provider_settings(connection: &mut Connection) -> Result<(), AiReportStoreError> {
    let transaction = connection.transaction()?;
    let selected_provider = transaction
        .query_row(
            "SELECT setting_value FROM ai_report_settings WHERE setting_key = 'selected_provider'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let legacy_model = transaction
        .query_row(
            "SELECT setting_value FROM ai_report_settings WHERE setting_key = 'default_model'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let has_legacy_report = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM ai_latest_reports WHERE schema_version = 1 LIMIT 1)",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    let deepseek_model = match legacy_model.as_deref() {
        Some(DEEPSEEK_PRO_MODEL_ID) => DEEPSEEK_PRO_MODEL_ID,
        _ => DEEPSEEK_DEFAULT_MODEL_ID,
    };
    let selected_provider =
        selected_provider
            .as_deref()
            .unwrap_or(if legacy_model.is_some() || has_legacy_report {
                DEEPSEEK_PROVIDER_ID
            } else {
                LOCAL_PROVIDER_ID
            });

    for (key, value) in [
        ("selected_provider", selected_provider),
        ("model.local_summary", LOCAL_MODEL_ID),
        ("model.deepseek", deepseek_model),
    ] {
        transaction.execute(
            "INSERT OR IGNORE INTO ai_report_settings (setting_key, setting_value) VALUES (?1, ?2)",
            params![key, value],
        )?;
    }
    // Remove pre-release compatibility rows after their values have been
    // migrated. This also makes the steady-state startup path read-only.
    transaction.execute(
        "DELETE FROM ai_report_settings WHERE setting_key IN \
         ('default_model', 'environment_fallback_enabled')",
        [],
    )?;
    transaction.commit()?;
    Ok(())
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

    fn load_provider_selection(&self) -> Result<AiProviderSelectionRecord, AiReportStoreError> {
        let provider_id = self
            .load_setting("selected_provider")?
            .ok_or(AiReportStoreError::InvalidSelection)?;
        let model_key = match provider_id.as_str() {
            LOCAL_PROVIDER_ID => "model.local_summary",
            DEEPSEEK_PROVIDER_ID => "model.deepseek",
            _ => {
                return Ok(AiProviderSelectionRecord {
                    provider_id,
                    model_id: String::new(),
                });
            }
        };
        let model_id = self
            .load_setting(model_key)?
            .ok_or(AiReportStoreError::InvalidSelection)?;
        Ok(AiProviderSelectionRecord {
            provider_id,
            model_id,
        })
    }

    fn save_provider_selection(
        &self,
        provider_id: &str,
        model_id: &str,
    ) -> Result<(), AiReportStoreError> {
        let model_key = match (provider_id, model_id) {
            (LOCAL_PROVIDER_ID, LOCAL_MODEL_ID) => "model.local_summary",
            (DEEPSEEK_PROVIDER_ID, DEEPSEEK_DEFAULT_MODEL_ID | DEEPSEEK_PRO_MODEL_ID) => {
                "model.deepseek"
            }
            _ => return Err(AiReportStoreError::InvalidSelection),
        };
        let mut connection = self.lock()?;
        let transaction = connection.transaction()?;
        for (key, value) in [("selected_provider", provider_id), (model_key, model_id)] {
            transaction.execute(
                "INSERT INTO ai_report_settings (setting_key, setting_value) VALUES (?1, ?2) \
                 ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value",
                params![key, value],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

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
            provider_id: "deepseek".to_owned(),
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

        assert_eq!(
            store.load_provider_selection().expect("load selection"),
            super::AiProviderSelectionRecord {
                provider_id: "local_summary".to_owned(),
                model_id: "local-summary-v1".to_owned(),
            }
        );
        store
            .save_provider_selection("deepseek", "deepseek-v4-pro")
            .expect("save selection");
        store
            .save_latest_report(&report("daily", "2026-08-24T10:00:00Z"))
            .expect("save daily report");
        store
            .save_latest_report(&report("daily", "2026-08-24T11:00:00Z"))
            .expect("replace daily report");

        assert_eq!(
            store.load_provider_selection().expect("reload selection"),
            super::AiProviderSelectionRecord {
                provider_id: "deepseek".to_owned(),
                model_id: "deepseek-v4-pro".to_owned(),
            }
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
            store.load_provider_selection().expect("settings preserved"),
            super::AiProviderSelectionRecord {
                provider_id: "deepseek".to_owned(),
                model_id: "deepseek-v4-pro".to_owned(),
            }
        );
    }

    #[test]
    fn reports_and_selection_survive_real_file_close_and_reopen() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "timetrace-ai-report-{}-{nonce}.sqlite",
            std::process::id()
        ));

        {
            let store = SqliteAiReportStore::open(path.clone()).expect("create file store");
            store
                .save_provider_selection("deepseek", "deepseek-v4-pro")
                .expect("save provider selection");
            store
                .save_latest_report(&report("monthly", "2026-08-24T12:00:00Z"))
                .expect("save monthly report");
        }

        {
            let reopened = SqliteAiReportStore::open(path.clone()).expect("reopen file store");
            assert_eq!(
                reopened
                    .load_provider_selection()
                    .expect("load provider selection"),
                super::AiProviderSelectionRecord {
                    provider_id: "deepseek".to_owned(),
                    model_id: "deepseek-v4-pro".to_owned(),
                }
            );
            let reports = reopened.load_latest_reports().expect("load reports");
            assert_eq!(reports.len(), 1);
            assert_eq!(reports[0].scope, "monthly");
        }

        let _ = std::fs::remove_file(path.with_extension("sqlite-wal"));
        let _ = std::fs::remove_file(path.with_extension("sqlite-shm"));
        std::fs::remove_file(path).expect("remove temporary report store");
    }

    #[test]
    fn initialized_provider_settings_need_no_steady_state_migration() {
        let store = SqliteAiReportStore::from_connection(
            Connection::open_in_memory().expect("in-memory database"),
        )
        .expect("create report store");
        let connection = store.lock().expect("report store lock");

        assert!(!super::provider_settings_need_migration(&connection).expect("migration check"));
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
    fn legacy_default_model_migrates_to_deepseek_selection() {
        let connection = Connection::open_in_memory().expect("in-memory database");
        connection
            .execute_batch(
                "CREATE TABLE ai_report_settings (\
                   setting_key TEXT PRIMARY KEY NOT NULL,\
                   setting_value TEXT NOT NULL\
                 );\
                 INSERT INTO ai_report_settings (setting_key, setting_value)\
                 VALUES ('default_model', 'deepseek-v4-pro');",
            )
            .expect("seed legacy model");

        let store = SqliteAiReportStore::from_connection(connection).expect("migrate store");

        assert_eq!(
            store.load_provider_selection().expect("migrated selection"),
            super::AiProviderSelectionRecord {
                provider_id: "deepseek".to_owned(),
                model_id: "deepseek-v4-pro".to_owned(),
            }
        );
    }

    #[test]
    fn legacy_report_without_provider_migrates_and_loads_as_deepseek() {
        let connection = Connection::open_in_memory().expect("in-memory database");
        connection
            .execute_batch(super::CREATE_SCHEMA)
            .expect("create legacy-compatible schema");
        let mut legacy_json = serde_json::to_value(report("weekly", "2026-08-24T11:00:00Z"))
            .expect("serialize report");
        legacy_json
            .as_object_mut()
            .expect("report object")
            .remove("provider_id");
        connection
            .execute(
                "INSERT INTO ai_latest_reports \
                 (scope, schema_version, generated_at_utc, report_json) \
                 VALUES ('weekly', 1, '2026-08-24T11:00:00Z', ?1)",
                [legacy_json.to_string()],
            )
            .expect("seed legacy report");

        let store = SqliteAiReportStore::from_connection(connection).expect("migrate store");

        assert_eq!(
            store.load_provider_selection().expect("migrated selection"),
            super::AiProviderSelectionRecord {
                provider_id: "deepseek".to_owned(),
                model_id: "deepseek-v4-flash".to_owned(),
            }
        );
        let reports = store.load_latest_reports().expect("load legacy report");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].provider_id, "deepseek");
    }

    #[test]
    fn invalid_provider_model_pair_is_rejected_atomically() {
        let store = SqliteAiReportStore::from_connection(
            Connection::open_in_memory().expect("in-memory database"),
        )
        .expect("create report store");
        let original = store.load_provider_selection().expect("initial selection");

        assert!(matches!(
            store.save_provider_selection("deepseek", "local-summary-v1"),
            Err(AiReportStoreError::InvalidSelection)
        ));
        assert_eq!(
            store
                .load_provider_selection()
                .expect("preserved selection"),
            original
        );
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
