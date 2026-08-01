//! Process query implementation using the `sysinfo` crate.
//!
//! Wraps `sysinfo::System` to provide process listing, resource stats, and termination.

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

use crate::contracts::process::{ProcessInfo, ProcessQuery, ProcessStatus};

pub struct SysinfoProcessQuery {
    system: System,
}

impl SysinfoProcessQuery {
    pub fn new() -> Self {
        Self {
            system: System::new(),
        }
    }
}

impl ProcessQuery for SysinfoProcessQuery {
    fn refresh(&mut self) {
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::everything(),
        );
    }

    fn list_processes(&self) -> Vec<ProcessInfo> {
        self.system
            .processes()
            .iter()
            .map(|(pid, process)| {
                let cpu = process.cpu_usage();
                let mem_mb = process.memory() as f64 / (1024.0 * 1024.0);
                let status = match process.status() {
                    sysinfo::ProcessStatus::Run => ProcessStatus::Running,
                    sysinfo::ProcessStatus::Sleep => ProcessStatus::Running, // sleeping counts as running
                    sysinfo::ProcessStatus::Stop => ProcessStatus::Suspended,
                    sysinfo::ProcessStatus::Zombie => ProcessStatus::Unknown,
                    sysinfo::ProcessStatus::Tracing => ProcessStatus::Unknown,
                    sysinfo::ProcessStatus::Dead => ProcessStatus::Unknown,
                    _ => ProcessStatus::Unknown,
                };

                ProcessInfo {
                    pid: pid.as_u32(),
                    name: process.name().to_string_lossy().into_owned(),
                    exe_path: process.exe().map(|p| p.to_string_lossy().into_owned()),
                    cpu_percent: cpu,
                    memory_mb: mem_mb,
                    status,
                }
            })
            .collect()
    }

    fn terminate_process(&self, pid: u32) -> Result<(), String> {
        let p = Pid::from_u32(pid);
        if let Some(process) = self.system.process(p) {
            if process.kill() {
                Ok(())
            } else {
                Err(format!("Failed to kill process {pid}. It may require admin rights."))
            }
        } else {
            Err(format!("Process {pid} not found"))
        }
    }

    fn get_process(&self, pid: u32) -> Option<ProcessInfo> {
        let p = Pid::from_u32(pid);
        self.system.process(p).map(|process| {
            ProcessInfo {
                pid: pid,
                name: process.name().to_string_lossy().into_owned(),
                exe_path: process.exe().map(|p| p.to_string_lossy().into_owned()),
                cpu_percent: process.cpu_usage(),
                memory_mb: process.memory() as f64 / (1024.0 * 1024.0),
                status: match process.status() {
                    sysinfo::ProcessStatus::Run | sysinfo::ProcessStatus::Sleep => ProcessStatus::Running,
                    sysinfo::ProcessStatus::Stop => ProcessStatus::Suspended,
                    _ => ProcessStatus::Unknown,
                },
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_process_query_does_not_crash() {
        let mut query = SysinfoProcessQuery::new();
        query.refresh();
        let processes = query.list_processes();
        // Our own process should be in the list
        let own_pid = std::process::id();
        assert!(processes.iter().any(|p| p.pid == own_pid));
    }

    #[test]
    fn test_terminate_nonexistent_process() {
        let query = SysinfoProcessQuery::new();
        let result = query.terminate_process(99999);
        assert!(result.is_err());
    }
}
