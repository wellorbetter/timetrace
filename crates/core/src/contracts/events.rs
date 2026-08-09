//! Event system — the core communication protocol.
//!
//! `EventSource` produces events. `EventSink` consumes them.
//! The monitor thread owns an `EventSource`; the aggregator owns an `EventSink`.
//! They communicate via a channel — no shared state.

use std::time::Duration;

/// Minimal information about a foreground application.
///
/// Constructed by `WindowResolver` and embedded in every event.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AppInfo {
    pub exe_path: String,
    pub display_name: String,
    pub window_title: Option<String>,
}

impl AppInfo {
    pub fn new(exe_path: String, display_name: String) -> Self {
        Self { exe_path, display_name, window_title: None }
    }

    pub fn with_title(mut self, title: String) -> Self {
        self.window_title = Some(title);
        self
    }

    /// Idle pseudo-app.
    pub fn idle() -> Self {
        Self {
            exe_path: String::new(),
            display_name: "__IDLE__".into(),
            window_title: None,
        }
    }

    pub fn is_idle(&self) -> bool {
        self.display_name == "__IDLE__"
    }
}

/// Events produced by the foreground monitor.
///
/// The monitor thread sends these to the aggregator via a channel.
#[derive(Debug, Clone)]
pub enum TrackedEvent {
    /// Foreground window changed to a different application.
    AppSwitched {
        /// The app that was in foreground before (None on first event).
        previous: Option<AppInfo>,
        /// The app that is now in foreground.
        current: AppInfo,
        /// When the switch happened.
        timestamp: chrono::DateTime<chrono::Utc>,
    },

    /// User became idle (no input for longer than the threshold, or the
    /// screen was locked / a screensaver started).
    IdleStarted {
        /// When idle was detected.
        timestamp: chrono::DateTime<chrono::Utc>,
        /// Trailing grace period (input-threshold minutes) that must NOT be
        /// attributed to the previous app. Zero for lock/screensaver (the
        /// user left instantly).
        grace: Duration,
    },

    /// The monitor stopped observing for longer than expected (sleep,
    /// hibernate, or a system freeze). Closes any dangling session at
    /// `timestamp` (the last known active time) so the gap is never
    /// attributed to the pre-gap app.
    GapDetected {
        /// Last known active time (gap start).
        timestamp: chrono::DateTime<chrono::Utc>,
    },

    /// User returned from idle.
    IdleEnded {
        /// How long the idle period lasted.
        idle_duration: Duration,
        /// The app currently in foreground when the user returned.
        current_app: AppInfo,
        timestamp: chrono::DateTime<chrono::Utc>,
    },

}

/// Produces `TrackedEvent`s on its own thread/timer.
///
/// # Lifecycle
/// 1. Call `start(sink)` to begin producing events.
/// 2. Events are sent to the provided `EventSink`.
/// 3. Drop the returned `EventSourceHandle` to stop.
pub trait EventSource: Send {
    fn start(&mut self, sink: Box<dyn EventSink>) -> EventSourceHandle;
}

/// Handle for controlling a running `EventSource`.
///
/// Dropping this handle signals the source to stop.
/// Use `pause()` / `resume()` for temporary suspension without full teardown.
pub struct EventSourceHandle {
    stop_tx: std::sync::mpsc::Sender<()>,
    hook_stop_tx: std::sync::mpsc::Sender<()>,
    pause_tx: std::sync::mpsc::Sender<bool>,
}

impl EventSourceHandle {
    pub fn new(
        stop_tx: std::sync::mpsc::Sender<()>,
        pause_tx: std::sync::mpsc::Sender<bool>,
        hook_stop_tx: std::sync::mpsc::Sender<()>,
    ) -> Self {
        Self { stop_tx, hook_stop_tx, pause_tx }
    }

    /// Signal the event source to stop permanently.
    pub fn stop(self) {
        let _ = self.stop_tx.send(());
        let _ = self.hook_stop_tx.send(());
    }

    /// Pause event production (tracking suspended).
    pub fn pause(&self) {
        let _ = self.pause_tx.send(true);
    }

    /// Resume event production.
    pub fn resume(&self) {
        let _ = self.pause_tx.send(false);
    }
}

impl Drop for EventSourceHandle {
    fn drop(&mut self) {
        let _ = self.stop_tx.send(());
        let _ = self.hook_stop_tx.send(());
    }
}

/// Consumes `TrackedEvent`s — typically writes to storage.
pub trait EventSink: Send {
    fn accept(&mut self, event: TrackedEvent);
}
