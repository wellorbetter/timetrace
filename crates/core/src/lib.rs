//! # TimeTrace Core
//!
//! Shared library crate containing all business logic.

pub mod config;
pub mod contracts;
pub mod engine;
pub mod error;
pub mod storage;

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

#[cfg(target_os = "windows")]
pub use engine::startup_win32::{is_self_start_enabled, set_self_start_enabled};
#[cfg(target_os = "macos")]
pub use engine::startup_macos::{is_self_start_enabled, set_self_start_enabled};

pub use error::AppError;
pub use storage::SqliteStore;
