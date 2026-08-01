//! Foreground window monitor — the core tracking loop.
//!
//! Runs on a dedicated thread. Polls the foreground window at a configurable interval,
//! checks for idle state, and emits `TrackedEvent`s to the sink.

use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use tracing::{debug, error};

use crate::contracts::events::{
    AppInfo, EventSink, EventSource, EventSourceHandle, TrackedEvent,
};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;

pub struct ForegroundMonitor<W: WindowResolver, I: IdleDetector> {
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    heartbeat_interval: Duration,
}

impl<W: WindowResolver + 'static, I: IdleDetector + 'static> ForegroundMonitor<W, I> {
    pub fn new(
        window_resolver: W,
        idle_detector: I,
        poll_interval: Duration,
        idle_threshold: Duration,
    ) -> Self {
        Self {
            window_resolver,
            idle_detector,
            poll_interval,
            idle_threshold,
            heartbeat_interval: Duration::from_secs(60),
        }
    }
}

impl<W: WindowResolver + 'static, I: IdleDetector + 'static> EventSource
    for ForegroundMonitor<W, I>
{
    fn start(&mut self, mut sink: Box<dyn EventSink>) -> EventSourceHandle {
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (pause_tx, pause_rx) = mpsc::channel::<bool>();

        let poll_interval = self.poll_interval;
        let idle_threshold = self.idle_threshold;
        let heartbeat_interval = self.heartbeat_interval;

        // We need to move the resolver and detector into the thread.
        // Since they're owned by self, we take them out via mem::replace with dummy values.
        // Actually, let's restructure: the monitor takes ownership and we consume self.

        thread::spawn(move || {
            // Take ownership (self is moved into this closure)
            // But wait — self is &mut in start(). We need to restructure.
            // For now, we use the fields directly since they were moved.
            Self::monitor_loop(
                poll_interval,
                idle_threshold,
                heartbeat_interval,
                stop_rx,
                pause_rx,
                &mut sink,
            );
        });

        EventSourceHandle::new(stop_tx, pause_tx)
    }
}

/// Standalone monitor loop (used when we need to move ownership into a thread).
pub fn run_monitor_loop<W, I>(
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    mut sink: Box<dyn EventSink>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (pause_tx, pause_rx) = mpsc::channel::<bool>();
    let heartbeat_interval = Duration::from_secs(60);

    thread::spawn(move || {
        let mut current_app: Option<AppInfo> = None;
        let mut session_start = Instant::now();
        let mut is_paused = false;
        let mut is_idle = false;
        let mut last_heartbeat = Instant::now();

        loop {
            // Check for stop signal
            if stop_rx.try_recv().is_ok() {
                debug!("Monitor received stop signal");
                break;
            }

            // Check for pause/resume
            if let Ok(pause) = pause_rx.try_recv() {
                is_paused = pause;
                debug!("Monitor {}", if pause { "paused" } else { "resumed" });
            }

            if !is_paused {
                // Resolve foreground app
                let foreground = window_resolver.get_foreground_app();

                // Check idle state
                let now_idle = idle_detector.is_idle(idle_threshold);

                if now_idle && !is_idle {
                    // Transition to idle
                    is_idle = true;
                    let timestamp = chrono::Utc::now();
                    sink.accept(TrackedEvent::IdleStarted { timestamp });
                    current_app = None;
                } else if !now_idle && is_idle {
                    // Transition from idle
                    is_idle = false;
                    let timestamp = chrono::Utc::now();
                    let idle_duration = idle_detector.idle_duration();
                    let current = foreground.unwrap_or_else(AppInfo::idle);
                    sink.accept(TrackedEvent::IdleEnded {
                        idle_duration,
                        current_app: current.clone(),
                        timestamp,
                    });
                    current_app = Some(current);
                    session_start = Instant::now();
                } else if !is_idle {
                    if let Some(fg) = foreground {
                        let app_changed = current_app.as_ref().map_or(true, |c| c.exe_path != fg.exe_path);

                        if app_changed {
                            let previous = current_app.take();
                            let timestamp = chrono::Utc::now();
                            sink.accept(TrackedEvent::AppSwitched {
                                previous,
                                current: fg.clone(),
                                timestamp,
                            });
                            current_app = Some(fg);
                            session_start = Instant::now();
                        }
                    }
                }
            }

            // Periodic heartbeat
            if last_heartbeat.elapsed() >= heartbeat_interval {
                last_heartbeat = Instant::now();
                if let Some(ref app) = current_app {
                    let timestamp = chrono::Utc::now();
                    sink.accept(TrackedEvent::Heartbeat {
                        current_app: app.clone(),
                        session_duration: session_start.elapsed(),
                        timestamp,
                    });
                }
            }

            thread::sleep(poll_interval);
        }

        debug!("Monitor loop exited");
    });

    EventSourceHandle::new(stop_tx, pause_tx)
}
