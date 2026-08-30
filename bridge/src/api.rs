//! TimeTrace Flutter bridge API.
//!
//! Exposes the Rust core to Flutter/Dart via flutter_rust_bridge.
//! All methods are synchronous; data is small and local.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use flutter_rust_bridge::frb;
use timetrace_core::*;

/// Set up Rust-side file logging in the platform-native TimeTrace directory.
fn setup_logging() {
    use tracing_subscriber::prelude::*;

    let log_path = rust_log_path();
    if let Some(dir) = log_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path);
    if let Ok(file) = file {
        let _ = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::INFO)
            .with_writer(file)
            .with_ansi(false)
            .try_init();
    }
}

// ── DTOs exposed to Dart ──

#[derive(Debug, Clone)]
pub struct AppUsageDto {
    pub app_name: String,
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub exe_path: String,
}

#[derive(Debug, Clone)]
pub struct PageDto {
    pub title: String,
    pub seconds: i64,
}

#[derive(Debug, Clone)]
pub struct StartupDto {
    pub id: i64,
    pub name: String,
    pub exe_path: String,
    pub source: String,
    pub enabled: bool,
}

#[derive(Debug, Clone)]
pub struct StatsDto {
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub total_seconds: i64,
    pub since: Option<String>,
}

/// A diary entry with its publish status ('draft' | 'published').
#[derive(Debug, Clone)]
pub struct DiaryEntryDto {
    pub id: i64,
    pub date: String,
    pub content: String,
    pub status: String,
}

/// Raw RGBA icon pixels for rendering in Flutter.
#[derive(Debug, Clone)]
pub struct IconDto {
    pub width: i64,
    pub height: i64,
    pub rgba: Vec<u8>,
}

/// A single day's session record (for the daily log).
#[derive(Debug, Clone)]
pub struct DaySessionDto {
    pub app_name: String,
    pub is_idle: bool,
    pub duration_secs: i64,
    pub started_at: String,
}

/// A day's detail: summary + sessions + diary.
#[derive(Debug, Clone)]
pub struct DayDetailDto {
    pub date: String,
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub session_count: i64,
    pub diary: String,
    pub sessions: Vec<DaySessionDto>,
}

/// Combined dashboard payload (one FFI call instead of two).
#[derive(Debug, Clone)]
pub struct DashboardDataDto {
    pub apps: Vec<AppUsageDto>,
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub total_seconds: i64,
    pub since: Option<String>,
}

/// User configuration (persisted in config.json).
#[derive(Debug, Clone)]
pub struct ConfigDto {
    pub poll_interval_ms: u64,
    pub idle_threshold_minutes: u64,
    pub minimize_to_tray: bool,
    pub start_minimized: bool,
    pub auto_start_tracking: bool,
    pub excluded_apps: Vec<String>,
    pub db_path: String,
}

// ── Main API ──

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    db_path: PathBuf,
    monitor: std::sync::Mutex<Option<EventSourceHandle>>,
    paused: std::sync::atomic::AtomicBool,
}

impl TimeTraceApi {
    /// Create the API, opening the DB and starting the background monitor.
    ///
    /// An empty `db_path` selects TimeTrace's platform-native default path.
    #[frb(sync)]
    pub fn create(db_path: String) -> Result<TimeTraceApi> {
        setup_logging();
        let resolved_db_path = if db_path.trim().is_empty() {
            database_path()
        } else {
            PathBuf::from(db_path)
        };
        if let Some(parent) = resolved_db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        tracing::info!(
            "TimeTrace bridge starting, platform={}, db={}",
            std::env::consts::OS,
            resolved_db_path.display()
        );
        let db = Arc::new(SqliteStore::open(resolved_db_path.clone())?);

        // Auto-scan startup entries on first launch. Platforms that cannot
        // enumerate arbitrary login items simply return an empty list.
        if DataStore::get_all_startup_entries(&*db).is_empty() {
            let entries = PlatformStartupScanner::new().scan();
            DataStore::upsert_startup_entries(&*db, &entries);
        }

        // Start the shared monitor with target-specific adapters selected by
        // timetrace-core. Flutter never needs to know which implementation runs.
        let config = AppConfig::load();
        let initially_paused = !config.auto_start_tracking;
        let excluded_apps = config.excluded_apps.clone();
        let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
        let handle = run_monitor_loop(
            PlatformWindowResolver::new(),
            PlatformIdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            excluded_apps,
            sink,
        );
        if initially_paused {
            handle.pause();
        }

        Ok(TimeTraceApi {
            db,
            db_path: resolved_db_path,
            monitor: std::sync::Mutex::new(Some(handle)),
            paused: std::sync::atomic::AtomicBool::new(initially_paused),
        })
    }

    /// Pause or resume the background tracking monitor.
    #[frb(sync)]
    pub fn set_tracking_paused(&self, paused: bool) {
        if let Ok(guard) = self.monitor.lock() {
            if let Some(h) = guard.as_ref() {
                if paused { h.pause(); } else { h.resume(); }
                self.paused.store(paused, std::sync::atomic::Ordering::SeqCst);
                tracing::info!("Tracking {}", if paused { "paused" } else { "resumed" });
            }
        }
    }

    /// Whether tracking is currently paused.
    #[frb(sync)]
    pub fn is_tracking_paused(&self) -> bool {
        self.paused.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// One-call dashboard payload: usage split + overall stats.
    #[frb(sync)]
    pub fn get_dashboard_data(&self, start: String, end: String) -> DashboardDataDto {
        let s = parse_date(&start);
        let e = parse_date(&end);
        let split = DataStore::get_usage_split(&*self.db, s, e);
        let active: i64 = split.iter().map(|x| x.active_seconds).sum();
        let idle: i64 = split.iter().map(|x| x.idle_seconds).sum();
        DashboardDataDto {
            apps: split
                .into_iter()
                .map(|x| AppUsageDto {
                    app_name: x.app_name,
                    active_seconds: x.active_seconds,
                    idle_seconds: x.idle_seconds,
                    exe_path: x.exe_path,
                })
                .collect(),
            active_seconds: active,
            idle_seconds: idle,
            total_seconds: DataStore::total_tracked_seconds(&*self.db),
            since: DataStore::recording_started_at(&*self.db)
                .map(|t| t.format("%Y-%m-%d").to_string()),
        }
    }

    /// Reports whether a database read has entered its non-panicking fallback.
    #[frb(sync)]
    pub fn is_database_degraded(&self) -> bool {
        self.db.is_degraded()
    }

    /// Per-app active/idle split for a date range (dates as "YYYY-MM-DD").
    #[frb(sync)]
    pub fn get_usage_split(&self, start: String, end: String) -> Vec<AppUsageDto> {
        let s = parse_date(&start);
        let e = parse_date(&end);
        DataStore::get_usage_split(&*self.db, s, e)
            .into_iter()
            .map(|x| AppUsageDto { app_name: x.app_name, active_seconds: x.active_seconds, idle_seconds: x.idle_seconds, exe_path: x.exe_path })
            .collect()
    }

    /// Page-level breakdown for an app on a date.
    #[frb(sync)]
    pub fn get_window_titles(&self, app_name: String, date: String) -> Vec<PageDto> {
        DataStore::get_window_titles(&*self.db, &app_name, parse_date(&date))
            .into_iter()
            .map(|(title, seconds)| PageDto { title, seconds })
            .collect()
    }

    /// All startup entries.
    #[frb(sync)]
    pub fn get_startup_entries(&self) -> Vec<StartupDto> {
        DataStore::get_all_startup_entries(&*self.db)
            .into_iter()
            .map(|e| StartupDto { id: e.id, name: e.name, exe_path: e.command, source: e.source, enabled: e.enabled })
            .collect()
    }

    /// Enable/disable a startup entry when supported by the current platform.
    #[frb(sync)]
    pub fn toggle_startup(&self, id: i64, enable: bool) -> Result<()> {
        let entries = DataStore::get_all_startup_entries(&*self.db);
        let entry = entries
            .iter()
            .find(|e| e.id == id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("entry not found"))?;
        let scanner = PlatformStartupScanner::new();
        if enable {
            scanner.enable(&entry).map_err(|e| anyhow::anyhow!(e))?;
            DataStore::set_startup_enabled(&*self.db, id, true, None, None);
        } else {
            let r = scanner.disable(&entry).map_err(|e| anyhow::anyhow!(e))?;
            DataStore::set_startup_enabled(
                &*self.db,
                id,
                false,
                r.backup_value.as_deref(),
                r.backup_path.as_deref(),
            );
        }
        Ok(())
    }

    /// Returns whether TimeTrace is configured to start for the current user.
    #[frb(sync)]
    pub fn is_self_start_enabled(&self) -> Result<bool> {
        timetrace_core::is_self_start_enabled().map_err(|e| anyhow::anyhow!(e))
    }

    /// Configures current-user startup without requiring administrator rights.
    #[frb(sync)]
    pub fn set_self_start_enabled(&self, enabled: bool, minimized: bool) -> Result<()> {
        timetrace_core::set_self_start_enabled(enabled, minimized)
            .map_err(|e| anyhow::anyhow!(e))
    }

    /// Overall recording statistics.
    #[frb(sync)]
    pub fn get_stats(&self, start: String, end: String) -> StatsDto {
        let s = parse_date(&start);
        let e = parse_date(&end);
        let split = DataStore::get_usage_split(&*self.db, s, e);
        let active: i64 = split.iter().map(|x| x.active_seconds).sum();
        let idle: i64 = split.iter().map(|x| x.idle_seconds).sum();
        StatsDto {
            active_seconds: active,
            idle_seconds: idle,
            total_seconds: DataStore::total_tracked_seconds(&*self.db),
            since: DataStore::recording_started_at(&*self.db)
                .map(|t| t.format("%Y-%m-%d").to_string()),
        }
    }

    /// Extract an application icon as raw RGBA pixels when supported.
    #[frb(sync)]
    pub fn get_app_icon(&self, exe_path: String) -> Option<IconDto> {
        let cleaned = clean_exe_path(&exe_path).unwrap_or_else(|| exe_path.clone());
        crate::icons::extract_icon_rgba(&cleaned).map(|(w, h, rgba)| IconDto {
            width: w as i64,
            height: h as i64,
            rgba,
        })
    }

    /// Resolve a Windows startup command line to its clean executable path.
    #[frb(sync)]
    pub fn resolve_exe_path(&self, command: String) -> Option<String> {
        clean_exe_path(&command)
    }

    /// Read the current user configuration.
    #[frb(sync)]
    pub fn get_config(&self) -> ConfigDto {
        let config = AppConfig::load();
        ConfigDto {
            poll_interval_ms: config.poll_interval_ms,
            idle_threshold_minutes: config.idle_threshold_minutes,
            minimize_to_tray: config.minimize_to_tray,
            start_minimized: config.start_minimized,
            auto_start_tracking: config.auto_start_tracking,
            excluded_apps: config.excluded_apps,
            db_path: self.db_path.to_string_lossy().into_owned(),
        }
    }

    /// Persist user configuration (monitor timing/exclusions apply next launch).
    #[frb(sync)]
    pub fn set_config(&self, config: ConfigDto) -> Result<()> {
        let mut app_config = AppConfig::load();
        app_config.poll_interval_ms = config.poll_interval_ms;
        app_config.idle_threshold_minutes = config.idle_threshold_minutes;
        app_config.minimize_to_tray = config.minimize_to_tray;
        app_config.start_minimized = config.start_minimized;
        app_config.auto_start_tracking = config.auto_start_tracking;
        app_config.excluded_apps = config.excluded_apps;
        app_config.save().map_err(|e| anyhow::anyhow!(e.to_string()))?;

        // Keep the startup command's optional --minimized flag aligned with the
        // persisted preference when the user changes it after enabling startup.
        if timetrace_core::is_self_start_enabled().unwrap_or(false) {
            timetrace_core::set_self_start_enabled(true, app_config.start_minimized)
                .map_err(|e| anyhow::anyhow!(e))?;
        }
        Ok(())
    }

    /// Active seconds for this week (Mon→today) and last week (full).
    #[frb(sync)]
    pub fn get_week_totals(&self) -> (i64, i64) {
        let today = chrono::Local::now().date_naive();
        let weekday = chrono::Datelike::weekday(&today).num_days_from_monday() as i64;
        let this_monday = today - chrono::Duration::days(weekday);
        let last_monday = this_monday - chrono::Duration::days(7);
        let this_week = DataStore::total_tracked_in_range(&*self.db, this_monday, today);
        let last_week = DataStore::total_tracked_in_range(
            &*self.db,
            last_monday,
            this_monday - chrono::Duration::days(1),
        );
        (this_week, last_week)
    }

    /// Full day detail: active/idle totals, session timeline, diary.
    #[frb(sync)]
    pub fn get_day_detail(&self, date: String) -> DayDetailDto {
        let d = parse_date(&date);
        let sessions = DataStore::get_day_sessions(&*self.db, d);
        let mut active = 0i64;
        let mut idle = 0i64;
        let mut dtos = Vec::with_capacity(sessions.len());
        for (app, is_idle, dur, started) in sessions {
            if is_idle { idle += dur; } else { active += dur; }
            dtos.push(DaySessionDto {
                app_name: app,
                is_idle,
                duration_secs: dur,
                started_at: started,
            });
        }
        DayDetailDto {
            date,
            active_seconds: active,
            idle_seconds: idle,
            session_count: dtos.len() as i64,
            diary: DataStore::get_diary(&*self.db, d).unwrap_or_default(),
            sessions: dtos,
        }
    }

    /// Get all diary entries for a month range (for calendar markers).
    #[frb(sync)]
    pub fn get_diary_entries(&self, start: String, end: String) -> Vec<(String, String)> {
        DataStore::get_diary_entries(&*self.db, parse_date(&start), parse_date(&end))
    }

    /// All diary images with their entry link: (date, entry_id, path).
    #[frb(sync)]
    pub fn get_diary_images_detailed(
        &self,
        start: String,
        end: String,
    ) -> Vec<(String, Option<i64>, String)> {
        DataStore::get_diary_images_detailed(&*self.db, parse_date(&start), parse_date(&end))
    }

    /// All diary entries in a range with ids + status, newest first.
    #[frb(sync)]
    pub fn get_diary_entries_detailed(
        &self,
        start: String,
        end: String,
    ) -> Vec<DiaryEntryDto> {
        DataStore::get_diary_entries_detailed(&*self.db, parse_date(&start), parse_date(&end))
            .into_iter()
            .map(|(id, date, content, status)| DiaryEntryDto {
                id,
                date,
                content,
                status,
            })
            .collect()
    }

    /// Autosave a draft for a date (one draft per day). Returns its id.
    #[frb(sync)]
    pub fn save_diary_draft(&self, date: String, content: String) -> i64 {
        DataStore::save_diary_draft(&*self.db, parse_date(&date), &content)
    }

    /// Publish: promote the day's draft or insert a new published entry.
    #[frb(sync)]
    pub fn publish_diary(&self, date: String, content: String) -> i64 {
        DataStore::publish_diary(&*self.db, parse_date(&date), &content)
    }

    /// The day's draft content, if any.
    #[frb(sync)]
    pub fn get_diary_draft(&self, date: String) -> Option<String> {
        DataStore::get_diary_draft(&*self.db, parse_date(&date))
    }

    /// Add a new diary entry for a date. Returns the new entry id.
    #[frb(sync)]
    pub fn add_diary_entry(&self, date: String, content: String) -> i64 {
        DataStore::add_diary_entry(&*self.db, parse_date(&date), &content)
    }

    /// Update a diary entry's content by id.
    #[frb(sync)]
    pub fn update_diary_entry(&self, id: i64, content: String) -> Result<(), String> {
        DataStore::update_diary_entry(&*self.db, id, &content)
    }

    /// Delete a diary entry by id.
    #[frb(sync)]
    pub fn delete_diary_entry(&self, id: i64) -> Result<(), String> {
        DataStore::delete_diary_entry(&*self.db, id)
    }

    /// Set the diary entry for a date.
    #[frb(sync)]
    pub fn set_diary(&self, date: String, content: String) -> String {
        DataStore::set_diary(&*self.db, parse_date(&date), &content)
    }

    /// Hourly active-seconds for a day (24 buckets) — for the heatmap.
    #[frb(sync)]
    pub fn get_day_hourly(&self, date: String) -> Vec<i64> {
        DataStore::get_day_hourly(&*self.db, parse_date(&date))
    }

    /// Apps active within a specific hour of a date (seconds per app).
    #[frb(sync)]
    pub fn get_hour_apps(&self, date: String, hour: u32) -> Vec<AppUsageDto> {
        DataStore::get_hour_apps(&*self.db, parse_date(&date), hour)
            .into_iter()
            .map(|(app_name, secs)| AppUsageDto {
                app_name,
                active_seconds: secs,
                idle_seconds: 0,
                exe_path: String::new(),
            })
            .collect()
    }

    /// Hourly active-seconds for one app on a date (24 buckets).
    #[frb(sync)]
    pub fn get_app_hourly(&self, app_name: String, date: String) -> Vec<i64> {
        DataStore::get_app_hourly(&*self.db, &app_name, parse_date(&date))
    }

    /// Diary image paths in a date range (for calendar cell overlays).
    #[frb(sync)]
    pub fn get_diary_images(&self, start: String, end: String) -> Vec<(String, String)> {
        DataStore::get_diary_images(&*self.db, parse_date(&start), parse_date(&end))
    }

    /// Register a diary image for a date.
    #[frb(sync)]
    pub fn add_diary_image(&self, date: String, path: String) -> String {
        DataStore::add_diary_image(&*self.db, parse_date(&date), &path)
    }

    /// Link a staged diary image to a diary entry.
    #[frb(sync)]
    pub fn set_diary_image_entry(&self, path: String, entry_id: i64) -> Result<(), String> {
        DataStore::set_diary_image_entry(&*self.db, &path, entry_id)
    }

    /// Image paths attached to a diary entry.
    #[frb(sync)]
    pub fn get_diary_images_for_entry(&self, entry_id: i64) -> Vec<String> {
        DataStore::get_diary_images_for_entry(&*self.db, entry_id)
    }

    /// Remove a diary image.
    #[frb(sync)]
    pub fn remove_diary_image(&self, path: String) {
        DataStore::remove_diary_image(&*self.db, &path);
    }

    /// Clear ALL tracked usage data (sessions + page visits).
    #[frb(sync)]
    pub fn clear_data(&self) {
        tracing::info!("Clearing all usage data");
        DataStore::clear_all_data(&*self.db);
    }

    /// Export usage data for a date range as CSV.
    /// Returns the CSV text (app, date, active_secs, idle_secs).
    #[frb(sync)]
    pub fn export_csv(&self, start: String, end: String) -> String {
        let s = parse_date(&start);
        let e = parse_date(&end);
        let rows = DataStore::export_rows(&*self.db, s, e);
        let mut csv = String::from("app,date,active_secs,idle_secs\n");
        for (app, date, active, idle) in rows {
            csv.push_str(&format!(
                "{},{},{},{}\n",
                csv_field(&app),
                csv_field(&date),
                active,
                idle
            ));
        }
        csv
    }
}

fn csv_field(value: &str) -> String {
    if value.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

fn parse_date(s: &str) -> chrono::NaiveDate {
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Local::now().date_naive())
}

/// Extract a clean, env-expanded exe path from a Windows startup command line.
fn clean_exe_path(cmd: &str) -> Option<String> {
    let lower = cmd.to_lowercase();
    let idx = lower.find(".exe").or_else(|| lower.find(".lnk"))?;
    let end = idx + 4;
    if end > cmd.len() {
        return None;
    }
    let before = &cmd[..end];
    let start = before.rfind('"').map(|q| q + 1).unwrap_or(0);
    if start >= end {
        return None;
    }
    let raw = &cmd[start..end];

    // Normalize doubled backslashes from registry escaping.
    let raw = raw.replace("\\\\", "\\");

    let mut expanded = raw.to_string();
    for (k, v) in std::env::vars() {
        expanded = expanded.replace(&format!("%{}%", k), &v);
    }
    let common = [
        ("windir", "C:\\Windows"),
        ("SystemRoot", "C:\\Windows"),
        ("ProgramFiles", "C:\\Program Files"),
        ("ProgramFiles(x86)", "C:\\Program Files (x86)"),
        ("SystemDrive", "C:"),
    ];
    for (k, v) in common {
        expanded = expanded.replace(&format!("%{}%", k), v);
    }

    if expanded.contains('%') {
        return None;
    }
    Some(expanded)
}

#[cfg(test)]
mod tests {
    use super::{clean_exe_path, csv_field};

    #[test]
    fn spaced_unquoted_path_kept_intact() {
        let p = clean_exe_path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe").unwrap();
        assert_eq!(p, r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe");
    }

    #[test]
    fn quoted_path_strips_quotes() {
        let p = clean_exe_path(r#""C:\Program Files\App\app.exe" --flag"#).unwrap();
        assert_eq!(p, r"C:\Program Files\App\app.exe");
    }

    #[test]
    fn no_space_path_unchanged() {
        let p = clean_exe_path(r"D:\QQ\QQ.exe").unwrap();
        assert_eq!(p, r"D:\QQ\QQ.exe");
    }

    #[test]
    fn csv_fields_escape_delimiters_quotes_and_newlines() {
        assert_eq!(csv_field("plain"), "plain");
        assert_eq!(csv_field("A, B"), "\"A, B\"");
        assert_eq!(csv_field("A \"quoted\""), "\"A \"\"quoted\"\"\"");
        assert_eq!(csv_field("A\nB"), "\"A\nB\"");
    }
}
