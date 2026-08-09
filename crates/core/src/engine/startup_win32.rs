//! Startup scanner — discovers and manages Windows auto-start entries.
//!
//! Uses `winreg` for registry access and `schtasks` command for scheduled tasks.

use std::path::PathBuf;

use chrono::Utc;
use tracing::warn;

use crate::contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};

const SELF_START_NAME: &str = "TimeTrace";
const RUN_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";

/// Returns whether TimeTrace has a current-user startup entry.
pub fn is_self_start_enabled() -> Result<bool, String> {
    let key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .open_subkey_with_flags(RUN_KEY, winreg::enums::KEY_READ)
        .map_err(|e| format!("Cannot open HKCU Run key: {e}"))?;
    match key.get_value::<String, _>(SELF_START_NAME) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("Cannot read TimeTrace startup entry: {error}")),
    }
}

/// Enables or disables TimeTrace startup for the current Windows user.
pub fn set_self_start_enabled(enabled: bool, minimized: bool) -> Result<(), String> {
    let key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .create_subkey(RUN_KEY)
        .map_err(|e| format!("Cannot open HKCU Run key: {e}"))?
        .0;
    if enabled {
        let exe = std::env::current_exe().map_err(|e| format!("Cannot resolve executable: {e}"))?;
        let mut command = format!("\"{}\" --startup", exe.display());
        if minimized {
            command.push_str(" --minimized");
        }
        key.set_value(SELF_START_NAME, &command)
            .map_err(|e| format!("Cannot write TimeTrace startup entry: {e}"))
    } else {
        match key.delete_value(SELF_START_NAME) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("Cannot remove TimeTrace startup entry: {error}")),
        }
    }
}

// ── Internal source trait ──

trait StartupSource: Send + Sync {
    fn name(&self) -> &'static str;
    fn scan(&self) -> Vec<StartupEntryRecord>;
    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String>;
    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String>;
}

// ── Registry source (HKLM + HKCU) via winreg ──

struct RegistrySource {
    source_name: &'static str,
    subkey: &'static str,
}

impl RegistrySource {
    fn new_hklm() -> Self { Self { source_name: "HKLM", subkey: r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run" } }
    fn new_hkcu() -> Self { Self { source_name: "HKCU", subkey: r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run" } }

    fn predef(&self) -> winreg::HKEY {
        match self.source_name {
            "HKLM" => winreg::enums::HKEY_LOCAL_MACHINE,
            _ => winreg::enums::HKEY_CURRENT_USER,
        }
    }
}

impl StartupSource for RegistrySource {
    fn name(&self) -> &'static str { self.source_name }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut entries = Vec::new();
        let key = match winreg::RegKey::predef(self.predef()).open_subkey_with_flags(self.subkey, winreg::enums::KEY_READ) {
            Ok(k) => k,
            Err(e) => { warn!("Failed to open {}: {e}", self.source_name); return entries; }
        };

        let now = Utc::now();
        for result in key.enum_values() {
            if let Ok((name, value)) = result {
                let command = match value {
                    winreg::RegValue { vtype: _, bytes } => {
                        // Safe UTF-16 decode — odd-length bytes must not panic
                        let units: Vec<u16> = bytes
                            .chunks(2)
                            .map(|c| {
                                if c.len() == 2 { u16::from_ne_bytes([c[0], c[1]]) } else { c[0] as u16 }
                            })
                            .collect();
                        String::from_utf16_lossy(&units).trim_end_matches('\0').to_string()
                    }
                };
                entries.push(StartupEntryRecord { id: 0, name, command, source: self.source_name.to_string(),
                    enabled: true, backup_value: None, backup_path: None, first_seen: now, last_checked: now });
            }
        }
        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        // Backup: read current value
        let key = winreg::RegKey::predef(self.predef()).open_subkey_with_flags(self.subkey, winreg::enums::KEY_READ | winreg::enums::KEY_WRITE)
            .map_err(|e| format!("Cannot open key: {e}"))?;
        let backup = entry.command.clone();

        // Delete value
        key.delete_value(&entry.name).map_err(|e| format!("Cannot delete: {e}"))?;

        Ok(DisableResult { backup_value: Some(backup), backup_path: None })
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let backup = entry.backup_value.as_ref().ok_or("No backup")?;
        let key = winreg::RegKey::predef(self.predef()).open_subkey_with_flags(self.subkey, winreg::enums::KEY_WRITE)
            .map_err(|e| format!("Cannot open key: {e}"))?;
        // Encode as UTF-16 bytes for REG_SZ
        let wide: Vec<u16> = backup.encode_utf16().collect();
        let bytes: Vec<u8> = wide.iter().flat_map(|w| w.to_ne_bytes()).collect();
        key.set_raw_value(&entry.name, &winreg::RegValue { vtype: winreg::enums::REG_SZ, bytes })
            .map_err(|e| format!("Cannot restore: {e}"))
    }
}

// ── Startup folder source ──

struct StartupFolderSource;

impl StartupFolderSource {
    fn folder_path() -> PathBuf {
        dirs::config_dir().unwrap_or_default().parent().map(|p| p.to_path_buf()).unwrap_or_default()
            .join("Microsoft").join("Windows").join("Start Menu").join("Programs").join("Startup")
    }
    fn disabled_folder() -> PathBuf { Self::folder_path().join("TimeTrace_Disabled") }
}

impl StartupSource for StartupFolderSource {
    fn name(&self) -> &'static str { "StartupFolder" }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut entries = Vec::new();
        let now = Utc::now();
        let mut scan_dir = |dir: &PathBuf, enabled: bool| {
            if let Ok(rd) = std::fs::read_dir(dir) {
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().map_or(false, |ext| ext == "lnk") {
                        let name = p.file_stem().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                        entries.push(StartupEntryRecord { id: 0, name, command: p.to_string_lossy().to_string(),
                            source: "StartupFolder".into(), enabled, backup_value: None,
                            backup_path: if !enabled { Some(p.to_string_lossy().to_string()) } else { None },
                            first_seen: now, last_checked: now });
                    }
                }
            }
        };
        scan_dir(&Self::folder_path(), true);
        scan_dir(&Self::disabled_folder(), false);
        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        let src = PathBuf::from(&entry.command);
        std::fs::create_dir_all(Self::disabled_folder()).ok();
        let dst = Self::disabled_folder().join(src.file_name().ok_or("Invalid path")?);
        std::fs::rename(&src, &dst).map_err(|e| format!("Move failed: {e}"))?;
        Ok(DisableResult { backup_value: None, backup_path: Some(src.to_string_lossy().to_string()) })
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let backup = entry.backup_path.as_ref().ok_or("No backup")?;
        let src = PathBuf::from(backup);
        let dst = Self::folder_path().join(src.file_name().ok_or("Invalid path")?);
        std::fs::rename(&src, &dst).map_err(|e| format!("Restore failed: {e}"))
    }
}

// ── Scheduled Tasks source (schtasks CLI) ──

struct ScheduledTaskSource;

impl StartupSource for ScheduledTaskSource {
    fn name(&self) -> &'static str { "TaskScheduler" }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut entries = Vec::new();
        let now = Utc::now();

        if let Ok(out) = std::process::Command::new("schtasks").args(["/query", "/fo", "CSV", "/nh"]).output() {
            let csv = String::from_utf8_lossy(&out.stdout);
            for line in csv.lines() {
                let parts: Vec<&str> = line.split(',').collect();
                if parts.len() >= 3 {
                    let name = parts[0].trim_matches('"').to_string();
                    let cmd = parts.get(1).unwrap_or(&"").trim_matches('"').to_string();
                    let trigger = parts.get(2).map(|s| s.to_lowercase()).unwrap_or_default();
                    if trigger.contains("logon") || trigger.contains("startup") || trigger.contains("boot") {
                        entries.push(StartupEntryRecord { id: 0, name, command: cmd, source: "TaskScheduler".into(),
                            enabled: !trigger.contains("disabled"), backup_value: None, backup_path: None,
                            first_seen: now, last_checked: now });
                    }
                }
            }
        }
        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        let out = std::process::Command::new("schtasks").args(["/change", "/tn", &entry.name, "/disable"]).output()
            .map_err(|e| format!("schtasks failed: {e}"))?;
        if out.status.success() { Ok(DisableResult { backup_value: Some(entry.name.clone()), backup_path: None }) }
        else { Err(String::from_utf8_lossy(&out.stderr).to_string()) }
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let out = std::process::Command::new("schtasks").args(["/change", "/tn", &entry.name, "/enable"]).output()
            .map_err(|e| format!("schtasks failed: {e}"))?;
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).to_string()) }
    }
}

// ── Composite scanner ──

pub struct WindowsStartupScanner { sources: Vec<Box<dyn StartupSource>> }

impl WindowsStartupScanner {
    pub fn new() -> Self {
        Self { sources: vec![
            Box::new(RegistrySource::new_hklm()), Box::new(RegistrySource::new_hkcu()),
            Box::new(StartupFolderSource), Box::new(ScheduledTaskSource),
        ]}
    }
}

impl StartupScanner for WindowsStartupScanner {
    fn scan(&self) -> Vec<StartupEntryRecord> {
        self.sources.iter().flat_map(|s| s.scan()).collect()
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        self.sources.iter().find(|s| s.name() == entry.source)
            .ok_or_else(|| format!("Unknown source: {}", entry.source))?
            .disable(entry)
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        self.sources.iter().find(|s| s.name() == entry.source)
            .ok_or_else(|| format!("Unknown source: {}", entry.source))?
            .enable(entry)
    }
}
