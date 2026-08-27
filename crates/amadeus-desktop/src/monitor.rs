use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use amadeus_core::{ComputerActivity, PerceptionEvent};
use chrono::Utc;
use tracing::info;

use crate::contracts::{ForegroundResolver, IdleDetector, ObserverHandle, PerceptionSink};

pub fn run_observer_loop<R, I>(
    resolver: R,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    excluded_apps: Vec<String>,
    mut sink: Box<dyn PerceptionSink>,
) -> ObserverHandle
where
    R: ForegroundResolver + 'static,
    I: IdleDetector + 'static,
{
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (pause_tx, pause_rx) = mpsc::channel::<bool>();

    thread::spawn(move || {
        let mut current: Option<ComputerActivity> = None;
        let mut paused = false;
        let mut idle = false;
        let mut last_poll = Instant::now();

        loop {
            if stop_rx.try_recv().is_ok() {
                info!("Amadeus desktop observer stopped");
                break;
            }
            if let Ok(value) = pause_rx.try_recv() {
                paused = value;
            }

            let monotonic_now = Instant::now();
            let gap = monotonic_now.saturating_duration_since(last_poll);
            last_poll = monotonic_now;
            if gap > poll_interval.saturating_mul(5) {
                let gap_start = Utc::now()
                    - chrono::Duration::from_std(gap).unwrap_or_default();
                sink.accept(PerceptionEvent::GapDetected { at: gap_start });
                current = None;
                idle = false;
            }

            if !paused {
                let input_idle = idle_detector.is_idle(idle_threshold);
                if input_idle && !idle {
                    idle = true;
                    sink.accept(PerceptionEvent::IdleStarted {
                        at: Utc::now(),
                        grace_ms: idle_threshold.as_millis().min(u64::MAX as u128) as u64,
                    });
                    current = None;
                } else if !input_idle {
                    let raw = resolver.current_activity();
                    let excluded = raw
                        .as_ref()
                        .is_some_and(|activity| is_excluded(activity, &excluded_apps));
                    if excluded && current.take().is_some() {
                        sink.accept(PerceptionEvent::GapDetected { at: Utc::now() });
                    }
                    let foreground = raw.filter(|activity| !is_excluded(activity, &excluded_apps));
                    let locked = foreground.as_ref().is_some_and(is_lock_or_screensaver);

                    if locked && !idle {
                        idle = true;
                        sink.accept(PerceptionEvent::IdleStarted {
                            at: Utc::now(),
                            grace_ms: 0,
                        });
                        current = None;
                    } else if !locked && idle {
                        idle = false;
                        let at = Utc::now();
                        if let Some(activity) = foreground {
                            sink.accept(PerceptionEvent::IdleEnded {
                                current: activity.clone(),
                                at,
                            });
                            current = Some(activity);
                        } else {
                            sink.accept(PerceptionEvent::GapDetected { at });
                            current = None;
                        }
                    } else if !idle {
                        if let Some(activity) = foreground {
                            let same = current.as_ref().is_some_and(|previous| {
                                previous.app_id == activity.app_id
                                    && previous.window_title == activity.window_title
                            });
                            if !same {
                                let previous = current.take();
                                sink.accept(PerceptionEvent::ForegroundChanged {
                                    previous,
                                    current: activity.clone(),
                                    at: Utc::now(),
                                });
                                current = Some(activity);
                            }
                        }
                    }
                }
            }

            thread::sleep(poll_interval);
        }
    });

    ObserverHandle::new(stop_tx, pause_tx)
}

fn is_lock_or_screensaver(activity: &ComputerActivity) -> bool {
    let path = activity
        .executable_path
        .as_deref()
        .unwrap_or(&activity.app_id);
    let stem = path
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

fn is_excluded(activity: &ComputerActivity, excluded_apps: &[String]) -> bool {
    let path = activity.executable_path.as_deref().unwrap_or_default();
    let exe_name = path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let exe_stem = exe_name.strip_suffix(".exe").unwrap_or(&exe_name);
    let display_name = activity.display_name.to_ascii_lowercase();
    let app_id = activity.app_id.to_ascii_lowercase();
    excluded_apps.iter().any(|excluded| {
        let value = excluded.trim().to_ascii_lowercase();
        let stem = value.strip_suffix(".exe").unwrap_or(&value);
        value == exe_name || stem == exe_stem || value == display_name || value == app_id
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclusion_is_independent_from_timetrace_identity_types() {
        let activity = ComputerActivity::new("editor", "Editor")
            .with_executable_path(r"C:\Apps\Editor.exe");
        assert!(is_excluded(&activity, &["editor".into()]));
        assert!(is_excluded(&activity, &["EDITOR.EXE".into()]));
        assert!(!is_excluded(&activity, &["browser".into()]));
    }
}
