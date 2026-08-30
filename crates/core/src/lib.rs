//! # TimeTrace Core
//!
//! Shared library crate containing all business logic.

pub mod config;
pub mod contracts;
pub mod engine;
pub mod error;
pub mod paths;
pub mod storage;

pub use config::AppConfig;
pub use contracts::events::{AppInfo, EventSink, EventSource, EventSourceHandle, TrackedEvent};
pub use contracts::idle::IdleDetector;
pub use contracts::process::{ProcessInfo, ProcessQuery, ProcessStatus};
pub use contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};
pub use contracts::storage::{
    AppMetaRecord, AppUsageSplit, AppUsageSummary, DataStore, DiaryEntryRecord, DiarySource,
    SessionRecord,
};
pub use contracts::window::WindowResolver;
pub use engine::{run_monitor_loop, SessionAggregator, SysinfoProcessQuery};
#[cfg(any(target_os = "windows", target_os = "macos"))]
pub use engine::{PlatformIdleDetector, PlatformStartupScanner, PlatformWindowResolver};
pub use paths::{
    app_data_dir, config_path, database_path, ensure_app_data_dir, rust_log_path,
    APP_DIR_NAME,
};

// Windows-only compatibility aliases for the legacy TUI/egui frontends. New
// cross-platform code should use the neutral Platform* names above.
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
