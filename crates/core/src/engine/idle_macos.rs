//! macOS idle detection via Quartz event-source state.
//!
//! This avoids spawning `ioreg` on every tracking poll. Quartz exposes the
//! elapsed time since any keyboard/mouse/tablet input directly from the HID
//! event source, which is exactly the signal TimeTrace needs.

use std::time::Duration;

use crate::contracts::idle::IdleDetector;

const HID_SYSTEM_STATE: i32 = 1;
const ANY_INPUT_EVENT_TYPE: u32 = u32::MAX;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state_id: i32, event_type: u32) -> f64;
}

pub struct MacOsIdleDetector;

impl MacOsIdleDetector {
    pub fn new() -> Self { Self }
}

impl IdleDetector for MacOsIdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() >= threshold
    }

    fn idle_duration(&self) -> Duration {
        let seconds = unsafe {
            CGEventSourceSecondsSinceLastEventType(HID_SYSTEM_STATE, ANY_INPUT_EVENT_TYPE)
        };
        if seconds.is_finite() && seconds > 0.0 {
            Duration::from_secs_f64(seconds)
        } else {
            Duration::ZERO
        }
    }
}
