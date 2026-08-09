use std::sync::Mutex;

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

use crate::contracts::process::{ProcessInfo, ProcessQuery, ProcessStatus};

pub struct SysinfoProcessQuery {
    system: Mutex<System>,
}

impl SysinfoProcessQuery {
    pub fn new() -> Self {
        Self { system: Mutex::new(System::new()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, System> {
        match self.system.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

impl ProcessQuery for SysinfoProcessQuery {
    fn refresh(&self) {
        if let Ok(mut sys) = self.system.lock() {
            sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::everything());
        }
    }

    fn list_processes(&self) -> Vec<ProcessInfo> {
        let sys = self.lock();
        sys.processes().iter().map(|(pid, p)| {
            let cpu = p.cpu_usage();
            let mem_mb = p.memory() as f64 / (1024.0 * 1024.0);
            let status = match p.status() {
                sysinfo::ProcessStatus::Run | sysinfo::ProcessStatus::Sleep => ProcessStatus::Running,
                sysinfo::ProcessStatus::Stop => ProcessStatus::Suspended,
                _ => ProcessStatus::Unknown,
            };
            ProcessInfo { pid: pid.as_u32(), name: p.name().to_string_lossy().into_owned(),
                exe_path: p.exe().map(|e| e.to_string_lossy().into_owned()),
                cpu_percent: cpu, memory_mb: mem_mb, status }
        }).collect()
    }

    fn terminate_process(&self, pid: u32) -> Result<(), String> {
        let sys = self.lock();
        if let Some(p) = sys.process(Pid::from_u32(pid)) {
            if p.kill() { Ok(()) } else { Err(format!("Failed to kill {pid}")) }
        } else { Err(format!("Process {pid} not found")) }
    }

    fn get_process(&self, pid: u32) -> Option<ProcessInfo> {
        let sys = self.lock();
        sys.process(Pid::from_u32(pid)).map(|p| ProcessInfo {
            pid, name: p.name().to_string_lossy().into_owned(),
            exe_path: p.exe().map(|e| e.to_string_lossy().into_owned()),
            cpu_percent: p.cpu_usage(), memory_mb: p.memory() as f64 / (1024.0 * 1024.0),
            status: match p.status() {
                sysinfo::ProcessStatus::Run | sysinfo::ProcessStatus::Sleep => ProcessStatus::Running,
                sysinfo::ProcessStatus::Stop => ProcessStatus::Suspended, _ => ProcessStatus::Unknown,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_list_includes_self() {
        let q = SysinfoProcessQuery::new();
        q.refresh();
        assert!(q.list_processes().iter().any(|p| p.pid == std::process::id()));
    }
}
