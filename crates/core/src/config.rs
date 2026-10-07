//! Configuration management.
//!
//! Reads/writes the user configuration only on an explicit save.

use std::io::{Error, ErrorKind};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tracing::warn;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Polling interval in milliseconds. Legacy reads normalize in memory only.
    #[serde(default = "default_poll_interval")]
    pub poll_interval_ms: u64,

    /// Idle threshold in minutes.
    #[serde(default = "default_idle_threshold")]
    pub idle_threshold_minutes: u64,

    /// Whether to minimize to system tray on close.
    #[serde(default = "default_true")]
    pub minimize_to_tray: bool,

    /// Whether to start minimized.
    #[serde(default)]
    pub start_minimized: bool,

    /// Whether to auto-start tracking on launch.
    #[serde(default = "default_true")]
    pub auto_start_tracking: bool,

    /// Applications to exclude from tracking (by exe name).
    #[serde(default)]
    pub excluded_apps: Vec<String>,

    /// Preserve unrecognized configuration fields without exposing new DTOs.
    #[serde(flatten, default)]
    pub extra_fields: serde_json::Map<String, serde_json::Value>,
}

fn default_poll_interval() -> u64 { AppConfig::DEFAULT_POLL_INTERVAL_MS }
fn default_idle_threshold() -> u64 { 5 }
fn default_true() -> bool { true }

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            poll_interval_ms: Self::DEFAULT_POLL_INTERVAL_MS,
            idle_threshold_minutes: 5,
            minimize_to_tray: true,
            start_minimized: false,
            auto_start_tracking: true,
            excluded_apps: Vec::new(),
            extra_fields: serde_json::Map::new(),
        }
    }
}

impl AppConfig {
    pub const MIN_POLL_INTERVAL_MS: u64 = 30000;
    pub const MAX_POLL_INTERVAL_MS: u64 = 60000;
    pub const DEFAULT_POLL_INTERVAL_MS: u64 = Self::MIN_POLL_INTERVAL_MS;

    /// Strict new-write validation. Never normalize an explicit invalid input.
    pub fn validate_poll_interval(milliseconds: u64) -> Result<(), Error> {
        if (Self::MIN_POLL_INTERVAL_MS..=Self::MAX_POLL_INTERVAL_MS).contains(&milliseconds) {
            Ok(())
        } else {
            Err(Error::new(ErrorKind::InvalidInput,
                "poll_interval_ms must be between 30000 and 60000"))
        }
    }

    /// Legacy read compatibility only; no file access or automatic migration.
    pub fn effective_poll_interval(milliseconds: u64) -> u64 {
        milliseconds.clamp(Self::MIN_POLL_INTERVAL_MS, Self::MAX_POLL_INTERVAL_MS)
    }

    /// Pure structural decode shared with the real explicit-update path.
    /// Preserve a legacy poll until the incoming valid DTO replaces it.
    fn decode_for_update(contents: &str) -> Result<Self, Error> {
        let value: serde_json::Value = serde_json::from_str(contents)
            .map_err(|error| Error::new(ErrorKind::InvalidData, error))?;
        if !value.is_object() {
            return Err(Error::new(ErrorKind::InvalidData, "config must be a JSON object"));
        }
        serde_json::from_value(value)
            .map_err(|error| Error::new(ErrorKind::InvalidData, error))
    }

    /// Pure effective read, also used by load. Does not rewrite the input.
    fn decode_for_read(contents: &str) -> Result<Self, Error> {
        let mut config = Self::decode_for_update(contents)?;
        config.poll_interval_ms = Self::effective_poll_interval(config.poll_interval_ms);
        Ok(config)
    }

    /// Validate and encode completely before resolving a path or touching IO.
    fn encode_for_update(&self) -> Result<String, Error> {
        Self::validate_poll_interval(self.poll_interval_ms)?;
        for key in ["poll_interval_ms", "idle_threshold_minutes", "minimize_to_tray",
            "start_minimized", "auto_start_tracking", "excluded_apps"] {
            if self.extra_fields.contains_key(key) {
                return Err(Error::new(ErrorKind::InvalidInput,
                    "preserved config field cannot shadow a known field"));
            }
        }
        serde_json::to_string_pretty(self)
            .map_err(|error| Error::new(ErrorKind::InvalidData, error))
    }

    /// Effective read with a read-only fallback. Missing/corrupt files are not saved.
    pub fn load() -> Self {
        let path = Self::config_path();
        match std::fs::read_to_string(&path) {
            Ok(contents) => Self::decode_for_read(&contents).unwrap_or_else(|error| {
                warn!("Failed to parse config, using in-memory defaults: {error}");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    /// Explicit updates may start defaults only when the file is absent.
    /// Permission/read/parse/type errors must not be replaced with defaults.
    pub fn try_load_for_update() -> Result<Self, Error> {
        match std::fs::read_to_string(Self::config_path()) {
            Ok(contents) => Self::decode_for_update(&contents),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(error),
        }
    }

    /// Save only a valid, fully encoded explicit intent.
    pub fn save(&self) -> Result<(), Error> {
        let json = self.encode_for_update()?;
        let path = Self::config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, json)
    }

    fn config_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("TimeTrace")
            .join("config.json")
    }
}

#[cfg(test)]
mod tests {
    use super::AppConfig;
    use serde_json::json;

    #[test]
    fn polling_default_effective_and_bounds_are_consistent() {
        assert_eq!(AppConfig::default().poll_interval_ms, 30000);
        assert_eq!(serde_json::from_str::<AppConfig>("{}").unwrap().poll_interval_ms, 30000);
        for (raw, effective, valid) in [
            (0, 30000, false), (500, 30000, false), (1000, 30000, false),
            (3000, 30000, false), (29999, 30000, false), (30000, 30000, true),
            (30001, 30001, true), (59999, 59999, true), (60000, 60000, true),
            (60001, 60000, false), (u64::MAX, 60000, false),
        ] {
            assert_eq!(AppConfig::effective_poll_interval(raw), effective);
            assert_eq!(AppConfig::validate_poll_interval(raw).is_ok(), valid);
        }
    }

    #[test]
    fn legacy_polling_decode_is_read_only_and_preserves_other_fields() {
        for raw in [0, 500, 1000, 3000, 29999, 30000, 60000, 60001, u64::MAX] {
            let source = json!({
                "poll_interval_ms": raw, "idle_threshold_minutes": 12,
                "minimize_to_tray": false, "start_minimized": true,
                "auto_start_tracking": false, "excluded_apps": ["fixture.exe"],
                "unknown": {"nested": [1, true, null, {"keep": "value"}]}
            }).to_string();
            let original = source.clone();
            let config = AppConfig::decode_for_read(&source).unwrap();
            assert_eq!(source, original);
            assert_eq!(config.poll_interval_ms, AppConfig::effective_poll_interval(raw));
            assert_eq!(config.idle_threshold_minutes, 12);
            assert!(!config.minimize_to_tray);
            assert!(config.start_minimized);
            assert!(!config.auto_start_tracking);
            assert_eq!(config.excluded_apps, ["fixture.exe"]);
            assert_eq!(config.extra_fields["unknown"], json!({"nested": [1, true, null, {"keep": "value"}]}));
        }
        assert_eq!(AppConfig::decode_for_read("{}").unwrap().poll_interval_ms, 30000);
    }

    #[test]
    fn explicit_config_update_rejects_corrupt_input_and_preserves_unknown_fields() {
        for invalid in ["{broken", "[]", "null", "42",
            r#"{"poll_interval_ms":"30000"}"#, r#"{"idle_threshold_minutes":false}"#,
            r#"{"minimize_to_tray":0}"#, r#"{"start_minimized":"true"}"#,
            r#"{"auto_start_tracking":null}"#, r#"{"excluded_apps":[1]}"#] {
            assert!(AppConfig::decode_for_update(invalid).is_err(), "{invalid}");
        }
        let source = json!({
            "poll_interval_ms": 3000, "idle_threshold_minutes": 12,
            "minimize_to_tray": false, "start_minimized": true,
            "auto_start_tracking": false, "excluded_apps": ["fixture.exe"],
            "unknown": {"nested": [null, {"keep": 7}]}
        });
        let mut config = AppConfig::decode_for_update(&source.to_string()).unwrap();
        assert_eq!(config.poll_interval_ms, 3000);
        assert!(config.encode_for_update().is_err());
        config.poll_interval_ms = 30000;
        let encoded: serde_json::Value = serde_json::from_str(&config.encode_for_update().unwrap()).unwrap();
        let mut expected = source;
        expected["poll_interval_ms"] = json!(30000);
        assert_eq!(encoded, expected);
        let reopened = AppConfig::decode_for_update(&encoded.to_string()).unwrap();
        assert_eq!(reopened.poll_interval_ms, 30000);
        assert_eq!(reopened.extra_fields["unknown"], expected["unknown"]);
    }

    #[test]
    fn config_extra_fields_cannot_shadow_known_fields() {
        for key in ["poll_interval_ms", "idle_threshold_minutes", "minimize_to_tray",
            "start_minimized", "auto_start_tracking", "excluded_apps"] {
            let mut config = AppConfig::default();
            config.extra_fields.insert(key.to_owned(), json!("collision"));
            assert!(config.encode_for_update().is_err(), "{key}");
        }
        let mut config = AppConfig::default();
        config.extra_fields.insert("unknown".to_owned(), json!({"nested": [1, 2]}));
        let encoded: serde_json::Value = serde_json::from_str(&config.encode_for_update().unwrap()).unwrap();
        assert_eq!(encoded["unknown"], json!({"nested": [1, 2]}));
        for invalid in [0, 500, 29999, 60001, u64::MAX] {
            config.poll_interval_ms = invalid;
            assert!(config.encode_for_update().is_err());
        }
    }
}
