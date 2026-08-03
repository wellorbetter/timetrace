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

/// Set up file logging at %APPDATA%/TimeTrace/timetrace.log
fn setup_logging() {
    use tracing_subscriber::prelude::*;
    let dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("TimeTrace");
    let _ = std::fs::create_dir_all(&dir);
    let log_path = dir.join("timetrace.log");
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

/// User configuration (persisted in AppConfig.json).
#[derive(Debug, Clone)]
pub struct ConfigDto {
    pub poll_interval_ms: u64,
    pub idle_threshold_minutes: u64,
    pub excluded_apps: Vec<String>,
    pub db_path: String,
}

// ── Main API ──

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    monitor: std::sync::Mutex<Option<EventSourceHandle>>,
    paused: std::sync::atomic::AtomicBool,
}

impl TimeTraceApi {
    /// Create the API, opening the DB and starting the background monitor.
    #[frb(sync)]
    pub fn create(db_path: String) -> Result<TimeTraceApi> {
        setup_logging();
        tracing::info!("TimeTrace bridge starting, db={}", db_path);
        let db = Arc::new(SqliteStore::open(PathBuf::from(&db_path))?);

        // Auto-scan startup entries on first launch
        if DataStore::get_all_startup_entries(&*db).is_empty() {
            let entries = WindowsStartupScanner::new().scan();
            DataStore::upsert_startup_entries(&*db, &entries);
        }

        // Start background monitor (thread persists after handle drops)
        let config = AppConfig::load();
        let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
        let handle = run_monitor_loop(
            Win32WindowResolver,
            Win32IdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            sink,
        );
        let api = TimeTraceApi {
            db,
            monitor: std::sync::Mutex::new(Some(handle)),
            paused: std::sync::atomic::AtomicBool::new(false),
        };
        Ok(api)
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

    /// Enable/disable a startup entry.
    #[frb(sync)]
    pub fn toggle_startup(&self, id: i64, enable: bool) -> Result<()> {
        let entries = DataStore::get_all_startup_entries(&*self.db);
        let entry = entries.iter().find(|e| e.id == id).cloned().ok_or_else(|| anyhow::anyhow!("entry not found"))?;
        let scanner = WindowsStartupScanner::new();
        if enable {
            scanner.enable(&entry).map_err(|e| anyhow::anyhow!(e))?;
            DataStore::set_startup_enabled(&*self.db, id, true, None, None);
        } else {
            let r = scanner.disable(&entry).map_err(|e| anyhow::anyhow!(e))?;
            DataStore::set_startup_enabled(&*self.db, id, false, r.backup_value.as_deref(), r.backup_path.as_deref());
        }
        Ok(())
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
            since: DataStore::recording_started_at(&*self.db).map(|t| t.format("%Y-%m-%d").to_string()),
        }
    }

    /// Extract an exe icon as raw RGBA pixels.
    #[frb(sync)]
    pub fn get_app_icon(&self, exe_path: String) -> Option<IconDto> {
        let cleaned = clean_exe_path(&exe_path).unwrap_or_else(|| exe_path.clone());
        crate::icons::extract_icon_rgba(&cleaned).map(|(w, h, rgba)| IconDto {
            width: w as i64,
            height: h as i64,
            rgba,
        })
    }

    /// Resolve a startup command line to its clean exe path (env-expanded,
    /// quotes/args stripped). Returns None if no .exe is found.
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
            excluded_apps: config.excluded_apps,
            db_path: String::new(),
        }
    }

    /// Persist user configuration (applies on next monitor start).
    #[frb(sync)]
    pub fn set_config(&self, config: ConfigDto) -> Result<()> {
        let mut app_config = AppConfig::load();
        app_config.poll_interval_ms = config.poll_interval_ms;
        app_config.idle_threshold_minutes = config.idle_threshold_minutes;
        app_config.excluded_apps = config.excluded_apps;
        app_config.save().map_err(|e| anyhow::anyhow!(e.to_string()))
    }

    /// Active seconds for this week (Mon→today) and last week (full).
    #[frb(sync)]
    pub fn get_week_totals(&self) -> (i64, i64) {
        let today = chrono::Local::now().date_naive();
        let weekday = chrono::Datelike::weekday(&today).num_days_from_monday() as i64;
        let this_monday = today - chrono::Duration::days(weekday);
        let last_monday = this_monday - chrono::Duration::days(7);
        let this_week = DataStore::total_tracked_in_range(&*self.db, this_monday, today);
        let last_week = DataStore::total_tracked_in_range(&*self.db, last_monday, this_monday - chrono::Duration::days(1));
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
            dtos.push(DaySessionDto { app_name: app, is_idle, duration_secs: dur, started_at: started });
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

    /// Set the diary entry for a date.
    #[frb(sync)]
    pub fn set_diary(&self, date: String, content: String) -> String {
        DataStore::set_diary(&*self.db, parse_date(&date), &content)
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
            csv.push_str(&format!("{},{},{},{}\n", app, date, active, idle));
        }
        csv
    }
}

fn parse_date(s: &str) -> chrono::NaiveDate {
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap_or_else(|_| chrono::Local::now().date_naive())
}

/// Extract a clean, env-expanded exe path from a startup command line.
/// Handles: quoted paths, trailing args, %VAR% env vars, double backslashes.
fn clean_exe_path(cmd: &str) -> Option<String> {
    let lower = cmd.to_lowercase();
    let idx = lower.find(".exe").or_else(|| lower.find(".lnk"))?;
    let end = idx + if lower[idx..].starts_with(".exe") { 4 } else { 4 };
    if end > cmd.len() {
        return None;
    }
    let before = &cmd[..end];
    let start = before
        .rfind('"')
        .map(|q| q + 1)
        .or_else(|| before.rfind(' ').map(|s| s + 1))
        .unwrap_or(0);
    if start >= end {
        return None;
    }
    let raw = &cmd[start..end];

    // Normalize double backslashes from registry escaping: \\ → \
    // (only when the path otherwise parses — a single backslash stays)
    let raw = raw.replace("\\\\", "\\");

    // Expand %VAR% using process environment (windir, SystemRoot, etc.)
    let mut expanded = raw.to_string();
    for (k, v) in std::env::vars() {
        expanded = expanded.replace(&format!("%{}%", k), &v);
    }
    // Fallback for common vars if somehow not in env
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

    if expanded.contains("%") {
        return None; // unresolved env var — can't iconify
    }
    Some(expanded)
}
