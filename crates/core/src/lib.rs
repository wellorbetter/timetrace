//! # TimeTrace Core
//!
//! Shared library crate containing all business logic.

pub mod amadeus_adapter;
pub mod amadeus_host;
pub mod config;
pub mod contracts;
pub mod engine;
pub mod error;
pub mod paths;
pub mod storage;

pub use amadeus_adapter::{adapt_tracked_event, AmadeusMemorySink, FanoutEventSink};
pub use amadeus_host::{
    amadeus_converse, configure_openai_compatible_model, handle_triggered_actions,
    persist_amadeus_state, recent_amadeus_memories, search_amadeus_memories,
    shared_amadeus_runtime, take_pending_initiatives, AmadeusHostError,
    PendingInitiative, SharedAmadeusRuntime,
};
pub use config::AppConfig;
pub use contracts::events::{AppInfo, EventSink, EventSource, EventSourceHandle, TrackedEvent};
pub use contracts::idle::IdleDetector;
pub use contracts::process::{ProcessInfo, ProcessQuery, ProcessStatus};
pub use contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};
pub use contracts::storage::{AppMetaRecord, AppUsageSplit, AppUsageSummary, DataStore, SessionRecord};
pub use contracts::window::WindowResolver;
pub use engine::{
    run_monitor_loop, PlatformIdleDetector, PlatformStartupScanner,
    PlatformWindowResolver, SessionAggregator, SysinfoProcessQuery,
};
pub use paths::{
    app_data_dir, config_path, database_path, ensure_app_data_dir, rust_log_path,
    APP_DIR_NAME,
};

#[cfg(target_os = "windows")]
pub use engine::idle_win32::Win32IdleDetector;
#[cfg(target_os = "windows")]
pub use engine::startup_win32::WindowsStartupScanner;
#[cfg(target_os = "windows")]
pub use engine::window_win32::Win32WindowResolver;

#[cfg(target_os = "windows")]
pub use engine::startup_win32::{is_self_start_enabled, set_self_start_enabled};
#[cfg(target_os = "macos")]
pub use engine::startup_macos::{is_self_start_enabled, set_self_start_enabled};

pub use error::AppError;
pub use storage::SqliteStore;
