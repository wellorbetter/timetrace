//! TimeTrace Flutter bridge API.
//!
//! Exposes the Rust core to Flutter/Dart via flutter_rust_bridge.
//! Methods that can touch storage, plugin lifecycle, or shutdown are exposed
//! asynchronously to Flutter so they never block the UI isolate.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use flutter_rust_bridge::frb;
use timetrace_core::*;

use crate::marketplace::{
    MarketplaceBridgeProvider, MarketplaceCatalogPageDto, MarketplaceCatalogQueryDto,
    MarketplaceInstallRequestDto, MarketplaceOperationStateDto, MarketplacePluginDetailDto,
    MarketplacePluginRefDto,
};
use crate::marketplace_runtime::production_marketplace_provider;
use crate::plugins::PluginService;
use crate::plugins::service::FirstPartyAdapterBinding;
pub use crate::plugins::{
    HostContributionSnapshotDto, HostDeclarativeV1DocumentDto, HostDeclarativeV1NodeDto,
    HostPluginUiStateDto, HostProjectedContributionDto,
};

fn marketplace_error_token(error: crate::marketplace::MarketplaceErrorDto) -> String {
    use crate::marketplace::MarketplaceErrorCodeDto as Code;
    match error.code {
        Code::CatalogUnavailable => "catalog_unavailable",
        Code::CatalogInvalid => "catalog_invalid",
        Code::NotFound => "not_found",
        Code::InvalidRequest => "invalid_request",
        Code::PackageUnavailable => "package_unavailable",
        Code::PackageTooLarge => "package_too_large",
        Code::DigestMismatch => "digest_mismatch",
        Code::ArchiveInvalid => "archive_invalid",
        Code::ReleaseIdentityMismatch => "release_identity_mismatch",
        Code::ConsentMismatch => "consent_mismatch",
        Code::StorageUnavailable => "storage_unavailable",
        Code::Cancelled => "cancelled",
        Code::Internal => "internal",
    }
    .to_owned()
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

// ── Flight DTOs exposed to Dart ──

/// A flight session record.
#[derive(Debug, Clone)]
pub struct FlightSessionDto {
    pub id: i64,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub duration_secs: Option<i64>,
    pub status: String,
    pub satisfaction: Option<i64>,
    pub note: String,
    pub date: String,
}

/// A material record.
#[derive(Debug, Clone)]
pub struct MaterialDto {
    pub id: i64,
    pub title: String,
    pub kind: String,
    pub source_url: Option<String>,
    pub domain: Option<String>,
    pub local_asset_path: Option<String>,
    pub tags: String,
    pub rating: Option<i64>,
}

/// A material linked to a flight.
#[derive(Debug, Clone)]
pub struct FlightMaterialDto {
    pub flight_id: i64,
    pub sort_order: i64,
    pub material: MaterialDto,
}

/// Optional material draft committed atomically with a flight completion.
#[derive(Debug, Clone)]
pub struct FlightCompletionMaterialDto {
    pub title: String,
    pub kind: String,
    pub source_url: Option<String>,
    pub domain: Option<String>,
    pub local_asset_path: Option<String>,
    pub tags: String,
    pub rating: Option<i64>,
}

/// Safe, entitlement-gated presentation state for the first-party AI Recap
/// renderer. It contains no endpoint, provider profile, credential, report,
/// or usage data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapStatusDto {
    /// Stable host-owned state token. The only currently supported value is
    /// `configuration_required`; the composition root is deliberately not
    /// started until the application has supplied real configuration.
    pub state: String,
}

// ── Main API ──

struct CollectorRuntime {
    handle: Mutex<Option<Box<dyn CollectorHandle>>>,
    shutdown_lock: Mutex<()>,
}

impl CollectorRuntime {
    fn new(handle: Option<Box<dyn CollectorHandle>>) -> Self {
        Self {
            handle: Mutex::new(handle),
            shutdown_lock: Mutex::new(()),
        }
    }

    fn set_paused(&self, paused: bool) -> bool {
        let handle = match self.handle.lock() {
            Ok(handle) => handle,
            Err(poisoned) => poisoned.into_inner(),
        };
        let Some(handle) = handle.as_ref() else {
            return false;
        };
        if paused {
            handle.pause();
        } else {
            handle.resume();
        }
        true
    }

    fn shutdown(&self) -> bool {
        // Serialize the full stop/join operation. A concurrent idempotent
        // caller must not observe an empty handle and begin log flushing while
        // the first caller is still joining collector workers.
        let _shutdown_guard = match self.shutdown_lock.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        let handle = {
            let mut slot = match self.handle.lock() {
                Ok(slot) => slot,
                Err(poisoned) => poisoned.into_inner(),
            };
            slot.take()
        };
        let Some(handle) = handle else {
            return false;
        };
        // Stop may join the collector thread, so never hold the slot lock while
        // waiting for platform teardown to finish.
        handle.stop();
        true
    }
}

#[cfg(test)]
fn shutdown_runtime_then_logging(
    collector: &CollectorRuntime,
    shutdown_logging: impl FnOnce(bool),
) -> bool {
    let stopped = collector.shutdown();
    shutdown_logging(stopped);
    stopped
}

fn shutdown_all_in_order(
    stop_plugins: impl FnOnce() -> bool,
    stop_collector: impl FnOnce() -> bool,
    shutdown_logging: impl FnOnce(bool),
) {
    if !stop_plugins() {
        tracing::warn!(
            event = "plugin_shutdown_failed",
            error_code = "plugin_service_unavailable",
            status = "failed"
        );
    }
    let collector_stopped = stop_collector();
    shutdown_logging(collector_stopped);
}

struct ShutdownOnce {
    completed: Mutex<bool>,
}

impl ShutdownOnce {
    fn new() -> Self {
        Self {
            completed: Mutex::new(false),
        }
    }

    fn run(&self, operation: impl FnOnce()) {
        let Ok(mut completed) = self.completed.lock() else {
            // A panic in teardown poisons the gate. Fail closed rather than
            // repeating partially completed shutdown side effects.
            return;
        };
        if *completed {
            return;
        }
        operation();
        *completed = true;
    }
}

pub struct TimeTraceApi {
    db: Arc<SqliteStore>,
    plugins: Arc<PluginService>,
    marketplace: MarketplaceBridgeProvider,
    /// Idempotent owner of the optional platform collector handle.
    collector: CollectorRuntime,
    shutdown_once: ShutdownOnce,
    paused: std::sync::atomic::AtomicBool,
}

impl TimeTraceApi {
    fn with_private_flight<T>(&self, operation: impl FnOnce() -> T) -> Result<T, String> {
        self.plugins
            .with_projectable("private-flight", operation)
            .map_err(|error| error.to_string())
    }

    /// Create the API, opening the DB and starting the background monitor.
    #[frb(sync)]
    pub fn create(db_path: String) -> Result<TimeTraceApi> {
        crate::logging::init();
        tracing::info!(event = "bridge_started", status = "starting");
        let database_path = PathBuf::from(&db_path);
        let db = Arc::new(SqliteStore::open(database_path.clone())?);
        let plugins = Arc::new(
            PluginService::from_database_path(&database_path)
                .map_err(|error| anyhow::anyhow!(error.to_string()))?,
        );
        // Auto-scan startup entries on first launch
        if DataStore::get_all_startup_entries(&*db).is_empty() {
            let entries = WindowsStartupScanner::new().scan();
            DataStore::upsert_startup_entries(&*db, &entries);
        }

        // Start background monitor via the platform-abstracted collector.
        let config = AppConfig::load();
        let initially_paused = !config.auto_start_tracking;
        let collector: Box<dyn ActivityCollector> = Self::create_platform_collector(&config);
        let collector_handle = if collector.is_available() {
            let sink: Box<dyn EventSink> = Box::new(SessionAggregator::new(db.clone()));
            match collector.start(sink) {
                Ok(handle) => {
                    if initially_paused {
                        handle.pause();
                    }
                    Some(handle)
                }
                Err(_error) => {
                    tracing::error!(
                        event = "collector_start_failed",
                        error_code = "collector_start_failed",
                        status = "failed"
                    );
                    None
                }
            }
        } else {
            tracing::info!(event = "collector_unavailable", status = "unavailable");
            None
        };

        let api = TimeTraceApi {
            db,
            plugins: plugins.clone(),
            // Production Marketplace is constructed only from a complete,
            // validated native configuration. Flutter never receives URLs or keys.
            marketplace: production_marketplace_provider(&database_path, plugins.clone()),
            collector: CollectorRuntime::new(collector_handle),
            shutdown_once: ShutdownOnce::new(),
            paused: std::sync::atomic::AtomicBool::new(initially_paused),
        };
        Ok(api)
    }

    /// Stop plugins and collection in order, then flush diagnostics.
    ///
    /// This method intentionally uses normal asynchronous FRB dispatch because
    /// collector teardown may join platform worker threads. Logging shutdown is
    /// kept inside the same Rust call so the host cannot flush while a collector
    /// is still producing events.
    pub fn shutdown_all(&self) {
        self.shutdown_once.run(|| {
            tracing::info!(event = "bridge_shutdown", status = "stopping");
            shutdown_all_in_order(
                || {
                    // The Marketplace watchdog can reload the dynamic catalog.
                    // Stop it before closing the plugin lifecycle fence.
                    self.marketplace.shutdown_lifecycle();
                    self.plugins.stop_all().is_ok()
                },
                || self.collector.shutdown(),
                |stopped| {
                    tracing::info!(
                        event = "bridge_runtime_shutdown",
                        status = if stopped {
                            "stopped"
                        } else {
                            "already_stopped"
                        }
                    );
                    tracing::info!(event = "bridge_logging_shutdown", status = "stopping");
                    crate::logging::shutdown();
                },
            );
        });
    }

    /// Returns the latest immutable plugin lifecycle and contribution view.
    ///
    /// This uses normal asynchronous FRB dispatch so cloning the bounded DTO
    /// never runs on the Flutter UI isolate.
    pub fn plugin_snapshot(&self) -> Result<HostContributionSnapshotDto, String> {
        self.plugins.snapshot().map_err(|error| error.to_string())
    }

    /// Reads the minimal AI Recap presentation state through a revocable,
    /// first-party entitlement lease. A caller without a verified, enabled AI
    /// Recap entitlement receives the same opaque `plugin_not_projectable`
    /// denial used by other plugin data planes.
    ///
    /// This does not create a provider profile, choose a model, start the AI
    /// composition root, or disclose provider configuration. Those operations
    /// remain unavailable until trusted application bootstrap owns their real
    /// inputs.
    pub fn ai_recap_status(&self) -> Result<AiRecapStatusDto, String> {
        let lease = self
            .plugins
            .acquire_first_party_adapter(FirstPartyAdapterBinding::ai_recap_v1())
            .map_err(|error| error.to_string())?;
        self.plugins
            .with_first_party_adapter(&lease, |_| AiRecapStatusDto {
                state: "configuration_required".to_owned(),
            })
            .map_err(|error| error.to_string())
    }

    /// Enables or disables a plugin on a Rust worker. Marketplace-installed
    /// packages persist their desired state in the Marketplace registry and
    /// reload from that registry; bundled plugins retain their lifecycle path.
    ///
    /// This intentionally uses normal asynchronous FRB dispatch because the
    /// transition atomically persists lifecycle state before publishing.
    pub fn set_plugin_enabled(
        &self,
        plugin_id: String,
        enabled: bool,
    ) -> Result<HostContributionSnapshotDto, String> {
        if self
            .marketplace
            .set_installed_enabled(&plugin_id, enabled)
            .map_err(marketplace_error_token)?
        {
            return self.plugins.snapshot().map_err(|error| error.to_string());
        }
        self.plugins
            .set_enabled(&plugin_id, enabled)
            .map_err(|error| error.to_string())
    }

    /// Lists only host-verified Marketplace presentation DTOs.
    pub fn marketplace_list(
        &self,
        query: MarketplaceCatalogQueryDto,
    ) -> Result<MarketplaceCatalogPageDto, String> {
        self.marketplace
            .list(query)
            .map_err(marketplace_error_token)
    }

    /// Resolves a Marketplace detail by its typed publisher/plugin identity.
    pub fn marketplace_detail(
        &self,
        reference: MarketplacePluginRefDto,
    ) -> Result<MarketplacePluginDetailDto, String> {
        self.marketplace
            .detail(reference)
            .map_err(marketplace_error_token)
    }

    /// Installs an exact reviewed Marketplace release with exact consent ids.
    pub fn marketplace_install(
        &self,
        request: MarketplaceInstallRequestDto,
    ) -> MarketplaceOperationStateDto {
        self.marketplace.install(request)
    }

    /// Emit one bounded, structured UI diagnostic without accepting free text.
    ///
    /// Event and error codes must be lowercase canonical tokens. Invalid input
    /// is replaced by a stable rejection event and is never written verbatim.
    #[frb(sync)]
    pub fn emit_ui_diagnostic(
        &self,
        level: String,
        event_code: String,
        error_code: Option<String>,
        duration_ms: Option<u64>,
    ) {
        crate::logging::emit_ui_diagnostic(&level, &event_code, error_code.as_deref(), duration_ms);
    }

    /// Return the process-start diagnostic level mask for the UI bridge.
    ///
    /// Bit positions follow `trace`, `debug`, `info`, `warn`, and `error`.
    /// The filter is intentionally immutable until the next process start.
    #[frb(sync)]
    pub fn ui_diagnostic_level_mask(&self) -> u8 {
        crate::logging::ui_diagnostic_level_mask()
    }

    /// Build the platform-appropriate activity collector.
    ///
    /// On Windows this returns a [`WindowsActivityCollector`] wrapping the
    /// existing Win32 monitor loop. On other platforms (future) this returns
    /// a [`NoopActivityCollector`]. The bridge never references Win32 types
    /// directly — all platform knowledge is encapsulated in the collector.
    #[cfg(target_os = "windows")]
    fn create_platform_collector(config: &AppConfig) -> Box<dyn ActivityCollector> {
        Box::new(WindowsActivityCollector::new(
            Duration::from_millis(config.poll_interval_ms),
            Duration::from_secs(config.idle_threshold_minutes * 60),
            config.excluded_apps.clone(),
        ))
    }

    #[cfg(not(target_os = "windows"))]
    fn create_platform_collector(_config: &AppConfig) -> Box<dyn ActivityCollector> {
        Box::new(NoopActivityCollector::new())
    }

    /// Pause or resume the background tracking monitor.
    #[frb(sync)]
    pub fn set_tracking_paused(&self, paused: bool) {
        if self.collector.set_paused(paused) {
            self.paused
                .store(paused, std::sync::atomic::Ordering::SeqCst);
            tracing::info!(
                event = "tracking_state_changed",
                status = if paused { "paused" } else { "running" }
            );
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
        let idle: i64 = split.iter().map(|x| x.idle_seconds).sum();
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
        let mut app_config = AppConfig::load();
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
        tracing::info!(event = "usage_data_clear_started", status = "starting");
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

    // ── Flight Session API ──

    /// Begin a new flight session. Returns the session id.
    /// Returns an error string if an active session already exists.
    pub fn flight_start(&self) -> Result<i64, String> {
        let now = chrono::Utc::now();
        self.with_private_flight(|| FlightStore::flight_start(&*self.db, now))?
    }

    /// Complete the current active flight.
    pub fn flight_complete(&self, satisfaction: Option<i64>, note: String) -> Result<i64, String> {
        let now = chrono::Utc::now();
        self.with_private_flight(|| {
            FlightStore::flight_complete(&*self.db, now, satisfaction.map(|s| s as i32), &note)
        })?
    }

    /// Completes the current flight and optional material as one async,
    /// lifecycle-gated database transaction.
    pub fn flight_complete_with_material(
        &self,
        satisfaction: Option<i64>,
        note: String,
        material: Option<FlightCompletionMaterialDto>,
    ) -> Result<i64, String> {
        let now = chrono::Utc::now();
        let material = material.map(|value| FlightCompletionMaterial {
            title: value.title,
            kind: MaterialKind::from_str(&value.kind),
            source_url: value.source_url,
            domain: value.domain,
            local_asset_path: value.local_asset_path,
            tags: value.tags,
            rating: value.rating.map(|rating| rating as i32),
        });
        self.with_private_flight(|| {
            FlightStore::flight_complete_with_material(
                &*self.db,
                now,
                satisfaction.map(|value| value as i32),
                &note,
                material.as_ref(),
            )
        })?
    }

    /// Discard the current active flight.
    pub fn flight_discard(&self) -> Result<i64, String> {
        self.with_private_flight(|| FlightStore::flight_discard(&*self.db))?
    }

    /// Get the currently active flight session, if any.
    pub fn flight_get_current(&self) -> Result<Option<FlightSessionDto>, String> {
        self.with_private_flight(|| FlightStore::flight_get_current(&*self.db).map(flight_to_dto))
    }

    /// Get the most recent N completed flight sessions.
    pub fn flight_recent(&self, limit: i64) -> Result<Vec<FlightSessionDto>, String> {
        self.with_private_flight(|| {
            FlightStore::flight_recent(&*self.db, limit.max(0) as usize)
                .into_iter()
                .map(flight_to_dto)
                .collect()
        })
    }

    /// Get flight sessions within a date range (inclusive).
    pub fn flight_range(
        &self,
        start: String,
        end: String,
    ) -> Result<Vec<FlightSessionDto>, String> {
        self.with_private_flight(|| {
            FlightStore::flight_range(&*self.db, parse_date(&start), parse_date(&end))
                .into_iter()
                .map(flight_to_dto)
                .collect()
        })
    }

    /// Insert or find a material by title. Returns the material id.
    pub fn material_upsert(
        &self,
        title: String,
        kind: String,
        source_url: Option<String>,
        domain: Option<String>,
        local_asset_path: Option<String>,
        tags: String,
        rating: Option<i64>,
    ) -> Result<i64, String> {
        self.with_private_flight(|| {
            FlightStore::material_upsert(
                &*self.db,
                &title,
                MaterialKind::from_str(&kind),
                source_url.as_deref(),
                domain.as_deref(),
                local_asset_path.as_deref(),
                &tags,
                rating.map(|r| r as i32),
            )
        })?
    }

    /// Link a material to a flight session.
    pub fn flight_add_material(&self, flight_id: i64, material_id: i64) -> Result<(), String> {
        self.with_private_flight(|| {
            FlightStore::flight_add_material(&*self.db, flight_id, material_id)
        })?
    }

    /// Get all materials linked to a flight session, in order.
    pub fn flight_get_materials(&self, flight_id: i64) -> Result<Vec<FlightMaterialDto>, String> {
        self.with_private_flight(|| {
            FlightStore::flight_get_materials(&*self.db, flight_id)
                .into_iter()
                .map(|link| FlightMaterialDto {
                    flight_id: link.flight_id,
                    sort_order: link.sort_order as i64,
                    material: material_to_dto(link.material),
                })
                .collect()
        })
    }

    /// Get a material by id.
    pub fn material_get(&self, id: i64) -> Result<Option<MaterialDto>, String> {
        self.with_private_flight(|| FlightStore::material_get(&*self.db, id).map(material_to_dto))
    }

    /// Get all materials, newest first.
    pub fn material_list(&self) -> Result<Vec<MaterialDto>, String> {
        self.with_private_flight(|| {
            FlightStore::material_list(&*self.db)
                .into_iter()
                .map(material_to_dto)
                .collect()
        })
    }
}

fn flight_to_dto(r: FlightSessionRecord) -> FlightSessionDto {
    FlightSessionDto {
        id: r.id,
        started_at: r.started_at.to_rfc3339(),
        ended_at: r.ended_at.map(|t| t.to_rfc3339()),
        duration_secs: r.duration_secs,
        status: r.status.as_str().to_string(),
        satisfaction: r.satisfaction.map(|s| s as i64),
        note: r.note,
        date: r.date.to_string(),
    }
}

fn material_to_dto(r: MaterialRecord) -> MaterialDto {
    MaterialDto {
        id: r.id,
        title: r.title,
        kind: r.kind.as_str().to_string(),
        source_url: r.source_url,
        domain: r.domain,
        local_asset_path: r.local_asset_path,
        tags: r.tags,
        rating: r.rating.map(|r| r as i64),
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
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier, Mutex};
    use timetrace_core::FlightStore;

    use super::{
        CollectorRuntime, MarketplaceBridgeProvider, ShutdownOnce, TimeTraceApi, clean_exe_path,
        csv_field, shutdown_all_in_order, shutdown_runtime_then_logging,
    };

    struct RecordingCollectorHandle {
        paused: Arc<AtomicUsize>,
        resumed: Arc<AtomicUsize>,
        stopped: Arc<AtomicUsize>,
    }

    impl timetrace_core::CollectorHandle for RecordingCollectorHandle {
        fn pause(&self) {
            self.paused.fetch_add(1, Ordering::Relaxed);
        }

        fn resume(&self) {
            self.resumed.fetch_add(1, Ordering::Relaxed);
        }

        fn stop(self: Box<Self>) {
            self.stopped.fetch_add(1, Ordering::Relaxed);
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
    fn collector_runtime_stops_exactly_once_and_rejects_late_pause() {
        let paused = Arc::new(AtomicUsize::new(0));
        let resumed = Arc::new(AtomicUsize::new(0));
        let stopped = Arc::new(AtomicUsize::new(0));
        let runtime = CollectorRuntime::new(Some(Box::new(RecordingCollectorHandle {
            paused: Arc::clone(&paused),
            resumed: Arc::clone(&resumed),
            stopped: Arc::clone(&stopped),
        })));

        assert!(runtime.set_paused(true));
        assert!(runtime.shutdown());
        assert!(!runtime.shutdown());
        assert!(!runtime.set_paused(false));
        assert_eq!(paused.load(Ordering::Relaxed), 1);
        assert_eq!(resumed.load(Ordering::Relaxed), 0);
        assert_eq!(stopped.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn shutdown_all_joins_collector_before_logging_shutdown() {
        let paused = Arc::new(AtomicUsize::new(0));
        let resumed = Arc::new(AtomicUsize::new(0));
        let stopped = Arc::new(AtomicUsize::new(0));
        let runtime = CollectorRuntime::new(Some(Box::new(RecordingCollectorHandle {
            paused,
            resumed,
            stopped: Arc::clone(&stopped),
        })));

        let did_stop = shutdown_runtime_then_logging(&runtime, |did_stop| {
            assert!(did_stop);
            assert_eq!(stopped.load(Ordering::Acquire), 1);
        });

        assert!(did_stop);
    }

    #[test]
    fn concurrent_shutdown_gate_executes_the_complete_sequence_once() {
        let once = Arc::new(ShutdownOnce::new());
        let order = Arc::new(Mutex::new(Vec::new()));
        let barrier = Arc::new(Barrier::new(9));
        let mut callers = Vec::new();
        for _ in 0..8 {
            let once = Arc::clone(&once);
            let order = Arc::clone(&order);
            let barrier = Arc::clone(&barrier);
            callers.push(std::thread::spawn(move || {
                barrier.wait();
                once.run(|| {
                    shutdown_all_in_order(
                        || {
                            order.lock().expect("order").push("plugin");
                            true
                        },
                        || {
                            order.lock().expect("order").push("collector");
                            true
                        },
                        |_| order.lock().expect("order").push("logging"),
                    );
                });
            }));
        }
        barrier.wait();
        for caller in callers {
            caller.join().expect("shutdown caller");
        }
        assert_eq!(
            *order.lock().expect("order"),
            ["plugin", "collector", "logging"]
        );
    }

    #[test]
    fn private_flight_data_plane_is_gated_by_rust_lifecycle() {
        let temp = tempfile::tempdir().expect("temp dir");
        let db = Arc::new(
            timetrace_core::SqliteStore::open(temp.path().join("timetrace.db"))
                .expect("open database"),
        );
        let plugins = crate::plugins::PluginService::new(temp.path().join("plugin-state.json"))
            .expect("plugin service");
        let api = TimeTraceApi {
            db,
            plugins: Arc::new(plugins),
            marketplace: MarketplaceBridgeProvider::unavailable(),
            collector: CollectorRuntime::new(None),
            shutdown_once: ShutdownOnce::new(),
            paused: std::sync::atomic::AtomicBool::new(true),
        };

        assert_eq!(api.flight_start().unwrap_err(), "plugin_not_projectable");
        assert_eq!(api.material_list().unwrap_err(), "plugin_not_projectable");
        assert_eq!(api.material_get(1).unwrap_err(), "plugin_not_projectable");
        assert_eq!(
            api.material_upsert(
                "blocked".to_owned(),
                "book".to_owned(),
                None,
                None,
                None,
                String::new(),
                None,
            )
            .unwrap_err(),
            "plugin_not_projectable"
        );
        assert_eq!(
            api.flight_add_material(1, 1).unwrap_err(),
            "plugin_not_projectable"
        );
        api.plugins
            .set_enabled("private-flight", true)
            .expect("enable private flight");
        api.flight_start().expect("start through active plugin");
        let material_id = api
            .material_upsert(
                "allowed".to_owned(),
                "book".to_owned(),
                None,
                None,
                None,
                String::new(),
                None,
            )
            .expect("material through active plugin");
        assert!(
            api.material_get(material_id)
                .expect("material query")
                .is_some()
        );
        assert_eq!(api.material_list().expect("material list").len(), 1);
        api.plugins.stop_all().expect("stop plugins");
        assert_eq!(api.flight_discard().unwrap_err(), "host_shutting_down");
        assert_eq!(api.material_list().unwrap_err(), "host_shutting_down");
        assert_eq!(
            api.material_get(material_id).unwrap_err(),
            "host_shutting_down"
        );
        assert_eq!(
            api.material_upsert(
                "late".to_owned(),
                "book".to_owned(),
                None,
                None,
                None,
                String::new(),
                None,
            )
            .unwrap_err(),
            "host_shutting_down"
        );
        assert_eq!(
            api.flight_add_material(1, material_id).unwrap_err(),
            "host_shutting_down"
        );
        assert_eq!(FlightStore::material_list(&*api.db).len(), 1);
    }
}
