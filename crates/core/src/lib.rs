//! # TimeTrace Core
//!
//! Shared library crate containing all business logic.
//! Used by both `timetrace-tui` (terminal) and `timetrace-gui` (desktop).

pub mod config;
pub mod contracts;
pub mod engine;
pub mod error;
pub mod storage;

// Re-export commonly used types
pub use config::AppConfig;
pub use contracts::events::{AppInfo, EventSink, EventSource, EventSourceHandle, TrackedEvent};
pub use contracts::idle::IdleDetector;
pub use contracts::process::{ProcessInfo, ProcessQuery, ProcessStatus};
pub use contracts::startup::{DisableResult, StartupEntryRecord, StartupScanner};
pub use contracts::storage::{AppMetaRecord, AppUsageSummary, DataStore, SessionRecord};
pub use contracts::window::WindowResolver;
pub use engine::{
    run_monitor_loop, SessionAggregator, SysinfoProcessQuery,
    Win32IdleDetector, Win32WindowResolver, WindowsStartupScanner,
};
pub use error::AppError;
pub use storage::SqliteStore;
