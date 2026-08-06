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
    DispatchMessageW, GetMessageW, MSG, TranslateMessage, EVENT_OBJECT_NAMECHANGE,
    EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT,
};

use crate::contracts::events::{AppInfo, EventSink, EventSourceHandle, TrackedEvent};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;

/// Bridge from the WinEvent callback (extern fn) to the monitor thread.
/// HWND is not Send on windows 0.57, so we only pass a signal.
static FG_EVENT: OnceLock<mpsc::Sender<()>> = OnceLock::new();

unsafe extern "system" fn win_event_proc(
    _hook: HWINEVENTHOOK,
    event: u32,
    _hwnd: windows::Win32::Foundation::HWND,
    id_object: i32,
    _id_child: i32,
    _event_thread: u32,
    _ms: u32,
) {
    // Foreground switches AND window-title changes (browser tab switches,
    // e.g. Edge updates its title on every tab) both push a recheck.
    if event == EVENT_SYSTEM_FOREGROUND
        || (event == EVENT_OBJECT_NAMECHANGE && id_object == 0 /* OBJID_WINDOW */)
    {
        if let Some(tx) = FG_EVENT.get() {
            let _ = tx.send(());
        }
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

    // Event-hook thread: SetWinEventHook needs a message loop on the
    // registering thread. Foreground switches are pushed to the monitor.
    {
        let fg_tx = fg_tx.clone();
        thread::spawn(move || {
            unsafe {
                FG_EVENT.set(fg_tx).ok();
                // Foreground switches → app switches.
                let _hook_fg = SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    None,
                    Some(win_event_proc),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT,
                );
                // Window-title changes → browser page switches (Edge etc.).
                let _hook_name = SetWinEventHook(
                    EVENT_OBJECT_NAMECHANGE,
                    EVENT_OBJECT_NAMECHANGE,
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
        let mut is_paused = false;
        let mut is_idle = false;
        let mut last_poll = Instant::now();
        let mut last_title_check = Instant::now();

        loop {
            if stop_rx.try_recv().is_ok() {
                info!("Monitor stopped");
                break;
            }
            if let Ok(pause) = pause_rx.try_recv() {
                is_paused = pause;
            }

            let now = Instant::now();
            // Sleep/resume (or system freeze): close the dangling DB session
            // at the last known active time so the gap is never attributed
            // to the pre-gap app.
            let gap = now - last_poll;
            last_poll = now;
            if gap > poll_interval * 5 {
                info!("Monitor: sleep gap {gap:?} detected - closing session at gap start");
                let gap_start = chrono::Utc::now()
                    - chrono::Duration::from_std(gap).unwrap_or_default();
                sink.accept(TrackedEvent::GapDetected { timestamp: gap_start });
                current_app = None;
                is_idle = false;
            }

            // A WinEventHook fired -> foreground/title changed -> check now.
            // Title-change events can be chatty, so cap rechecks at ~2/s.
            let hook_fired = fg_rx.try_recv().is_ok();
            let can_check = now - last_title_check >= Duration::from_millis(500);
            if hook_fired && can_check {
                last_title_check = now;
            }

            if !is_paused {
                // While already idle, only re-check input (cheap); skip the
                // expensive foreground/process resolution entirely.
                let now_idle_input = idle_detector.is_idle(idle_threshold);

                if now_idle_input && !is_idle {
                    // User stopped typing: idle started (input threshold ago).
                    is_idle = true;
                    info!("Monitor: idle started (input)");
                    sink.accept(TrackedEvent::IdleStarted {
                        timestamp: chrono::Utc::now(),
                        grace: idle_threshold,
                    });
                    current_app = None;
                } else if !now_idle_input {
                    let foreground = window_resolver.get_foreground_app();
                    let lock = foreground
                        .as_ref()
                        .map_or(false, is_lock_or_screensaver);

                    if lock && !is_idle {
                        // Lock screen / screensaver: away instantly, no grace.
                        is_idle = true;
                        info!("Monitor: idle started (lock/screensaver)");
                        sink.accept(TrackedEvent::IdleStarted {
                            timestamp: chrono::Utc::now(),
                            grace: Duration::ZERO,
                        });
                        current_app = None;
                    } else if !lock && is_idle {
                        is_idle = false;
                        let ts = chrono::Utc::now();
                        let dur = idle_detector.idle_duration();
                        let cur = foreground.unwrap_or_else(AppInfo::idle);
                        sink.accept(TrackedEvent::IdleEnded {
                            idle_duration: dur,
                            current_app: cur.clone(),
                            timestamp: ts,
                        });
                        current_app = Some(cur);
                    } else if !is_idle {
                        if let Some(fg) = foreground {
                            // Track per-window-title: "Edge - Bilibili" vs "Edge - GitHub".
                            let same = current_app.as_ref().map_or(false, |c| {
                                c.exe_path == fg.exe_path && c.window_title == fg.window_title
                            });
                            if !same {
                                let prev = current_app.take();
                                sink.accept(TrackedEvent::AppSwitched {
                                    previous: prev,
                                    current: fg.clone(),
                                    timestamp: chrono::Utc::now(),
                                });
                                current_app = Some(fg);
                            }
                        }
                    }
                }
            }

            // Poll cadence: on a fresh hook event check again immediately,
            // otherwise sleep the configured interval (fallback).
            if hook_fired && can_check {
                continue;
            }
            thread::sleep(poll_interval);
        }
    });



/// Lock screen / screensaver / logon foreground processes: the user is
/// away instantly (no input-threshold grace).
fn is_lock_or_screensaver(app: &AppInfo) -> bool {
    let stem = app
        .exe_path
        .rsplit("\\")
        .next()
        .unwrap_or("")
        .trim_end_matches(".exe")
        .to_lowercase();
    stem == "lockapp" || stem == "logonui" || stem.ends_with(".scr")
}
    EventSourceHandle::new(stop_tx, pause_tx)
}
