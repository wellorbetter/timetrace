//! Foreground window monitor — the core tracking loop.
//!
//! Event-driven (like RescueTime): a WinEventHook on
//! EVENT_SYSTEM_FOREGROUND pushes foreground switches instantly, so
//! switching apps is captured in milliseconds instead of waiting for the
//! poll tick. The timed poll remains as a fallback (covers fullscreen
//! games / UAC where the hook may not fire).

use std::sync::mpsc;
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use tracing::{debug, info};

use windows::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetMessageW, MSG, TranslateMessage, EVENT_SYSTEM_FOREGROUND,
    WINEVENT_OUTOFCONTEXT,
};

use crate::contracts::events::{AppInfo, EventSink, EventSourceHandle, TrackedEvent};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;

/// Bridge from the WinEvent callback (extern fn) to the monitor thread.
/// HWND is not Send on windows 0.57, so we only pass a signal.
static FG_EVENT: OnceLock<mpsc::Sender<()>> = OnceLock::new();

unsafe extern "system" fn win_event_proc(
    _hook: HWINEVENTHOOK,
    _event: u32,
    _hwnd: windows::Win32::Foundation::HWND,
    _id: i32,
    _id_child: i32,
    _event_thread: u32,
    _ms: u32,
) {
    if let Some(tx) = FG_EVENT.get() {
        let _ = tx.send(());
    }
}

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
    let (fg_tx, fg_rx) = mpsc::channel::<()>();
    let heartbeat_interval = Duration::from_secs(60);

    // Event-hook thread: SetWinEventHook needs a message loop on the
    // registering thread. Foreground switches are pushed to the monitor.
    {
        let fg_tx = fg_tx.clone();
        thread::spawn(move || {
            unsafe {
                FG_EVENT.set(fg_tx).ok();
                let _hook = SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    None,
                    Some(win_event_proc),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT,
                );
                let mut msg = MSG::default();
                loop {
                    let r = GetMessageW(&mut msg, None, 0, 0);
                    if r.0 == 0 || r.0 == -1 {
                        break;
                    }
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        });
    }

    thread::spawn(move || {
        let mut current_app: Option<AppInfo> = None;
        let mut session_start = Instant::now();
        let mut is_paused = false;
        let mut is_idle = false;
        let mut last_heartbeat = Instant::now();
        let mut last_poll = Instant::now();

        loop {
            if stop_rx.try_recv().is_ok() { info!("Monitor stopped"); break; }
            if let Ok(pause) = pause_rx.try_recv() { is_paused = pause; }

            let now = Instant::now();
            // Sleep/resume detection: reset the dangling session so a whole
            // sleep period is never attributed to the pre-sleep app.
            let gap = now - last_poll;
            last_poll = now;
            if gap > poll_interval * 5 {
                info!("Monitor: sleep gap {gap:?} detected — resetting session");
                current_app = None;
                session_start = now;
                is_idle = false;
            }

            // A WinEventHook fired → foreground changed → check immediately.
            let hook_fired = fg_rx.try_recv().is_ok();

            if !is_paused {
                let foreground = window_resolver.get_foreground_app();
                let now_idle = idle_detector.is_idle(idle_threshold);

                if now_idle && !is_idle {
                    is_idle = true;
                    info!("Monitor: idle started");
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
                        // Track per-window-title: "Edge — Bilibili" vs "Edge — GitHub"
                        let same = current_app.as_ref().map_or(false, |c| {
                            c.exe_path == fg.exe_path && c.window_title == fg.window_title
                        });
                        if !same {
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

            // Poll cadence: on hook events check again immediately (already
            // did), otherwise sleep the configured interval (fallback).
            if hook_fired {
                continue;
            }
            thread::sleep(poll_interval);
        }
    });

    EventSourceHandle::new(stop_tx, pause_tx)
}
