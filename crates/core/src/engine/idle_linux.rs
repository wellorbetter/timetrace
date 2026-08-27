//! Linux/X11 idle detection via the XScreenSaver extension.
//!
//! This keeps TimeTrace self-contained on X11/XWayland and avoids shelling out
//! to `xprintidle`. Pure Wayland compositors may intentionally hide global
//! input-idle information; that backend is tracked separately.

use std::time::Duration;

use x11rb::connection::Connection;
use x11rb::protocol::screensaver::ConnectionExt as _;

use crate::contracts::idle::IdleDetector;

pub struct LinuxIdleDetector;

impl LinuxIdleDetector {
    pub fn new() -> Self {
        Self
    }

    fn query_idle() -> Option<Duration> {
        let (conn, screen_num) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen_num)?.root;
        let reply = conn.screensaver_query_info(root).ok()?.reply().ok()?;
        Some(Duration::from_millis(reply.ms_since_user_input.into()))
    }
}

impl IdleDetector for LinuxIdleDetector {
    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() >= threshold
    }

    fn idle_duration(&self) -> Duration {
        Self::query_idle().unwrap_or(Duration::ZERO)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_is_infallible_without_display() {
        let detector = LinuxIdleDetector::new();
        let _ = detector.idle_duration();
    }
}
