//! Configuration management.
//!
//! Persists per-user configuration in TimeTrace's platform-native app support
//! directory (`%APPDATA%` on Windows, Application Support on macOS).

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::paths::config_path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Polling interval in milliseconds.
    #[serde(default = "default_poll_interval")]
    pub poll_interval_ms: u64,

    /// Idle threshold in minutes.
    #[serde(default = "default_idle_threshold")]
    pub idle_threshold_minutes: u64,

    /// Whether to minimize/hide to the platform background status area on close.
    #[serde(default = "default_true")]
    pub minimize_to_tray: bool,

    /// Whether to start with the main window hidden.
    #[serde(default)]
    pub start_minimized: bool,

    /// Whether to auto-start tracking on launch.
    #[serde(default = "default_true")]
    pub auto_start_tracking: bool,

    /// Applications to exclude from tracking (process or display name).
    #[serde(default)]
    pub excluded_apps: Vec<String>,

    /// Optional database file selected by the desktop UI.
    /// Empty keeps the platform-native TimeTrace location.
    #[serde(default)]
    pub db_path: String,
}

fn default_poll_interval() -> u64 { 3000 }
fn default_idle_threshold() -> u64 { 5 }
fn default_true() -> bool { true }

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            poll_interval_ms: 3000,
            idle_threshold_minutes: 5,
            minimize_to_tray: true,
            start_minimized: false,
            auto_start_tracking: true,
            excluded_apps: Vec::new(),
            db_path: String::new(),
        }
    }
}

impl AppConfig {
    /// Load config from the default path, or return defaults.
    pub fn load() -> Self {
        let path = config_path();
        match std::fs::read_to_string(&path) {
            Ok(contents) => serde_json::from_str(&contents).unwrap_or_else(|e| {
                warn!("Failed to parse config, using defaults: {e}");
                Self::default()
            }),
            Err(_) => {
                // No config file yet — create with defaults.
                let config = Self::default();
                let _ = config.save();
                config
            }
        }
    }

    /// Save config to the default path.
    pub fn save(&self) -> Result<(), std::io::Error> {
        let path = config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_config_defaults_to_platform_database() {
        let config: AppConfig = serde_json::from_str(
            r#"{"poll_interval_ms":1000,"idle_threshold_minutes":5}"#,
        )
        .expect("old config remains readable");
        assert!(config.db_path.is_empty());
    }
}
