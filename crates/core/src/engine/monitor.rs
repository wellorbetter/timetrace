//! Foreground application monitor — the core tracking loop.
//!
//! Windows supplements the timed poll with WinEventHook notifications for
//! near-instant foreground/title changes. Other desktop platforms use the same
//! portable poll loop without the Windows-specific hook.

use std::sync::mpsc;
#[cfg(target_os = "windows")]
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use tracing::info;

#[cfg(target_os = "windows")]
use windows::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
#[cfg(target_os = "windows")]
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, PeekMessageW, TranslateMessage, MSG, EVENT_OBJECT_NAMECHANGE,
    EVENT_SYSTEM_FOREGROUND, PM_REMOVE, WINEVENT_OUTOFCONTEXT,
};

use crate::contracts::events::{AppInfo, EventSink, EventSourceHandle, TrackedEvent};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;

#[cfg(target_os = "windows")]
static FG_EVENT: OnceLock<mpsc::Sender<()>> = OnceLock::new();

#[cfg(target_os = "windows")]
unsafe extern "system" fn win_event_proc(
    _hook: HWINEVENTHOOK,
    event: u32,
    _hwnd: windows::Win32::Foundation::HWND,
    id_object: i32,
    _id_child: i32,
    _event_thread: u32,
    _ms: u32,
) {
    if event == EVENT_SYSTEM_FOREGROUND
        || (event == EVENT_OBJECT_NAMECHANGE && id_object == 0)
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
    excluded_apps: Vec<String>,
    mut sink: Box<dyn EventSink>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (hook_stop_tx, hook_stop_rx) = mpsc::channel::<()>();
    let (pause_tx, pause_rx) = mpsc::channel::<bool>();
    let (fg_tx, fg_rx) = mpsc::channel::<()>();

    #[cfg(target_os = "windows")]
    {
        let fg_tx = fg_tx.clone();
        thread::spawn(move || {
            unsafe {
                FG_EVENT.set(fg_tx).ok();
                let _hook_fg = SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    None,
                    Some(win_event_proc),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT,
                );
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
                    if hook_stop_rx.try_recv().is_ok() {
                        break;
                    }
                    if PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    } else {
                        thread::sleep(Duration::from_millis(50));
                    }
                }
            }
        });
    }

    #[cfg(not(target_os = "windows"))]
    {
        // Keep the sender/receiver pair alive for EventSourceHandle's uniform
        // lifecycle API. No platform hook thread is needed on polling targets.
        drop(fg_tx);
        drop(hook_stop_rx);
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
                if pause && !is_paused {
                    // Pausing is a real observation boundary. Close the active
                    // session immediately and forget the foreground identity so
                    // resuming emits a fresh AppSwitched event even if the user
                    // stayed in the same application.
                    sink.accept(TrackedEvent::GapDetected {
                        timestamp: chrono::Utc::now(),
                    });
                    current_app = None;
                    is_idle = false;
                }
                is_paused = pause;
            }

            let now = Instant::now();
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

            let hook_fired = fg_rx.try_recv().is_ok();
            let can_check = now - last_title_check >= Duration::from_millis(500);
            if hook_fired && can_check {
                last_title_check = now;
            }

            if !is_paused {
                let now_idle_input = idle_detector.is_idle(idle_threshold);

                if now_idle_input && !is_idle {
                    is_idle = true;
                    info!("Monitor: idle started (input)");
                    sink.accept(TrackedEvent::IdleStarted {
                        timestamp: chrono::Utc::now(),
                        grace: idle_threshold,
                    });
                    current_app = None;
                } else if !now_idle_input {
                    let raw_foreground = window_resolver.get_foreground_app();
                    let excluded = raw_foreground
                        .as_ref()
                        .is_some_and(|app| is_excluded(app, &excluded_apps));
                    if excluded && current_app.take().is_some() {
                        sink.accept(TrackedEvent::GapDetected {
                            timestamp: chrono::Utc::now(),
                        });
                    }
                    let foreground =
                        raw_foreground.filter(|app| !is_excluded(app, &excluded_apps));
                    let lock = foreground.as_ref().is_some_and(is_lock_or_screensaver);

                    if lock && !is_idle {
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
                        if let Some(cur) = foreground {
                            sink.accept(TrackedEvent::IdleEnded {
                                idle_duration: dur,
                                current_app: cur.clone(),
                                timestamp: ts,
                            });
                            current_app = Some(cur);
                        } else {
                            sink.accept(TrackedEvent::GapDetected { timestamp: ts });
                            current_app = None;
                        }
                    } else if !is_idle {
                        if let Some(fg) = foreground {
                            let same = current_app.as_ref().is_some_and(|c| {
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

            if hook_fired && can_check {
                continue;
            }
            thread::sleep(poll_interval);
        }
    });

    EventSourceHandle::new(stop_tx, pause_tx, hook_stop_tx)
}

fn is_lock_or_screensaver(app: &AppInfo) -> bool {
    let stem = app
        .exe_path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or("")
        .trim_end_matches(".exe")
        .to_lowercase();
    stem == "lockapp"
        || stem == "logonui"
        || stem.ends_with(".scr")
        || stem == "loginwindow"
        || stem == "screensaverengine"
}

fn is_excluded(app: &AppInfo, excluded_apps: &[String]) -> bool {
    let exe_name = app
        .exe_path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let exe_stem = exe_name.strip_suffix(".exe").unwrap_or(&exe_name);
    let display_name = app.display_name.to_ascii_lowercase();
    excluded_apps.iter().any(|excluded| {
        let value = excluded.trim().to_ascii_lowercase();
        let value = value.strip_suffix(".exe").unwrap_or(&value);
        value == exe_name || value == exe_stem || value == display_name
    })
}

#[cfg(test)]
mod tests {
    use super::is_excluded;
    use crate::contracts::events::AppInfo;

    #[test]
    fn excludes_by_exe_name_with_or_without_extension() {
        let app = AppInfo::new(r"C:\Apps\Example.exe".into(), "Example".into());
        assert!(is_excluded(&app, &["example".into()]));
        assert!(is_excluded(&app, &["EXAMPLE.EXE".into()]));
        assert!(!is_excluded(&app, &["other.exe".into()]));
    }
}
