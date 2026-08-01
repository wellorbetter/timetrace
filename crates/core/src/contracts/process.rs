//! Process query — list running processes and terminate them.
//!
//! This is the lightweight task manager capability.

/// Information about a single running process.
#[derive(Debug, Clone)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    pub exe_path: Option<String>,
    /// CPU usage as a percentage (0.0–100.0+, multi-core can exceed 100).
    pub cpu_percent: f32,
    /// Memory usage in megabytes.
    pub memory_mb: f64,
    /// Process status.
    pub status: ProcessStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessStatus {
    Running,
    Suspended,
    Unknown,
}

impl std::fmt::Display for ProcessStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProcessStatus::Running => write!(f, "Running"),
            ProcessStatus::Suspended => write!(f, "Suspended"),
            ProcessStatus::Unknown => write!(f, "Unknown"),
        }
    }
}

/// Queries running processes and their resource usage.
///
/// Implemented by `engine::process_sysinfo` using the `sysinfo` crate.
pub trait ProcessQuery: Send + Sync {
    /// Refresh process list. Call before `list_processes()` to get fresh data.
    fn refresh(&self);

    /// Returns all running processes with resource stats.
    /// Call `refresh()` first to update the data.
    fn list_processes(&self) -> Vec<ProcessInfo>;

    /// Terminate a process by PID.
    /// Returns `Ok(())` on success, or an error message on failure.
    fn terminate_process(&self, pid: u32) -> Result<(), String>;

    /// Get detailed info for a single process.
    fn get_process(&self, pid: u32) -> Option<ProcessInfo>;
}
