//! Foreground window monitor — the core tracking loop.
//!
//! Spawns a dedicated thread that polls the foreground window and emits events.

use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use tracing::debug;

use crate::contracts::events::{AppInfo, EventSink, EventSourceHandle, TrackedEvent};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;

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
            if stop_rx.try_recv().is_ok() { debug!("Monitor stopped"); break; }
            if let Ok(pause) = pause_rx.try_recv() { is_paused = pause; }

            if !is_paused {
                let foreground = window_resolver.get_foreground_app();
                let now_idle = idle_detector.is_idle(idle_threshold);

                if now_idle && !is_idle {
                    is_idle = true;
                    sink.accept(TrackedEvent::IdleStarted { timestamp: chrono::Utc::now() });
                    current_app = None;
                } else if !now_idle && is_idle {
                    is_idle = false;
                    let ts = chrono::Utc::now();
                    let dur = idle_detector.idle_duration();
                    let cur = foreground.unwrap_or_else(AppInfo::idle);
                    sink.accept(TrackedEvent::IdleEnded { idle_duration: dur, current_app: cur.clone(), timestamp: ts });
                    current_app = Some(cur);
                    session_start = Instant::now();
                } else if !is_idle {
                    if let Some(fg) = foreground {
                        let changed = current_app.as_ref().map_or(true, |c| c.exe_path != fg.exe_path);
                        if changed {
                            let prev = current_app.take();
                            sink.accept(TrackedEvent::AppSwitched { previous: prev, current: fg.clone(), timestamp: chrono::Utc::now() });
                            current_app = Some(fg);
                            session_start = Instant::now();
                        }
                    }
                }
            }

            if last_heartbeat.elapsed() >= heartbeat_interval {
                last_heartbeat = Instant::now();
                if let Some(ref app) = current_app {
                    sink.accept(TrackedEvent::Heartbeat { current_app: app.clone(), session_duration: session_start.elapsed(), timestamp: chrono::Utc::now() });
                }
            }

            thread::sleep(poll_interval);
        }
    });

    EventSourceHandle::new(stop_tx, pause_tx)
}
