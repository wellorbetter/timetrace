//! macOS startup support.
//!
//! TimeTrace self-start uses a per-user LaunchAgent. Enumerating and mutating
//! arbitrary Login Items is intentionally not attempted because modern macOS
//! protects that surface; the UI can still manage TimeTrace's own startup.

use std::fs;
use std::path::PathBuf;

use crate::contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};

const LAUNCH_AGENT_LABEL: &str = "com.wellorbetter.timetrace";
const LEGACY_LAUNCH_AGENT_LABEL: &str = "com.timetrace.app";

pub struct MacOsStartupScanner;

impl MacOsStartupScanner {
    pub fn new() -> Self { Self }
}

impl StartupScanner for MacOsStartupScanner {
    fn scan(&self) -> Vec<StartupEntryRecord> { Vec::new() }

    fn disable(&self, _entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        Err("macOS does not expose arbitrary Login Items management to TimeTrace".into())
    }

    fn enable(&self, _entry: &StartupEntryRecord) -> Result<(), String> {
        Err("macOS does not expose arbitrary Login Items management to TimeTrace".into())
    }
}

fn launch_agents_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join("Library/LaunchAgents"))
}

fn launch_agent_path(label: &str) -> Result<PathBuf, String> {
    Ok(launch_agents_dir()?.join(format!("{label}.plist")))
}

pub fn is_self_start_enabled() -> Result<bool, String> {
    Ok(launch_agent_path(LAUNCH_AGENT_LABEL)?.exists()
        || launch_agent_path(LEGACY_LAUNCH_AGENT_LABEL)?.exists())
}

pub fn set_self_start_enabled(enabled: bool, minimized: bool) -> Result<(), String> {
    let path = launch_agent_path(LAUNCH_AGENT_LABEL)?;
    let legacy_path = launch_agent_path(LEGACY_LAUNCH_AGENT_LABEL)?;

    if !enabled {
        for candidate in [&path, &legacy_path] {
            if candidate.exists() {
                fs::remove_file(candidate).map_err(|e| e.to_string())?;
            }
        }
        return Ok(());
    }

    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let minimized_arg = if minimized {
        "\n      <string>--minimized</string>"
    } else {
        ""
    };
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key><string>{}</string>\n  <key>ProgramArguments</key>\n  <array>\n      <string>{}</string>{}\n  </array>\n  <key>RunAtLoad</key><true/>\n</dict>\n</plist>\n",
        LAUNCH_AGENT_LABEL,
        xml_escape(&exe.to_string_lossy()),
        minimized_arg,
    );
    fs::write(&path, plist).map_err(|e| e.to_string())?;

    // Migrate pre-release builds that used the old placeholder label.
    if legacy_path.exists() {
        let _ = fs::remove_file(legacy_path);
    }
    Ok(())
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
