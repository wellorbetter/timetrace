//! macOS idle detection via IOHIDSystem's HIDIdleTime (nanoseconds).

use std::process::Command;
use std::time::Duration;

use crate::contracts::idle::IdleDetector;

pub struct MacOsIdleDetector;

impl MacOsIdleDetector {
    pub fn new() -> Self { Self }
}

impl IdleDetector for MacOsIdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() >= threshold
    }

    fn idle_duration(&self) -> Duration {
        let output = match Command::new("ioreg").args(["-c", "IOHIDSystem"]).output() {
            Ok(v) if v.status.success() => v,
            _ => return Duration::ZERO,
        };
        let text = String::from_utf8_lossy(&output.stdout);
        let marker = "\"HIDIdleTime\" = ";
        let value = text.lines().find_map(|line| {
            let i = line.find(marker)?;
            line[i + marker.len()..].trim().split_whitespace().next()?.parse::<u64>().ok()
        }).unwrap_or(0);
        Duration::from_nanos(value)
    }
}
