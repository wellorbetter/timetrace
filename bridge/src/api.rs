//! TimeTrace Flutter bridge API.
//!
//! Exposes the Rust core to Flutter/Dart via flutter_rust_bridge.
//! Compatibility endpoints remain synchronous; typed queries and CSV export
//! use normal FRB worker tasks.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use flutter_rust_bridge::frb;
pub use timetrace_core::AccountingSnapshot;
use timetrace_core::engine::aggregator::CheckpointStore;
use timetrace_core::engine::{CanonicalMonitorHandle, run_canonical_monitor_loop};
use timetrace_core::*;

use crate::accounting::{
    AccountingAsOfRequest, AccountingBridgeError, AccountingExportCsv, AccountingRangeRequest,
    AccountingSnapshotDto, map_accounting_snapshot, resolve_accounting_request,
    utc_range_for_local_dates,
};

const CANONICAL_CHECKPOINT_TIMEOUT: Duration = Duration::from_secs(5);

// AppConfig has no IANA zone field yet. Keep the legacy String endpoint
// deterministic; callers needing local-day semantics use the typed endpoint.
const COMPAT_EXPORT_TIMEZONE: &str = "UTC";

/// Set up file logging at %APPDATA%/TimeTrace/timetrace.log
fn setup_logging() {
    use tracing_subscriber::prelude::*;
    let dir = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("TimeTrace");
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

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    monitor: std::sync::Mutex<Option<CanonicalMonitorHandle>>,
    paused: std::sync::atomic::AtomicBool,
}

impl TimeTraceApi {
    /// Resolve the host's IANA time zone for canonical local-day queries.
    #[frb(sync)]
    pub fn get_system_iana_timezone() -> Result<String> {
        Ok(iana_time_zone::get_timezone()?)
    }

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

        // Start background monitor.
        let config = AppConfig::load();
        let initially_paused = !config.auto_start_tracking;
        let excluded_apps = config.excluded_apps.clone();
        let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
        let accounting_store: Arc<dyn AccountingStore> = db.clone();
        let staging_store: Arc<dyn CheckpointStore> = db.clone();
        let clock: Arc<dyn AccountingClock> = Arc::new(SystemAccountingClock);
        let handle = run_canonical_monitor_loop(
            Win32WindowResolver,
            Win32IdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            excluded_apps,
            sink,
            accounting_store,
            staging_store,
            clock,
        );
        if initially_paused {
            handle
                .pause(CANONICAL_CHECKPOINT_TIMEOUT)
                .map_err(|error| anyhow::anyhow!(error.message.clone()))?;
        }
        let api = TimeTraceApi {
            db,
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
                let result = if paused {
                    h.pause(CANONICAL_CHECKPOINT_TIMEOUT)
                } else {
                    h.resume(CANONICAL_CHECKPOINT_TIMEOUT)
                };
                match result {
                    Ok(_) => {
                        self.paused
                            .store(paused, std::sync::atomic::Ordering::SeqCst);
                        tracing::info!("Tracking {}", if paused { "paused" } else { "resumed" });
                    }
                    Err(error) => tracing::warn!(
                        "Tracking state checkpoint failed at {:?}: {}",
                        error.last_acknowledged_observed_through,
                        error.message
                    ),
                }
            }
        }
    }

    /// Whether tracking is currently paused.
    #[frb(sync)]
    pub fn is_tracking_paused(&self) -> bool {
        self.paused.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Fence the producer at one Current boundary, then query exactly one
    /// canonical snapshot. A failed fence still queries at the producer-owned
    /// boundary so the core ledger returns a partial snapshot with an unknown
    /// tail after the last acknowledged watermark.
    #[frb(sync)]
    pub fn get_accounting_snapshot_current(
        &self,
        start_utc: String,
        end_utc: String,
    ) -> Result<AccountingSnapshot> {
        let requested = UtcInterval::new(
            parse_utc_boundary("start_utc", &start_utc)?,
            parse_utc_boundary("end_utc", &end_utc)?,
        )?;
        let guard = self
            .monitor
            .lock()
            .map_err(|_| anyhow::anyhow!("monitor handle is unavailable"))?;
        let handle = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("monitor has stopped"))?;
        current_accounting_snapshot(
            handle,
            &*self.db,
            &SystemAccountingClock,
            requested,
            CANONICAL_CHECKPOINT_TIMEOUT,
        )
    }

    /// Query and map exactly one canonical accounting snapshot. Current reads
    /// first use the accepted producer fence; historical reads remain durable
    /// and side-effect free.
    pub fn get_accounting_snapshot(
        &self,
        range: AccountingRangeRequest,
        as_of: AccountingAsOfRequest,
    ) -> Result<AccountingSnapshotDto, AccountingBridgeError> {
        let resolved = resolve_accounting_request(range, as_of)?;
        let snapshot = match resolved.query {
            AccountingQuery::Current => {
                let guard = self.monitor.lock().map_err(|_| {
                    AccountingBridgeError::ProducerUnavailable {
                        message: "monitor handle is unavailable".to_owned(),
                    }
                })?;
                let handle =
                    guard
                        .as_ref()
                        .ok_or_else(|| AccountingBridgeError::ProducerUnavailable {
                            message: "monitor has stopped".to_owned(),
                        })?;
                current_accounting_snapshot(
                    handle,
                    &*self.db,
                    &SystemAccountingClock,
                    resolved.requested.clone(),
                    CANONICAL_CHECKPOINT_TIMEOUT,
                )
                .map_err(map_current_snapshot_error)?
            }
            query => AccountingQueryService::new(&*self.db, &SystemAccountingClock)
                .snapshot(resolved.requested.clone(), query)?,
        };
        map_accounting_snapshot(&snapshot, &resolved)
    }

    /// One-call dashboard payload: usage split + overall stats.
    #[frb(sync)]
    pub fn get_dashboard_data(&self, start: String, end: String) -> DashboardDataDto {
        let s = parse_date(&start);
        let e = parse_date(&end);
        let split = DataStore::get_usage_split(&*self.db, s, e);
        let active: i64 = split.iter().map(|x| x.active_seconds).sum();
        let idle = self.db.get_idle_time_total(s, e).seconds;
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
            .map(|x| AppUsageDto {
                app_name: x.app_name,
                active_seconds: x.active_seconds,
                idle_seconds: x.idle_seconds,
                exe_path: x.exe_path,
            })
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
            .map(|e| StartupDto {
                id: e.id,
                name: e.name,
                exe_path: e.command,
                source: e.source,
                enabled: e.enabled,
            })
            .collect()
    }

    /// Enable/disable a startup entry.
    #[frb(sync)]
    pub fn toggle_startup(&self, id: i64, enable: bool) -> Result<()> {
        let entries = DataStore::get_all_startup_entries(&*self.db);
        let entry = entries
            .iter()
            .find(|e| e.id == id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("entry not found"))?;
        let scanner = WindowsStartupScanner::new();
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
        timetrace_core::set_self_start_enabled(enabled, minimized).map_err(|e| anyhow::anyhow!(e))
    }

    /// Overall recording statistics.
    #[frb(sync)]
    pub fn get_stats(&self, start: String, end: String) -> StatsDto {
        let s = parse_date(&start);
        let e = parse_date(&end);
        let split = DataStore::get_usage_split(&*self.db, s, e);
        let active: i64 = split.iter().map(|x| x.active_seconds).sum();
        let idle = self.db.get_idle_time_total(s, e).seconds;
        StatsDto {
            active_seconds: active,
            idle_seconds: idle,
            total_seconds: DataStore::total_tracked_seconds(&*self.db),
            since: DataStore::recording_started_at(&*self.db)
                .map(|t| t.format("%Y-%m-%d").to_string()),
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
        // New public values must fail before configuration or startup IO.
        validate_config_polling(&config)?;
        let mut app_config = AppConfig::try_load_for_update()?;
        app_config.poll_interval_ms = config.poll_interval_ms;
        app_config.idle_threshold_minutes = config.idle_threshold_minutes;
        app_config.minimize_to_tray = config.minimize_to_tray;
        app_config.start_minimized = config.start_minimized;
        app_config.auto_start_tracking = config.auto_start_tracking;
        app_config.excluded_apps = config.excluded_apps;
        app_config
            .save()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
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
            if is_idle {
                idle += dur;
            } else {
                active += dur;
            }
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
    pub fn get_diary_entries_detailed(&self, start: String, end: String) -> Vec<DiaryEntryDto> {
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
    pub fn clear_data(&self) {
        tracing::info!("Clearing all usage data");
        DataStore::clear_all_data(&*self.db);
    }

    /// Export one canonical accounting snapshot as versioned CSV.
    ///
    /// The external String contract is preserved. Invalid input or an
    /// unavailable snapshot produces a header-only document instead of
    /// silently substituting today's date.
    #[frb(sync)]
    pub fn export_csv(&self, start: String, end: String) -> String {
        self.export_csv_async(start, end).unwrap_or_else(|error| {
            tracing::warn!("Accounting CSV export failed: {error}");
            AccountingExportCsv::empty()
        })
    }

    /// Run canonical export on the FRB normal worker, preserving actual errors.
    /// A legitimate partial/unknown snapshot remains successful canonical CSV;
    /// the existing producer fence and snapshot degradation policy are unchanged.
    pub fn export_csv_async(
        &self,
        start: String,
        end: String,
    ) -> Result<String, AccountingBridgeError> {
        let requested = utc_range_for_local_dates(&start, &end, COMPAT_EXPORT_TIMEZONE)?;
        let guard =
            self.monitor
                .lock()
                .map_err(|_| AccountingBridgeError::ProducerUnavailable {
                    message: "monitor handle is unavailable".to_owned(),
                })?;
        let handle =
            guard
                .as_ref()
                .ok_or_else(|| AccountingBridgeError::ProducerUnavailable {
                    message: "monitor has stopped".to_owned(),
                })?;
        let snapshot = current_accounting_snapshot(
            handle,
            &*self.db,
            &SystemAccountingClock,
            requested,
            CANONICAL_CHECKPOINT_TIMEOUT,
        )
        .map_err(map_current_snapshot_error)?;
        Ok::<_, AccountingBridgeError>(AccountingExportCsv::serialize(&snapshot))
    }
}

/// Pure public configuration boundary, shared by set_config and its DTO test.
fn validate_config_polling(config: &ConfigDto) -> Result<()> {
    AppConfig::validate_poll_interval(config.poll_interval_ms)
        .map_err(|error| anyhow::anyhow!(error.to_string()))
}

fn map_current_snapshot_error(error: anyhow::Error) -> AccountingBridgeError {
    error
        .downcast_ref::<AccountingError>()
        .cloned()
        .map(AccountingBridgeError::from)
        .unwrap_or_else(|| AccountingBridgeError::ProducerUnavailable {
            message: error.to_string(),
        })
}

pub fn current_accounting_snapshot<S, C>(
    monitor: &CanonicalMonitorHandle,
    store: &S,
    clock: &C,
    requested: UtcInterval,
    timeout: Duration,
) -> Result<AccountingSnapshot>
where
    S: AccountingStore,
    C: AccountingClock,
{
    let as_of = match monitor.checkpoint_current(timeout) {
        Ok(ack) => ack.durable_observed_through,
        Err(error) => {
            tracing::warn!(
                "Current checkpoint failed at {:?}: {}",
                error.last_acknowledged_observed_through,
                error.message
            );
            error.requested_as_of
        }
    };
    AccountingQueryService::new(store, clock)
        .snapshot(requested, AccountingQuery::At { as_of })
        .map_err(anyhow::Error::from)
}

fn csv_field(value: &str) -> String {
    if value.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_owned()
    }
}

fn parse_date(s: &str) -> chrono::NaiveDate {
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Local::now().date_naive())
}

fn parse_utc_boundary(field: &str, value: &str) -> Result<chrono::DateTime<chrono::Utc>> {
    let parsed = chrono::DateTime::parse_from_rfc3339(value)
        .map_err(|error| anyhow::anyhow!("invalid {field}: {error}"))?;
    if parsed.offset().local_minus_utc() != 0 {
        return Err(anyhow::anyhow!("{field} must use UTC offset"));
    }
    Ok(parsed.with_timezone(&chrono::Utc))
}

/// Extract a clean, env-expanded exe path from a startup command line.
/// Handles: quoted paths, trailing args, %VAR% env vars, double backslashes.
fn clean_exe_path(cmd: &str) -> Option<String> {
    let lower = cmd.to_lowercase();
    let idx = lower.find(".exe").or_else(|| lower.find(".lnk"))?;
    let end = idx
        + if lower[idx..].starts_with(".exe") {
            4
        } else {
            4
        };
    if end > cmd.len() {
        return None;
    }
    let before = &cmd[..end];
    // The exe path itself may contain spaces (e.g. "C:\\Program Files\\...").
    // Only a quoted command lets us trim leading tokens; otherwise the whole
    // prefix up to ".exe" IS the path (arguments can only follow ".exe").
    let start = before.rfind('"').map(|q| q + 1).unwrap_or(0);
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
#[cfg(test)]
mod tests {
    use super::{clean_exe_path, csv_field, validate_config_polling, ConfigDto};

    // In-memory only: no create API, monitor, logging, environment or user DB.
    fn export_without_producer() -> super::TimeTraceApi {
        super::TimeTraceApi {
            db: std::sync::Arc::new(
                timetrace_core::SqliteStore::open(std::path::PathBuf::from(":memory:"))
                    .expect("isolated in-memory export fixture"),
            ),
            monitor: std::sync::Mutex::new(None),
            paused: std::sync::atomic::AtomicBool::new(false),
        }
    }

    #[test]
    fn async_export_invalid_date_preserves_error_and_sync_header_compatibility() {
        let api = export_without_producer();
        let result = api.export_csv_async("not-a-date".to_owned(), "2026-01-02".to_owned());
        assert!(matches!(result, Err(super::AccountingBridgeError::InvalidLocalDate { .. })));
        assert_eq!(
            api.export_csv("not-a-date".to_owned(), "2026-01-02".to_owned()),
            super::AccountingExportCsv::empty(),
        );
    }

    #[test]
    fn async_export_unavailable_producer_is_error_not_empty_success() {
        let api = export_without_producer();
        assert!(matches!(
            api.export_csv_async("2026-01-01".to_owned(), "2026-01-02".to_owned()),
            Err(super::AccountingBridgeError::ProducerUnavailable { .. }),
        ));
        assert_eq!(
            api.export_csv("2026-01-01".to_owned(), "2026-01-02".to_owned()),
            super::AccountingExportCsv::empty(),
        );
    }

    #[test]
    fn public_polling_validation_accepts_canonical_range_only() {
        for (poll_interval_ms, valid) in [
            (0, false), (500, false), (1000, false), (3000, false),
            (29999, false), (30000, true), (30001, true),
            (59999, true), (60000, true), (60001, false), (u64::MAX, false),
        ] {
            let config = ConfigDto {
                poll_interval_ms,
                idle_threshold_minutes: 5,
                minimize_to_tray: true,
                start_minimized: false,
                auto_start_tracking: true,
                excluded_apps: vec!["fixture.exe".to_owned()],
                db_path: "synthetic-only".to_owned(),
            };
            assert_eq!(validate_config_polling(&config).is_ok(), valid);
            assert_eq!(config.poll_interval_ms, poll_interval_ms);
            assert_eq!(config.idle_threshold_minutes, 5);
            assert!(config.minimize_to_tray);
            assert!(!config.start_minimized);
            assert!(config.auto_start_tracking);
            assert_eq!(config.excluded_apps, ["fixture.exe"]);
            assert_eq!(config.db_path, "synthetic-only");
        }
    }

    #[test]
    fn spaced_unquoted_path_kept_intact() {
        let p = clean_exe_path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
            .unwrap();
        assert_eq!(
            p,
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
        );
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
