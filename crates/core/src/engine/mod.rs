pub mod app_identity;
pub mod aggregator;
pub mod idle_win32;
pub mod monitor;
pub mod process_sysinfo;
pub mod startup_win32;
pub mod window_win32;

pub use aggregator::SessionAggregator;
pub use idle_win32::Win32IdleDetector;
pub use monitor::run_monitor_loop;
pub use process_sysinfo::SysinfoProcessQuery;
pub use startup_win32::WindowsStartupScanner;
pub use window_win32::Win32WindowResolver;
