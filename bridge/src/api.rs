//! TimeTrace Flutter bridge API.
//!
//! Exposes the Rust core to Flutter/Dart via flutter_rust_bridge.
//! All methods are synchronous; data is small and local.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::Result;
use flutter_rust_bridge::frb;
use timetrace_core::*;

use crate::ai_recap::{
    AiRecapConnectionReplyDto, AiRecapDto, AiRecapGenerateReplyDto, AiRecapService,
    AiRecapSettingsReplyDto, AiRecapStatusDto, SqliteAggregateUsageSource,
};
use crate::ai_report_store::{AiReportStore, AiReportStoreError, SqliteAiReportStore, UnavailableAiReportStore};

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

/// User configuration (persisted in AppConfig.json).
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

/// Lazily owns the feature-local AI service and its second SQLite connection.
///
/// The extra initialization mutex coordinates the one-time initializer with a
/// pre-initialization `clear_data` request. Once initialized, reads use the
/// lock-free `OnceLock` fast path.
struct LazyAiRecap {
    db: Arc<SqliteStore>,
    database_path: PathBuf,
    service: OnceLock<AiRecapService>,
    initialization: Mutex<()>,
    #[cfg(test)]
    initialization_count: AtomicUsize,
}

impl LazyAiRecap {
    fn new(db: Arc<SqliteStore>, database_path: PathBuf) -> Self {
        Self {
            db,
            database_path,
            service: OnceLock::new(),
            initialization: Mutex::new(()),
            #[cfg(test)]
            initialization_count: AtomicUsize::new(0),
        }
    }

    fn get(&self) -> &AiRecapService {
        if let Some(service) = self.service.get() {
            return service;
        }
        let _initialization = self.lock_initialization();
        self.service.get_or_init(|| self.initialize())
    }

    fn initialize(&self) -> AiRecapService {
        #[cfg(test)]
        self.initialization_count.fetch_add(1, Ordering::Relaxed);

        let report_store: Arc<dyn AiReportStore> =
            match SqliteAiReportStore::open(self.database_path.clone()) {
                Ok(store) => Arc::new(store),
                Err(_) => {
                    tracing::warn!("AI report storage unavailable; AI reports disabled");
                    Arc::new(UnavailableAiReportStore)
                }
            };
        AiRecapService::new(
            Arc::new(SqliteAggregateUsageSource::new(self.db.clone())),
            report_store,
        )
    }

    fn clear_reports(&self) -> Result<(), AiReportStoreError> {
        let _initialization = self.lock_initialization();
        if let Some(service) = self.service.get() {
            service.clear_reports()
        } else {
            // Clearing user data is an explicit privacy action. Remove any
            // persisted reports immediately without constructing or caching
            // the AI service; a later first AI access still initializes once.
            SqliteAiReportStore::open(self.database_path.clone())?.clear_latest_reports()
        }
    }

    fn lock_initialization(&self) -> MutexGuard<'_, ()> {
        match self.initialization.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    #[cfg(test)]
    fn initialization_count(&self) -> usize {
        self.initialization_count.load(Ordering::Acquire)
    }
}

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    ai_recap: LazyAiRecap,
    monitor: std::sync::Mutex<Option<EventSourceHandle>>,
    paused: std::sync::atomic::AtomicBool,
}

impl TimeTraceApi {
    /// Create the API, opening the DB and starting the background monitor.
    #[frb(sync)]
    pub fn create(db_path: String) -> Result<TimeTraceApi> {
        setup_logging();
        tracing::info!("TimeTrace bridge starting, db={}", db_path);
        let database_path = PathBuf::from(&db_path);
        let db = Arc::new(SqliteStore::open(database_path.clone())?);

        // Auto-scan startup entries on first launch
        if DataStore::get_all_startup_entries(&*db).is_empty() {
            let entries = WindowsStartupScanner::new().scan();
            DataStore::upsert_startup_entries(&*db, &entries);
        }

        // Start background monitor.
        let config = AppConfig::load();
        let initially_paused = !config.auto_start_tracking;
        let excluded_apps = config.excluded_apps.clone();
        let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
        let handle = run_monitor_loop(
            Win32WindowResolver,
            Win32IdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            excluded_apps,
            sink,
        );
        if initially_paused {
            handle.pause();
        }
        // Keep the AI schema, report load, and second SQLite connection off
        // the application startup path until an AI-facing API is requested.
        let ai_recap = LazyAiRecap::new(db.clone(), database_path);
        let api = TimeTraceApi {
            db,
            ai_recap,
            monitor: std::sync::Mutex::new(Some(handle)),
            paused: std::sync::atomic::AtomicBool::new(initially_paused),
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

    /// Redacted report-provider state; never exposes credential data.
    #[frb(sync)]
    pub fn ai_recap_status(&self) -> AiRecapStatusDto {
        self.ai_recap.get().status()
    }

    /// Reads only the bounded in-process result cache; performs no network I/O.
    #[frb(sync)]
    pub fn get_latest_ai_recap(
        &self,
        scope: String,
        start: String,
        end: String,
    ) -> Option<AiRecapDto> {
        self.ai_recap.get().latest(&scope, &start, &end)
    }

    /// Reads at most one persisted report per type, newest first, without network I/O.
    #[frb(sync)]
    pub fn get_latest_ai_reports(&self) -> Vec<AiRecapDto> {
        self.ai_recap.get().latest_reports()
    }

    /// Securely creates or replaces a credential for one closed provider.
    pub fn save_ai_recap_api_key(
        &self,
        provider_id: String,
        api_key: String,
    ) -> AiRecapSettingsReplyDto {
        self.ai_recap.get().save_api_key(provider_id, api_key)
    }

    /// Explicitly imports a provider's legacy environment key into secure storage.
    pub fn import_ai_recap_environment_key(&self, provider_id: String) -> AiRecapSettingsReplyDto {
        self.ai_recap.get().import_environment_api_key(provider_id)
    }

    /// Removes one provider's secure key; its environment fallback may become active.
    pub fn delete_ai_recap_api_key(&self, provider_id: String) -> AiRecapSettingsReplyDto {
        self.ai_recap.get().delete_api_key(provider_id)
    }

    /// Atomically saves a validated provider/model selection.
    pub fn set_ai_recap_provider_selection(
        &self,
        provider_id: String,
        model_id: String,
    ) -> AiRecapSettingsReplyDto {
        self.ai_recap.get().set_provider_selection(provider_id, model_id)
    }

    /// Explicitly tests the selected provider without sending usage aggregates.
    pub fn test_ai_recap_connection(&self) -> AiRecapConnectionReplyDto {
        self.ai_recap.get().test_connection()
    }

    /// Explicitly generates a report on a normal FRB worker thread.
    pub fn generate_ai_recap(
        &self,
        scope: String,
        start: String,
        end: String,
    ) -> AiRecapGenerateReplyDto {
        self.ai_recap.get().generate(scope, start, end)
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
            minimize_to_tray: config.minimize_to_tray,
            start_minimized: config.start_minimized,
            auto_start_tracking: config.auto_start_tracking,
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

    /// Image paths attached to a diary entry (朋友圈 album).
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
    pub fn clear_data(&self) -> bool {
        tracing::info!("Clearing all usage data");
        DataStore::clear_all_data(&*self.db);
        if let Err(error) = self.ai_recap.clear_reports() {
            tracing::warn!(error = %error, "failed to clear persisted AI reports");
            return false;
        }
        true
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
            csv.push_str(&format!("{},{},{},{}\n", csv_field(&app), csv_field(&date), active, idle));
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
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap_or_else(|_| chrono::Local::now().date_naive())
}

/// Extract a clean executable path from a startup command line.
/// Only a fixed allowlist of non-secret path variables may be expanded.
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
    let raw = cmd[start..end].replace("\\\\", "\\");
    expand_safe_path_variables(&raw)
}

fn expand_safe_path_variables(raw: &str) -> Option<String> {
    let mut expanded = String::with_capacity(raw.len());
    let mut remainder = raw;
    while let Some(open) = remainder.find('%') {
        expanded.push_str(&remainder[..open]);
        let after_open = &remainder[open + 1..];
        let close = after_open.find('%')?;
        let name = &after_open[..close];
        expanded.push_str(&safe_path_variable(name)?);
        remainder = &after_open[close + 1..];
    }
    expanded.push_str(remainder);
    (!expanded.contains('%')).then_some(expanded)
}

fn safe_path_variable(name: &str) -> Option<String> {
    match name.to_ascii_lowercase().as_str() {
        "windir" => Some(std::env::var("windir").or_else(|_| std::env::var("SystemRoot")).unwrap_or_else(|_| "C:\\Windows".to_owned())),
        "systemroot" => Some(std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned())),
        "programfiles" => Some(std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".to_owned())),
        "programfiles(x86)" => Some(std::env::var("ProgramFiles(x86)").unwrap_or_else(|_| "C:\\Program Files (x86)".to_owned())),
        "programw6432" => std::env::var("ProgramW6432").ok(),
        "systemdrive" => Some(std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned())),
        "localappdata" => std::env::var("LOCALAPPDATA").ok(),
        "appdata" => std::env::var("APPDATA").ok(),
        "userprofile" => std::env::var("USERPROFILE").ok(),
        "commonprogramfiles" => std::env::var("CommonProgramFiles").ok(),
        "commonprogramfiles(x86)" => std::env::var("CommonProgramFiles(x86)").ok(),
        _ => None,
    }
}
#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Barrier};
    use std::time::{SystemTime, UNIX_EPOCH};

    use rusqlite::Connection;
    use timetrace_core::SqliteStore;

    use super::{LazyAiRecap, clean_exe_path, csv_field};

    fn temporary_database_path(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "timetrace-api-{label}-{}-{nonce}.sqlite",
            std::process::id()
        ))
    }

    fn ai_table_count(path: &Path) -> i64 {
        Connection::open(path)
            .expect("inspect database")
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' \
                 AND name IN ('ai_report_settings', 'ai_latest_reports')",
                [],
                |row| row.get(0),
            )
            .expect("count AI tables")
    }

    fn remove_database_files(path: &Path) {
        for candidate in [
            path.to_path_buf(),
            path.with_extension("sqlite-wal"),
            path.with_extension("sqlite-shm"),
        ] {
            let _ = std::fs::remove_file(candidate);
        }
    }

    #[test]
    fn ai_service_is_lazy_and_concurrent_first_access_initializes_once() {
        let path = temporary_database_path("lazy-ai");
        let db = Arc::new(SqliteStore::open(path.clone()).expect("open main database"));
        let lazy = Arc::new(LazyAiRecap::new(db.clone(), path.clone()));

        assert_eq!(lazy.initialization_count(), 0);
        assert_eq!(ai_table_count(&path), 0);
        lazy.clear_reports().expect("clear persisted reports");
        assert_eq!(lazy.initialization_count(), 0);
        assert_eq!(ai_table_count(&path), 2);

        let worker_count = 8;
        let barrier = Arc::new(Barrier::new(worker_count));
        let workers = (0..worker_count)
            .map(|_| {
                let lazy = lazy.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    assert!(lazy.get().status().service_available);
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().expect("AI initialization worker");
        }

        assert_eq!(lazy.initialization_count(), 1);
        assert_eq!(ai_table_count(&path), 2);

        drop(lazy);
        drop(db);
        remove_database_files(&path);
    }

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
    fn startup_path_expands_only_fixed_non_secret_variables() {
        let system_command =
            clean_exe_path(r"%SystemRoot%\System32\cmd.exe").expect("safe system path");
        assert!(system_command.eq_ignore_ascii_case(r"C:\Windows\System32\cmd.exe"));
        assert_eq!(clean_exe_path(r"%DEEPSEEK_API_KEY%.exe"), None);
        assert_eq!(clean_exe_path(r"%UNLISTED_SECRET%.exe"), None);
    }

    #[test]
    fn csv_fields_escape_delimiters_quotes_and_newlines() {
        assert_eq!(csv_field("plain"), "plain");
        assert_eq!(csv_field("A, B"), "\"A, B\"");
        assert_eq!(csv_field("A \"quoted\""), "\"A \"\"quoted\"\"\"");
        assert_eq!(csv_field("A\nB"), "\"A\nB\"");
    }
}
