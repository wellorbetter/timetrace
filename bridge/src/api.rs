//! TimeTrace Flutter bridge API.
//!
//! Exposes the Rust core to Flutter/Dart via flutter_rust_bridge.
//! All methods are synchronous; data is small and local.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Result;
use flutter_rust_bridge::frb;
use timetrace_core::engine::app_identity::{normalize_timeout_rule_path, privacy_safe_app_name};
use timetrace_core::*;

/// Set up Rust-side file logging in the platform-native TimeTrace directory.
fn setup_logging() {
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

/// A diary entry with its publish status and structured provenance.
#[derive(Debug, Clone)]
pub struct DiaryEntryDto {
    pub id: i64,
    pub date: String,
    pub content: String,
    pub status: String,
    /// `manual` | `ai_generated` | `ai_assisted`.
    pub source: String,
    pub source_model: Option<String>,
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
    pub pomodoro: PomodoroConfigDto,
    pub app_timeout: AppTimeoutConfigDto,
}

/// Persisted Pomodoro preferences exposed to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PomodoroConfigDto {
    pub enabled: bool,
    pub focus_minutes: u64,
    pub short_break_minutes: u64,
    pub long_break_minutes: u64,
    pub long_break_interval: u64,
    pub auto_start_next: bool,
    pub notifications_enabled: bool,
    pub notification_sound: bool,
}

/// Persisted application timeout defaults exposed to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTimeoutConfigDto {
    pub enabled: bool,
    pub default_threshold_minutes: u64,
    pub default_cooldown_minutes: u64,
    pub notifications_enabled: bool,
    pub notification_sound: bool,
}

/// Constant-time privacy-minimal foreground activity projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivitySnapshotDto {
    pub revision: i64,
    /// Stable lowercase value: active/idle/excluded/paused/unavailable.
    pub state: String,
    pub tracking_paused: bool,
    pub is_idle: bool,
    pub app_path: Option<String>,
    pub app_name: Option<String>,
    pub observed_at: String,
}

/// One eligible running application for timeout-rule selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningAppDto {
    pub app_path: String,
    pub app_name: String,
}

/// Durable application timeout rule exposed to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTimeoutRuleDto {
    pub id: i64,
    pub app_path: String,
    pub app_name: String,
    pub threshold_secs: i64,
    pub cooldown_secs: i64,
    pub enabled: bool,
    pub notify_repeatedly: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// User-editable application timeout rule fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTimeoutRuleDraftDto {
    pub app_path: String,
    pub app_name: String,
    pub threshold_secs: i64,
    pub cooldown_secs: i64,
    pub enabled: bool,
    pub notify_repeatedly: bool,
}

// ── Main API ──

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    db_path: PathBuf,
    monitor: Mutex<Option<EventSourceHandle>>,
    paused: AtomicBool,
    activity_snapshot: ActivitySnapshotReader,
    process_query: SysinfoProcessQuery,
}

impl TimeTraceApi {
    /// Create the API, opening the DB and starting the background monitor.
    ///
    /// An empty `db_path` selects TimeTrace's platform-native default path.
    #[frb(sync)]
    pub fn create(db_path: String) -> Result<TimeTraceApi> {
        setup_logging();
        let config = AppConfig::load();
        let resolved_db_path = if db_path.trim().is_empty() {
            if config.db_path.trim().is_empty() {
                database_path()
            } else {
                PathBuf::from(config.db_path.trim())
            }
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
        let initially_paused = !config.auto_start_tracking;
        let excluded_apps = config.excluded_apps.clone();
        let projector = ActivitySnapshotProjector::new(initially_paused);
        let activity_snapshot = projector.reader();
        let sink = FanoutEventSink::new(vec![
            Box::new(SessionAggregator::new(db.clone())),
            Box::new(projector),
        ]);
        let handle = run_monitor_loop_with_initial_pause(
            PlatformWindowResolver::new(),
            PlatformIdleDetector::new(),
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes.saturating_mul(60)),
            excluded_apps,
            initially_paused,
            Box::new(sink),
        );

        Ok(TimeTraceApi {
            db,
            db_path: resolved_db_path,
            monitor: Mutex::new(Some(handle)),
            paused: AtomicBool::new(initially_paused),
            activity_snapshot,
            process_query: SysinfoProcessQuery::new(),
        })
    }

    /// Pause or resume the background tracking monitor.
    #[frb(sync)]
    pub fn set_tracking_paused(&self, paused: bool) {
        let guard = match self.monitor.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        if self.paused.swap(paused, Ordering::SeqCst) == paused {
            return;
        }
        if let Some(handle) = guard.as_ref() {
            if paused {
                handle.pause();
            } else {
                handle.resume();
            }
        }
        tracing::info!("Tracking {}", if paused { "paused" } else { "resumed" });
    }

    /// Whether tracking is currently paused.
    #[frb(sync)]
    pub fn is_tracking_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    /// Return the latest in-memory activity snapshot without querying SQLite
    /// or installing another foreground hook.
    #[frb(sync)]
    pub fn get_activity_snapshot(&self) -> ActivitySnapshotDto {
        activity_snapshot_dto(
            self.activity_snapshot.snapshot(),
            self.paused.load(Ordering::SeqCst),
        )
    }

    /// Refresh and list eligible running applications for rule selection.
    /// Processes without a readable stable path are omitted without elevation.
    #[frb(sync)]
    pub fn list_running_apps(&self) -> Vec<RunningAppDto> {
        self.process_query.refresh();
        running_app_dtos(self.process_query.list_processes())
    }

    /// List all locally persisted application timeout rules.
    #[frb(sync)]
    pub fn list_app_timeout_rules(&self) -> Result<Vec<AppTimeoutRuleDto>, String> {
        AppTimeoutRuleRepository::list_rules(&*self.db)
            .map(|rules| rules.into_iter().map(AppTimeoutRuleDto::from).collect())
            .map_err(rule_error_code)
    }

    /// Insert or update a timeout rule by normalized executable identity.
    #[frb(sync)]
    pub fn upsert_app_timeout_rule(
        &self,
        draft: AppTimeoutRuleDraftDto,
    ) -> Result<AppTimeoutRuleDto, String> {
        let draft = AppTimeoutRuleDraft {
            app_path: draft.app_path,
            app_name: draft.app_name,
            threshold_secs: draft.threshold_secs,
            cooldown_secs: draft.cooldown_secs,
            enabled: draft.enabled,
            notify_repeatedly: draft.notify_repeatedly,
        };
        AppTimeoutRuleRepository::upsert_rule(&*self.db, &draft)
            .map(AppTimeoutRuleDto::from)
            .map_err(rule_error_code)
    }

    /// Delete a timeout rule by stable ID.
    #[frb(sync)]
    pub fn delete_app_timeout_rule(&self, id: i64) -> Result<(), String> {
        AppTimeoutRuleRepository::delete_rule(&*self.db, id).map_err(rule_error_code)
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
        timetrace_core::set_self_start_enabled(enabled, minimized).map_err(|e| anyhow::anyhow!(e))
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
        config_dto(config, self.db_path.to_string_lossy().into_owned())
    }

    /// Persist user configuration (monitor timing/exclusions apply next launch).
    #[frb(sync)]
    pub fn set_config(&self, config: ConfigDto) -> Result<()> {
        let mut app_config = AppConfig::load();
        apply_config_dto(&mut app_config, config);
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
            .map(|entry| DiaryEntryDto {
                id: entry.id,
                date: entry.date,
                content: entry.content,
                status: entry.status,
                source: entry.source.as_str().to_string(),
                source_model: entry.source_model,
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

    /// Atomically publish an AI-authored diary with model provenance.
    #[frb(sync)]
    pub fn publish_ai_diary(
        &self,
        date: String,
        content: String,
        source_model: String,
    ) -> Result<i64, String> {
        DataStore::publish_ai_diary(&*self.db, parse_date(&date), &content, &source_model)
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

impl From<PomodoroConfig> for PomodoroConfigDto {
    fn from(config: PomodoroConfig) -> Self {
        Self {
            enabled: config.enabled,
            focus_minutes: config.focus_minutes,
            short_break_minutes: config.short_break_minutes,
            long_break_minutes: config.long_break_minutes,
            long_break_interval: config.long_break_interval,
            auto_start_next: config.auto_start_next,
            notifications_enabled: config.notifications_enabled,
            notification_sound: config.notification_sound,
        }
    }
}

impl From<PomodoroConfigDto> for PomodoroConfig {
    fn from(config: PomodoroConfigDto) -> Self {
        Self {
            enabled: config.enabled,
            focus_minutes: config.focus_minutes,
            short_break_minutes: config.short_break_minutes,
            long_break_minutes: config.long_break_minutes,
            long_break_interval: config.long_break_interval,
            auto_start_next: config.auto_start_next,
            notifications_enabled: config.notifications_enabled,
            notification_sound: config.notification_sound,
        }
    }
}

impl From<AppTimeoutConfig> for AppTimeoutConfigDto {
    fn from(config: AppTimeoutConfig) -> Self {
        Self {
            enabled: config.enabled,
            default_threshold_minutes: config.default_threshold_minutes,
            default_cooldown_minutes: config.default_cooldown_minutes,
            notifications_enabled: config.notifications_enabled,
            notification_sound: config.notification_sound,
        }
    }
}

impl From<AppTimeoutConfigDto> for AppTimeoutConfig {
    fn from(config: AppTimeoutConfigDto) -> Self {
        Self {
            enabled: config.enabled,
            default_threshold_minutes: config.default_threshold_minutes,
            default_cooldown_minutes: config.default_cooldown_minutes,
            notifications_enabled: config.notifications_enabled,
            notification_sound: config.notification_sound,
        }
    }
}

impl From<AppTimeoutRuleRecord> for AppTimeoutRuleDto {
    fn from(rule: AppTimeoutRuleRecord) -> Self {
        Self {
            id: rule.id,
            app_path: rule.app_path,
            app_name: rule.app_name,
            threshold_secs: rule.threshold_secs,
            cooldown_secs: rule.cooldown_secs,
            enabled: rule.enabled,
            notify_repeatedly: rule.notify_repeatedly,
            created_at: rule.created_at.to_rfc3339(),
            updated_at: rule.updated_at.to_rfc3339(),
        }
    }
}

fn config_dto(config: AppConfig, db_path: String) -> ConfigDto {
    ConfigDto {
        poll_interval_ms: config.poll_interval_ms,
        idle_threshold_minutes: config.idle_threshold_minutes,
        minimize_to_tray: config.minimize_to_tray,
        start_minimized: config.start_minimized,
        auto_start_tracking: config.auto_start_tracking,
        excluded_apps: config.excluded_apps,
        db_path,
        pomodoro: config.pomodoro.into(),
        app_timeout: config.app_timeout.into(),
    }
}

fn apply_config_dto(config: &mut AppConfig, dto: ConfigDto) {
    config.poll_interval_ms = dto.poll_interval_ms;
    config.idle_threshold_minutes = dto.idle_threshold_minutes;
    config.minimize_to_tray = dto.minimize_to_tray;
    config.start_minimized = dto.start_minimized;
    config.auto_start_tracking = dto.auto_start_tracking;
    config.excluded_apps = dto.excluded_apps;
    config.db_path = dto.db_path;
    config.pomodoro = dto.pomodoro.into();
    config.app_timeout = dto.app_timeout.into();
}

fn activity_snapshot_dto(snapshot: ActivitySnapshot, force_paused: bool) -> ActivitySnapshotDto {
    let state = if force_paused {
        ActivityState::Paused
    } else {
        snapshot.state
    };
    let app = if state == ActivityState::Active {
        snapshot.app
    } else {
        None
    };
    let tracking_paused =
        force_paused || snapshot.tracking_paused || state == ActivityState::Paused;
    ActivitySnapshotDto {
        revision: i64::try_from(snapshot.revision).unwrap_or(i64::MAX),
        state: activity_state_name(state).to_string(),
        tracking_paused,
        is_idle: state == ActivityState::Idle,
        app_path: app.as_ref().map(|application| application.app_path.clone()),
        app_name: app.map(|application| application.app_name),
        observed_at: snapshot.observed_at.to_rfc3339(),
    }
}

fn activity_state_name(state: ActivityState) -> &'static str {
    match state {
        ActivityState::Active => "active",
        ActivityState::Idle => "idle",
        ActivityState::Excluded => "excluded",
        ActivityState::Paused => "paused",
        ActivityState::Unavailable => "unavailable",
    }
}

fn running_app_dtos(processes: Vec<ProcessInfo>) -> Vec<RunningAppDto> {
    let mut applications = BTreeMap::<String, String>::new();
    for process in processes {
        if process.status != ProcessStatus::Running {
            continue;
        }
        let Some(raw_path) = process.exe_path.as_deref() else {
            continue;
        };
        let Ok(app_path) = normalize_timeout_rule_path(raw_path) else {
            continue;
        };
        let app_name = running_app_name(&process.name, raw_path);
        if app_name.trim().is_empty() {
            continue;
        }
        applications
            .entry(app_path)
            .and_modify(|current| {
                if app_name.to_lowercase() < current.to_lowercase() {
                    *current = app_name.clone();
                }
            })
            .or_insert(app_name);
    }
    applications
        .into_iter()
        .map(|(app_path, app_name)| RunningAppDto { app_path, app_name })
        .collect()
}

fn running_app_name(process_name: &str, raw_path: &str) -> String {
    privacy_safe_app_name(raw_path, Some(process_name))
}

fn rule_error_code(error: AppTimeoutRuleError) -> String {
    match error {
        AppTimeoutRuleError::InvalidPath => "invalid_path",
        AppTimeoutRuleError::EmptyAppName => "empty_app_name",
        AppTimeoutRuleError::InvalidDuration => "invalid_duration",
        AppTimeoutRuleError::NotFound => "not_found",
        AppTimeoutRuleError::Storage => "storage_unavailable",
    }
    .to_string()
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
    use super::*;

    fn process(name: &str, path: Option<&str>) -> ProcessInfo {
        process_with_status(name, path, ProcessStatus::Running)
    }

    fn process_with_status(name: &str, path: Option<&str>, status: ProcessStatus) -> ProcessInfo {
        ProcessInfo {
            pid: 1,
            name: name.to_string(),
            exe_path: path.map(str::to_string),
            cpu_percent: 99.0,
            memory_mb: 1024.0,
            status,
        }
    }

    fn valid_app_path() -> &'static str {
        #[cfg(target_os = "windows")]
        {
            r"C:\Apps\Editor.exe"
        }
        #[cfg(not(target_os = "windows"))]
        {
            "/Applications/Editor.app/Contents/MacOS/Editor"
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

    #[test]
    fn nested_config_dtos_round_trip_every_field() {
        let config = AppConfig {
            poll_interval_ms: 900,
            idle_threshold_minutes: 7,
            minimize_to_tray: false,
            start_minimized: true,
            auto_start_tracking: false,
            excluded_apps: vec!["private-app".to_string()],
            db_path: "old.db".to_string(),
            pomodoro: PomodoroConfig {
                enabled: true,
                focus_minutes: 50,
                short_break_minutes: 10,
                long_break_minutes: 25,
                long_break_interval: 3,
                auto_start_next: true,
                notifications_enabled: false,
                notification_sound: false,
            },
            app_timeout: AppTimeoutConfig {
                enabled: true,
                default_threshold_minutes: 75,
                default_cooldown_minutes: 20,
                notifications_enabled: false,
                notification_sound: false,
            },
        };

        let dto = config_dto(config, "active.db".to_string());
        assert_eq!(dto.db_path, "active.db");
        assert_eq!(dto.pomodoro.focus_minutes, 50);
        assert_eq!(dto.pomodoro.long_break_interval, 3);
        assert_eq!(dto.app_timeout.default_threshold_minutes, 75);

        let mut restored = AppConfig::default();
        apply_config_dto(&mut restored, dto);
        assert_eq!(restored.poll_interval_ms, 900);
        assert_eq!(restored.idle_threshold_minutes, 7);
        assert!(!restored.minimize_to_tray);
        assert!(restored.start_minimized);
        assert!(!restored.auto_start_tracking);
        assert_eq!(restored.excluded_apps, vec!["private-app"]);
        assert_eq!(restored.db_path, "active.db");
        assert!(restored.pomodoro.enabled);
        assert_eq!(restored.pomodoro.focus_minutes, 50);
        assert!(restored.pomodoro.auto_start_next);
        assert!(!restored.pomodoro.notifications_enabled);
        assert!(restored.app_timeout.enabled);
        assert_eq!(restored.app_timeout.default_cooldown_minutes, 20);
        assert!(!restored.app_timeout.notification_sound);
    }

    #[test]
    fn activity_snapshot_mapping_is_stable_and_pause_overlay_is_immediate() {
        let observed_at = chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        let snapshot = ActivitySnapshot {
            revision: u64::MAX,
            state: ActivityState::Active,
            tracking_paused: false,
            app: Some(ActivityApp {
                app_path: valid_app_path().to_string(),
                app_name: "Editor".to_string(),
            }),
            observed_at,
        };

        let active = activity_snapshot_dto(snapshot.clone(), false);
        assert_eq!(active.revision, i64::MAX);
        assert_eq!(active.state, "active");
        assert!(!active.tracking_paused);
        assert!(!active.is_idle);
        assert_eq!(active.app_path.as_deref(), Some(valid_app_path()));
        assert_eq!(active.app_name.as_deref(), Some("Editor"));
        assert_eq!(active.observed_at, observed_at.to_rfc3339());

        let paused = activity_snapshot_dto(snapshot, true);
        assert_eq!(paused.state, "paused");
        assert!(paused.tracking_paused);
        assert!(!paused.is_idle);
        assert!(paused.app_path.is_none());
        assert!(paused.app_name.is_none());

        let idle = activity_snapshot_dto(
            ActivitySnapshot {
                revision: 2,
                state: ActivityState::Idle,
                tracking_paused: false,
                app: None,
                observed_at,
            },
            false,
        );
        assert_eq!(idle.state, "idle");
        assert!(idle.is_idle);
    }

    #[test]
    fn running_app_projection_filters_invalid_paths_and_deduplicates_identity() {
        #[cfg(target_os = "windows")]
        let duplicate_path = "c:/apps/EDITOR.EXE";
        #[cfg(not(target_os = "windows"))]
        let duplicate_path = valid_app_path();

        let apps = running_app_dtos(vec![
            process("Editor.exe", Some(valid_app_path())),
            process("Editor Helper", Some(duplicate_path)),
            process("Protected", None),
            process("Ambiguous", Some("relative.exe")),
        ]);

        assert_eq!(apps.len(), 1);
        assert!(!apps[0].app_path.is_empty());
        assert!(!apps[0].app_name.is_empty());
        assert!(!apps[0].app_name.contains(['\\', '/', ':']));
    }

    #[test]
    fn running_app_projection_filters_non_running_processes() {
        let apps = running_app_dtos(vec![
            process_with_status(
                "Suspended",
                Some(valid_app_path()),
                ProcessStatus::Suspended,
            ),
            process_with_status("Unknown", Some(valid_app_path()), ProcessStatus::Unknown),
        ]);

        assert!(apps.is_empty());
    }

    #[test]
    fn running_app_projection_never_uses_private_parent_as_name() {
        #[cfg(target_os = "windows")]
        let private_runtime = r"C:\Users\Alice\secret-client\node.exe";
        #[cfg(not(target_os = "windows"))]
        let private_runtime = "/Users/alice/secret-client/node";

        let apps = running_app_dtos(vec![process("node.exe", Some(private_runtime))]);

        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].app_name, "Node.js");
        assert!(!apps[0].app_name.contains("secret-client"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn running_app_projection_omits_paths_without_portable_ordinal_identity() {
        let apps = running_app_dtos(vec![process("Greek.exe", Some(r"C:\Apps\Σ.exe"))]);
        assert!(apps.is_empty());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn running_app_projection_omits_lossy_windows_replacement_paths() {
        let apps = running_app_dtos(vec![process("Lossy.exe", Some("C:\\Apps\\\u{fffd}.exe"))]);
        assert!(apps.is_empty());
    }

    #[test]
    fn timeout_rule_errors_cross_the_bridge_as_safe_stable_codes() {
        assert_eq!(
            rule_error_code(AppTimeoutRuleError::InvalidPath),
            "invalid_path"
        );
        assert_eq!(
            rule_error_code(AppTimeoutRuleError::EmptyAppName),
            "empty_app_name"
        );
        assert_eq!(
            rule_error_code(AppTimeoutRuleError::InvalidDuration),
            "invalid_duration"
        );
        assert_eq!(rule_error_code(AppTimeoutRuleError::NotFound), "not_found");
        assert_eq!(
            rule_error_code(AppTimeoutRuleError::Storage),
            "storage_unavailable"
        );
    }

    #[test]
    fn timeout_rule_dto_uses_seconds_and_rfc3339_timestamps() {
        let created_at = chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        let updated_at = created_at + chrono::Duration::minutes(1);
        let dto = AppTimeoutRuleDto::from(AppTimeoutRuleRecord {
            id: 9,
            app_path: valid_app_path().to_string(),
            app_name: "Editor".to_string(),
            threshold_secs: 3600,
            cooldown_secs: 900,
            enabled: true,
            notify_repeatedly: false,
            created_at,
            updated_at,
        });
        assert_eq!(dto.id, 9);
        assert_eq!(dto.threshold_secs, 3600);
        assert_eq!(dto.cooldown_secs, 900);
        assert_eq!(dto.created_at, created_at.to_rfc3339());
        assert_eq!(dto.updated_at, updated_at.to_rfc3339());
    }
}
