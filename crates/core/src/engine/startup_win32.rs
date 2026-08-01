//! Startup scanner — Win32 implementation.
//!
//! Scans four locations: HKLM Run, HKCU Run, Startup folder, Scheduled Tasks.

use std::path::PathBuf;

use chrono::Utc;
use tracing::{debug, warn};

use crate::contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};

// ── Windows API imports ──
use windows::core::HSTRING;
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegEnumValueW, RegOpenKeyExW, RegSetValueExW,
    HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_SZ,
};
use windows::Win32::Foundation::ERROR_SUCCESS;

// ── Strategy: One scanner per source ──

trait StartupSource: Send + Sync {
    fn name(&self) -> &'static str;
    fn scan(&self) -> Vec<StartupEntryRecord>;
    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String>;
    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String>;
}

// ── Registry Source (HKLM + HKCU) ──

struct RegistrySource {
    hkey: windows::Win32::System::Registry::HKEY,
    source_name: &'static str,
    /// Subkey path under the hive.
    subkey: &'static str,
    /// Backup subkey for storing original values.
    backup_subkey: &'static str,
}

impl RegistrySource {
    fn new_hklm() -> Self {
        Self {
            hkey: HKEY_LOCAL_MACHINE,
            source_name: "HKLM",
            subkey: r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            backup_subkey: r"SOFTWARE\TimeTrace\Backup\HKLM_Run",
        }
    }

    fn new_hkcu() -> Self {
        Self {
            hkey: HKEY_CURRENT_USER,
            source_name: "HKCU",
            subkey: r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            backup_subkey: r"SOFTWARE\TimeTrace\Backup\HKCU_Run",
        }
    }

    fn open_key(&self, access: u32) -> Result<windows::Win32::System::Registry::HKEY, String> {
        let subkey = HSTRING::from(self.subkey);
        let mut key = Default::default();
        unsafe {
            let result = RegOpenKeyExW(self.hkey, &subkey, 0, access, &mut key);
            if result != ERROR_SUCCESS {
                return Err(format!("Failed to open {}: {:?}", self.source_name, result));
            }
        }
        Ok(key)
    }

    fn open_backup_key(&self) -> Result<windows::Win32::System::Registry::HKEY, String> {
        // Create the backup key if it doesn't exist
        let subkey = HSTRING::from(self.backup_subkey);
        let mut key = Default::default();
        unsafe {
            use windows::Win32::System::Registry::{RegCreateKeyExW, REG_OPTION_NON_VOLATILE};
            let result = RegCreateKeyExW(
                HKEY_CURRENT_USER,
                &subkey,
                0,
                None,
                REG_OPTION_NON_VOLATILE,
                KEY_READ | KEY_WRITE,
                None,
                &mut key,
                None,
            );
            if result != ERROR_SUCCESS {
                return Err(format!("Failed to create backup key: {:?}", result));
            }
        }
        Ok(key)
    }
}

impl StartupSource for RegistrySource {
    fn name(&self) -> &'static str {
        self.source_name
    }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut entries = Vec::new();
        let key = match self.open_key(KEY_READ) {
            Ok(k) => k,
            Err(e) => {
                warn!("{e}");
                return entries;
            }
        };

        unsafe {
            let mut index: u32 = 0;
            loop {
                let mut name_buf = vec![0u16; 256];
                let mut name_len = name_buf.len() as u32;
                let mut value_buf = vec![0u16; 2048];
                let mut value_len = value_buf.len() as u32;

                let result = RegEnumValueW(
                    key,
                    index,
                    name_buf.as_mut_ptr(),
                    &mut name_len,
                    None,
                    None,
                    Some(value_buf.as_mut_ptr()),
                    Some(&mut value_len),
                );

                if result != ERROR_SUCCESS {
                    break; // No more values
                }

                name_buf.truncate(name_len as usize);
                value_buf.truncate(value_len as usize);

                let name = String::from_utf16_lossy(&name_buf);
                let command = String::from_utf16_lossy(&value_buf);

                let now = Utc::now();
                entries.push(StartupEntryRecord {
                    id: 0, // assigned by DB
                    name,
                    command,
                    source: self.source_name.to_string(),
                    enabled: true,
                    backup_value: None,
                    backup_path: None,
                    first_seen: now,
                    last_checked: now,
                });

                index += 1;
            }
            let _ = RegCloseKey(key);
        }

        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        let key = self.open_key(KEY_WRITE | KEY_READ)?;

        // 1. Read current value for backup
        let value_name = HSTRING::from(&entry.name);
        // Store the command as backup
        let backup_value = entry.command.clone();

        // 2. Delete the value from the Run key
        unsafe {
            let result = RegDeleteValueW(key, &value_name);
            if result != ERROR_SUCCESS {
                let _ = RegCloseKey(key);
                return Err(format!("Failed to delete registry value: {:?}", result));
            }
        }

        // 3. Store backup in our backup key (optional but good practice)
        let backup_key = self.open_backup_key().ok();
        if let Some(bk) = backup_key {
            unsafe {
                let backup_name = HSTRING::from(&entry.name);
                let backup_data = HSTRING::from(&backup_value);
                let _ = RegSetValueExW(
                    bk,
                    &backup_name,
                    0,
                    REG_SZ,
                    Some(std::slice::from_raw_parts(
                        backup_data.as_ptr() as *const u8,
                        backup_data.len() * 2,
                    )),
                );
                let _ = RegCloseKey(bk);
            }
        }

        unsafe { let _ = RegCloseKey(key); }

        Ok(DisableResult {
            backup_value: Some(backup_value),
            backup_path: None,
        })
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let backup = entry.backup_value.as_ref()
            .ok_or("No backup value available")?;

        let key = self.open_key(KEY_WRITE)?;
        let value_name = HSTRING::from(&entry.name);
        let value_data = HSTRING::from(backup);

        unsafe {
            let result = RegSetValueExW(
                key,
                &value_name,
                0,
                REG_SZ,
                Some(std::slice::from_raw_parts(
                    value_data.as_ptr() as *const u8,
                    value_data.len() * 2,
                )),
            );
            let _ = RegCloseKey(key);
            if result != ERROR_SUCCESS {
                return Err(format!("Failed to restore registry value: {:?}", result));
            }
        }

        Ok(())
    }
}

// ── Startup Folder Source ──

struct StartupFolderSource;

impl StartupFolderSource {
    fn folder_path() -> PathBuf {
        // %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
        let appdata = dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .parent() // Roaming → AppData
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."));

        appdata
            .join("Roaming")
            .join("Microsoft")
            .join("Windows")
            .join("Start Menu")
            .join("Programs")
            .join("Startup")
    }

    fn disabled_folder() -> PathBuf {
        Self::folder_path().join("TimeTrace_Disabled")
    }
}

impl StartupSource for StartupFolderSource {
    fn name(&self) -> &'static str {
        "StartupFolder"
    }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut entries = Vec::new();
        let folder = Self::folder_path();
        let disabled = Self::disabled_folder();

        let now = Utc::now();

        // Scan enabled shortcuts
        if let Ok(read_dir) = std::fs::read_dir(&folder) {
            for entry in read_dir.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |e| e == "lnk") {
                    let name = path.file_stem()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default();

                    entries.push(StartupEntryRecord {
                        id: 0,
                        name,
                        command: path.to_string_lossy().to_string(),
                        source: "StartupFolder".into(),
                        enabled: true,
                        backup_value: None,
                        backup_path: None,
                        first_seen: now,
                        last_checked: now,
                    });
                }
            }
        }

        // Scan disabled shortcuts
        if let Ok(read_dir) = std::fs::read_dir(&disabled) {
            for entry in read_dir.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |e| e == "lnk") {
                    let name = path.file_stem()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default();

                    entries.push(StartupEntryRecord {
                        id: 0,
                        name: format!("{} (disabled)", name),
                        command: path.to_string_lossy().to_string(),
                        source: "StartupFolder".into(),
                        enabled: false,
                        backup_value: None,
                        backup_path: Some(path.to_string_lossy().to_string()),
                        first_seen: now,
                        last_checked: now,
                    });
                }
            }
        }

        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        let src = PathBuf::from(&entry.command);
        let dst = Self::disabled_folder().join(
            src.file_name().ok_or("Invalid shortcut path")?,
        );

        std::fs::create_dir_all(Self::disabled_folder())
            .map_err(|e| format!("Failed to create disabled folder: {e}"))?;

        std::fs::rename(&src, &dst)
            .map_err(|e| format!("Failed to move shortcut: {e}"))?;

        Ok(DisableResult {
            backup_value: None,
            backup_path: Some(src.to_string_lossy().to_string()),
        })
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let backup = entry.backup_path.as_ref()
            .ok_or("No backup path available")?;
        let src = PathBuf::from(backup);
        let dst = Self::folder_path().join(
            src.file_name().ok_or("Invalid shortcut path")?,
        );

        std::fs::rename(&src, &dst)
            .map_err(|e| format!("Failed to restore shortcut: {e}"))?;

        Ok(())
    }
}

// ── Scheduled Tasks Source (simplified) ──

struct ScheduledTaskSource;

impl StartupSource for ScheduledTaskSource {
    fn name(&self) -> &'static str {
        "TaskScheduler"
    }

    fn scan(&self) -> Vec<StartupEntryRecord> {
        // Scheduled Task scanning via COM (ITaskScheduler) is complex.
        // For MVP, we use a lightweight approach: parse `schtasks /query` output.
        // This is a simplified placeholder.
        let output = std::process::Command::new("schtasks")
            .args(["/query", "/fo", "CSV", "/nh"])
            .output();

        let mut entries = Vec::new();
        let now = Utc::now();

        if let Ok(output) = output {
            let csv = String::from_utf8_lossy(&output.stdout);
            for line in csv.lines() {
                let parts: Vec<&str> = line.split(',').collect();
                if parts.len() >= 3 {
                    let name = parts[0].trim_matches('"').to_string();
                    // Filter for tasks that run at logon
                    let trigger_info = parts.get(2).map(|s| s.to_lowercase()).unwrap_or_default();
                    if trigger_info.contains("logon") || trigger_info.contains("startup") {
                        entries.push(StartupEntryRecord {
                            id: 0,
                            name,
                            command: parts.get(1).unwrap_or(&"").trim_matches('"').to_string(),
                            source: "TaskScheduler".into(),
                            enabled: true,
                            backup_value: None,
                            backup_path: None,
                            first_seen: now,
                            last_checked: now,
                        });
                    }
                }
            }
        }

        entries
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        // Use schtasks to disable
        let result = std::process::Command::new("schtasks")
            .args(["/change", "/tn", &entry.name, "/disable"])
            .output()
            .map_err(|e| format!("Failed to run schtasks: {e}"))?;

        if result.status.success() {
            Ok(DisableResult {
                backup_value: Some(entry.name.clone()),
                backup_path: None,
            })
        } else {
            Err(String::from_utf8_lossy(&result.stderr).to_string())
        }
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let result = std::process::Command::new("schtasks")
            .args(["/change", "/tn", &entry.name, "/enable"])
            .output()
            .map_err(|e| format!("Failed to run schtasks: {e}"))?;

        if result.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&result.stderr).to_string())
        }
    }
}

// ── Public composite scanner ──

pub struct WindowsStartupScanner {
    sources: Vec<Box<dyn StartupSource>>,
}

impl WindowsStartupScanner {
    pub fn new() -> Self {
        Self {
            sources: vec![
                Box::new(RegistrySource::new_hklm()),
                Box::new(RegistrySource::new_hkcu()),
                Box::new(StartupFolderSource),
                Box::new(ScheduledTaskSource),
            ],
        }
    }
}

impl StartupScanner for WindowsStartupScanner {
    fn scan(&self) -> Vec<StartupEntryRecord> {
        let mut all = Vec::new();
        for source in &self.sources {
            debug!("Scanning startup source: {}", source.name());
            let entries = source.scan();
            debug!("  Found {} entries", entries.len());
            all.extend(entries);
        }
        all
    }

    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String> {
        let source = self.sources.iter()
            .find(|s| s.name() == entry.source)
            .ok_or_else(|| format!("Unknown startup source: {}", entry.source))?;
        source.disable(entry)
    }

    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String> {
        let source = self.sources.iter()
            .find(|s| s.name() == entry.source)
            .ok_or_else(|| format!("Unknown startup source: {}", entry.source))?;
        source.enable(entry)
    }
}
