//! Configuration management.
//!
//! Persists per-user configuration in TimeTrace's platform-native app support
//! directory (`%APPDATA%` on Windows, Application Support on macOS).

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::paths::config_path;

/// Persisted Pomodoro preferences.
///
/// Runtime countdown state is intentionally not stored here. Existing
/// installations deserialize this nested object through `Default`, keeping
/// the capability quiet until the user explicitly enables it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PomodoroConfig {
    /// Whether the Pomodoro capability is enabled.
    pub enabled: bool,
    /// Duration of a focus phase in minutes.
    pub focus_minutes: u64,
    /// Duration of a short break in minutes.
    pub short_break_minutes: u64,
    /// Duration of a long break in minutes.
    pub long_break_minutes: u64,
    /// Number of naturally completed focus phases before a long break.
    pub long_break_interval: u64,
    /// Whether a newly selected phase begins immediately.
    pub auto_start_next: bool,
    /// Whether phase-boundary notifications are delivered.
    pub notifications_enabled: bool,
    /// Whether phase-boundary notifications may play sound.
    pub notification_sound: bool,
}

impl Default for PomodoroConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            focus_minutes: 25,
            short_break_minutes: 5,
            long_break_minutes: 15,
            long_break_interval: 4,
            auto_start_next: false,
            notifications_enabled: true,
            notification_sound: true,
        }
    }
}

/// Persisted application continuous-use reminder preferences.
///
/// Individual executable rules live in SQLite. These values provide the
/// global opt-in and defaults used when creating a new rule.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppTimeoutConfig {
    /// Whether application timeout evaluation is enabled.
    pub enabled: bool,
    /// Initial threshold offered for a new rule, in minutes.
    pub default_threshold_minutes: u64,
    /// Initial repeat cooldown offered for a new rule, in minutes.
    pub default_cooldown_minutes: u64,
    /// Whether timeout notifications are delivered.
    pub notifications_enabled: bool,
    /// Whether timeout notifications may play sound.
    pub notification_sound: bool,
}

impl Default for AppTimeoutConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            default_threshold_minutes: 60,
            default_cooldown_minutes: 30,
            notifications_enabled: true,
            notification_sound: true,
        }
    }
}

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

    /// Pomodoro preferences. Missing values use quiet upgrade defaults.
    #[serde(default)]
    pub pomodoro: PomodoroConfig,

    /// Application timeout preferences. Missing values use quiet defaults.
    #[serde(default)]
    pub app_timeout: AppTimeoutConfig,
}

fn default_poll_interval() -> u64 {
    3000
}
fn default_idle_threshold() -> u64 {
    5
}
fn default_true() -> bool {
    true
}

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
            pomodoro: PomodoroConfig::default(),
            app_timeout: AppTimeoutConfig::default(),
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
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_config_defaults_to_platform_database() {
        let config: AppConfig =
            serde_json::from_str(r#"{"poll_interval_ms":1000,"idle_threshold_minutes":5}"#)
                .expect("old config remains readable");
        assert!(config.db_path.is_empty());
        assert_eq!(config.pomodoro, PomodoroConfig::default());
        assert_eq!(config.app_timeout, AppTimeoutConfig::default());
        assert!(!config.pomodoro.enabled);
        assert!(!config.app_timeout.enabled);
    }

    #[test]
    fn nested_config_defaults_are_complete_and_quiet() {
        let config = AppConfig::default();
        assert_eq!(config.pomodoro.focus_minutes, 25);
        assert_eq!(config.pomodoro.short_break_minutes, 5);
        assert_eq!(config.pomodoro.long_break_minutes, 15);
        assert_eq!(config.pomodoro.long_break_interval, 4);
        assert!(!config.pomodoro.auto_start_next);
        assert!(config.pomodoro.notifications_enabled);
        assert!(config.pomodoro.notification_sound);

        assert_eq!(config.app_timeout.default_threshold_minutes, 60);
        assert_eq!(config.app_timeout.default_cooldown_minutes, 30);
        assert!(config.app_timeout.notifications_enabled);
        assert!(config.app_timeout.notification_sound);
    }

    #[test]
    fn partial_nested_config_uses_field_defaults() {
        let config: AppConfig = serde_json::from_str(
            r#"{"pomodoro":{"enabled":true,"focus_minutes":50},"app_timeout":{"enabled":true}}"#,
        )
        .expect("partial nested config remains readable");

        assert!(config.pomodoro.enabled);
        assert_eq!(config.pomodoro.focus_minutes, 50);
        assert_eq!(config.pomodoro.short_break_minutes, 5);
        assert!(config.app_timeout.enabled);
        assert_eq!(config.app_timeout.default_threshold_minutes, 60);
    }
}
