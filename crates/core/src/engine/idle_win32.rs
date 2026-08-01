//! Win32 implementation of `IdleDetector`.
//!
//! Uses `GetLastInputInfo` to determine how long since the last user input.

use std::mem;
use std::time::Duration;

use windows::Win32::UI::Input::KeyboardAndMouse::GetLastInputInfo;
use windows::Win32::System::Time::GetTickCount;

use crate::contracts::idle::IdleDetector;

pub struct Win32IdleDetector;

impl IdleDetector for Win32IdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() > threshold
    }

    fn idle_duration(&self) -> Duration {
        unsafe {
            let mut last_input = windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO {
                cbSize: mem::size_of::<windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO>() as u32,
                dwTime: 0,
            };

            if GetLastInputInfo(&mut last_input).is_err() {
                return Duration::ZERO;
            }

            let tick_count = GetTickCount();
            let elapsed = tick_count.saturating_sub(last_input.dwTime);
            Duration::from_millis(elapsed as u64)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_idle_detector_does_not_crash() {
        let detector = Win32IdleDetector;
        let duration = detector.idle_duration();
        // Should return a valid duration (could be zero in CI)
        assert!(duration.as_millis() < 86_400_000); // less than a day
    }
}
