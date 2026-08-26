pub mod app_identity;
pub mod aggregator;
pub mod monitor;
pub mod process_sysinfo;

#[cfg(target_os = "windows")]
pub mod idle_win32;
#[cfg(target_os = "windows")]
pub mod startup_win32;
#[cfg(target_os = "windows")]
pub mod window_win32;

#[cfg(target_os = "macos")]
pub mod idle_macos;
#[cfg(target_os = "macos")]
pub mod startup_macos;
#[cfg(target_os = "macos")]
pub mod window_macos;

pub use aggregator::SessionAggregator;
pub use monitor::run_monitor_loop;
pub use process_sysinfo::SysinfoProcessQuery;

// Platform-neutral names used by the Flutter bridge and new cross-platform code.
#[cfg(target_os = "windows")]
pub use idle_win32::Win32IdleDetector as PlatformIdleDetector;
#[cfg(target_os = "windows")]
pub use startup_win32::WindowsStartupScanner as PlatformStartupScanner;
#[cfg(target_os = "windows")]
pub use window_win32::Win32WindowResolver as PlatformWindowResolver;

#[cfg(target_os = "macos")]
pub use idle_macos::MacOsIdleDetector as PlatformIdleDetector;
#[cfg(target_os = "macos")]
pub use startup_macos::MacOsStartupScanner as PlatformStartupScanner;
#[cfg(target_os = "macos")]
pub use window_macos::MacOsWindowResolver as PlatformWindowResolver;

// Preserve the historical engine::* names for Windows-only TUI/egui callers.
// This keeps the macOS refactor backwards-compatible instead of forcing those
// frontends to migrate in the same change.
#[cfg(target_os = "windows")]
pub use idle_win32::Win32IdleDetector;
#[cfg(target_os = "windows")]
pub use startup_win32::WindowsStartupScanner;
#[cfg(target_os = "windows")]
pub use window_win32::Win32WindowResolver;
