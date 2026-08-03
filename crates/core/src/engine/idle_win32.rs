use std::mem;
use std::time::Duration;

use windows::Win32::UI::Input::KeyboardAndMouse::GetLastInputInfo;

use crate::contracts::idle::IdleDetector;

/// Idle detection via `GetLastInputInfo` + `GetTickCount`.
///
/// idle_ms = GetTickCount() - lastInputInfo.dwTime
/// This is the standard, correct approach.
pub struct Win32IdleDetector;

impl Win32IdleDetector {
    pub fn new() -> Self {
        Self
    }

    fn capture() -> (u32, u32) {
        unsafe {
            let mut info = windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO {
                cbSize: mem::size_of::<windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO>() as u32,
                dwTime: 0,
            };
            let _ = GetLastInputInfo(&mut info);
            // GetTickCount is in SystemInformation (Win32_System_SystemInformation feature)
            let tick = windows::Win32::System::SystemInformation::GetTickCount();
            (tick, info.dwTime)
        }
    }
}

impl IdleDetector for Win32IdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() > threshold
    }

    fn idle_duration(&self) -> Duration {
        let (tick, last_input) = Self::capture();
        let idle_ms = tick.saturating_sub(last_input);
        Duration::from_millis(idle_ms as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_does_not_crash() {
        let d = Win32IdleDetector::new();
        let dur = d.idle_duration();
        assert!(dur.as_millis() < 86_400_000);
    }

    #[test]
    fn test_idle_less_than_day() {
        let d = Win32IdleDetector::new();
        assert!(!d.is_idle(Duration::from_secs(86400)));
    }
}
