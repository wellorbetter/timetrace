use std::mem;
use std::time::{Duration, Instant};

use windows::Win32::UI::Input::KeyboardAndMouse::GetLastInputInfo;

use crate::contracts::idle::IdleDetector;

/// Tracks last input time using Win32 `GetLastInputInfo`, compared to a baseline `Instant`.
pub struct Win32IdleDetector {
    baseline: Instant,
    baseline_tick: u32,
}

impl Win32IdleDetector {
    pub fn new() -> Self {
        let (baseline, baseline_tick) = Self::capture();
        Self { baseline, baseline_tick }
    }

    fn capture() -> (Instant, u32) {
        let now = Instant::now();
        let tick = unsafe {
            let mut info = windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO {
                cbSize: mem::size_of::<windows::Win32::UI::Input::KeyboardAndMouse::LASTINPUTINFO>() as u32,
                dwTime: 0,
            };
            let _ = GetLastInputInfo(&mut info);
            info.dwTime
        };
        (now, tick)
    }
}

impl IdleDetector for Win32IdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() > threshold
    }

    fn idle_duration(&self) -> Duration {
        let (now, tick) = Self::capture();
        let elapsed_ticks = tick.saturating_sub(self.baseline_tick);
        let elapsed_ms = now.duration_since(self.baseline);
        // The actual idle time is: current tick - last input tick
        // We can compute last_input_time = baseline - (baseline_tick - last_input_tick)
        // idle = now - last_input_time
        //      = now - (baseline - (baseline_tick - last_input_tick))
        //      = (now - baseline) + (baseline_tick - last_input_tick)
        let baseline_to_last_input = Duration::from_millis(self.baseline_tick.saturating_sub(tick) as u64);
        if elapsed_ms > baseline_to_last_input {
            elapsed_ms - baseline_to_last_input
        } else {
            Duration::ZERO
        }
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
}
