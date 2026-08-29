//! Linux startup support.
//!
//! TimeTrace manages its own freedesktop autostart entry. Enumerating and
//! mutating arbitrary desktop startup entries is intentionally not attempted.

use std::fs;
use std::path::PathBuf;

use crate::contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};

const DESKTOP_FILE_NAME: &str = "com.wellorbetter.timetrace.desktop";

pub struct LinuxStartupScanner;

impl LinuxStartupScanner {
    pub fn new() -> Self {
        Self
    }
}

impl StartupScanner for LinuxStartupScanner {
    fn scan(&self) -> Vec<StartupEntryRecord> {
        Vec::new()
    }

    fn disable(&self, _entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        Err("Linux arbitrary startup-entry management is not supported".into())
    }

    fn enable(&self, _entry: &StartupEntryRecord) -> Result<(), String> {
        Err("Linux arbitrary startup-entry management is not supported".into())
    }
}

fn autostart_dir() -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os("XDG_CONFIG_HOME") {
        return Ok(PathBuf::from(value).join("autostart"));
    }
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join(".config/autostart"))
}

fn self_start_path() -> Result<PathBuf, String> {
    Ok(autostart_dir()?.join(DESKTOP_FILE_NAME))
}

pub fn is_self_start_enabled() -> Result<bool, String> {
    Ok(self_start_path()?.exists())
}

pub fn set_self_start_enabled(enabled: bool, minimized: bool) -> Result<(), String> {
    let path = self_start_path()?;
    if !enabled {
        if path.exists() {
            fs::remove_file(path).map_err(|error| error.to_string())?;
        }
        return Ok(());
    }

    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut exec = quote_exec(&executable.to_string_lossy());
    if minimized {
        exec.push_str(" --minimized");
    }
    let desktop = format!(
        "[Desktop Entry]\nType=Application\nName=TimeTrace\nComment=Track desktop application usage\nExec={exec}\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
    );
    fs::write(path, desktop).map_err(|error| error.to_string())?;
    Ok(())
}

fn quote_exec(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_path_is_quoted() {
        assert_eq!(quote_exec("/opt/Time Trace/timetrace"), "\"/opt/Time Trace/timetrace\"");
    }
}
