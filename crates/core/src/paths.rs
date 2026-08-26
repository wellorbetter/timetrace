//! Platform-native TimeTrace storage locations.
//!
//! Keep filesystem policy inside the Rust core so every Rust frontend uses the
//! same config/database/log roots. Flutter has a small mirror for UI-only files
//! (app log/preferences/export), but business data paths originate here.

use std::path::PathBuf;

pub const APP_DIR_NAME: &str = "TimeTrace";

/// Per-user application support/config directory.
///
/// - Windows: `%APPDATA%/TimeTrace`
/// - macOS: `~/Library/Application Support/TimeTrace`
/// - Linux: `$XDG_CONFIG_HOME/TimeTrace` (or `~/.config/TimeTrace`)
pub fn app_data_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(APP_DIR_NAME)
}

pub fn config_path() -> PathBuf {
    app_data_dir().join("config.json")
}

pub fn database_path() -> PathBuf {
    app_data_dir().join("time.db")
}

pub fn rust_log_path() -> PathBuf {
    app_data_dir().join("timetrace.log")
}

pub fn ensure_app_data_dir() -> std::io::Result<PathBuf> {
    let dir = app_data_dir();
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_files_share_one_root() {
        let root = app_data_dir();
        assert_eq!(config_path().parent(), Some(root.as_path()));
        assert_eq!(database_path().parent(), Some(root.as_path()));
        assert_eq!(rust_log_path().parent(), Some(root.as_path()));
    }
}
