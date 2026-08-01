//! Configuration management.
//!
//! Reads/writes `%APPDATA%\TimeTrace\config.json`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tracing::warn;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Polling interval in milliseconds.
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
}

fn default_poll_interval() -> u64 { 1000 }
fn default_idle_threshold() -> u64 { 5 }
fn default_true() -> bool { true }

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            poll_interval_ms: 1000,
            idle_threshold_minutes: 5,
            minimize_to_tray: true,
            start_minimized: false,
            auto_start_tracking: true,
            excluded_apps: Vec::new(),
        }
    }
}

impl AppConfig {
    /// Load config from the default path, or return defaults.
    pub fn load() -> Self {
        let path = Self::config_path();
        match std::fs::read_to_string(&path) {
            Ok(contents) => {
                serde_json::from_str(&contents).unwrap_or_else(|e| {
                    warn!("Failed to parse config, using defaults: {e}");
                    Self::default()
                })
            }
            Err(_) => {
                // No config file yet — create with defaults
                let config = Self::default();
                let _ = config.save();
                config
            }
        }
    }

    /// Save config to the default path.
    pub fn save(&self) -> Result<(), std::io::Error> {
        let path = Self::config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        std::fs::write(path, json)
    }

    fn config_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("TimeTrace")
            .join("config.json")
    }
}
