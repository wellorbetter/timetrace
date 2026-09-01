//! Foreground application monitor — the core tracking loop.
//!
//! Windows supplements the timed poll with WinEventHook notifications for
//! near-instant foreground/title changes. Other desktop platforms use the same
//! portable poll loop without the Windows-specific hook.

#[cfg(all(target_os = "windows", not(test)))]
use std::sync::OnceLock;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, atomic::AtomicBool, atomic::Ordering};
use std::thread;
use std::time::{Duration, Instant};

use tracing::info;

#[cfg(all(target_os = "windows", not(test)))]
use windows::Win32::UI::Accessibility::HWINEVENTHOOK;
#[cfg(all(target_os = "windows", not(test)))]
use windows::Win32::UI::Accessibility::SetWinEventHook;
#[cfg(all(target_os = "windows", not(test)))]
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage, WINEVENT_OUTOFCONTEXT,
};
#[cfg(all(target_os = "windows", not(test)))]
use windows::Win32::UI::WindowsAndMessaging::{EVENT_OBJECT_NAMECHANGE, EVENT_SYSTEM_FOREGROUND};

use crate::contracts::events::{
    AppInfo, EventSink, EventSourceHandle, MonitorCommand, TrackedEvent,
};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;
use crate::engine::app_identity::normalize_executable_path;

#[cfg(all(target_os = "windows", not(test)))]
static FG_EVENT: OnceLock<Mutex<Option<mpsc::Sender<MonitorCommand>>>> = OnceLock::new();

#[cfg(all(target_os = "windows", not(test)))]
unsafe extern "system" fn win_event_proc(
    _hook: HWINEVENTHOOK,
    event: u32,
    _hwnd: windows::Win32::Foundation::HWND,
    id_object: i32,
    _id_child: i32,
    _event_thread: u32,
    _ms: u32,
) {
    if (event == EVENT_SYSTEM_FOREGROUND || (event == EVENT_OBJECT_NAMECHANGE && id_object == 0))
        && let Some(slot) = FG_EVENT.get()
    {
        let guard = match slot.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(tx) = guard.as_ref() {
            let _ = tx.send(MonitorCommand::ForegroundHint {
                timestamp: chrono::Utc::now(),
            });
        }
    }
}

/// Start foreground monitoring in the active tracking state.
///
/// This compatibility entry point preserves existing callers. New application
/// roots that persist a paused startup preference should call
/// [`run_monitor_loop_with_initial_pause`].
pub fn run_monitor_loop<W, I>(
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    excluded_apps: Vec<String>,
    sink: Box<dyn EventSink>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    run_monitor_loop_with_initial_pause(
        window_resolver,
        idle_detector,
        poll_interval,
        idle_threshold,
        excluded_apps,
        false,
        sink,
    )
}

/// Start foreground monitoring with an explicit persisted pause state.
///
/// Passing the initial state into thread construction removes the former race
/// where the first foreground observation could open a session before a
/// post-start `pause()` command arrived.
pub fn run_monitor_loop_with_initial_pause<W, I>(
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    excluded_apps: Vec<String>,
    initially_paused: bool,
    mut sink: Box<dyn EventSink>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    let (control_tx, control_rx) = mpsc::channel::<MonitorCommand>();
    let (hook_stop_tx, hook_stop_rx) = mpsc::channel::<()>();
    let requested_paused = Arc::new(AtomicBool::new(initially_paused));
    let transition_lock = Arc::new(Mutex::new(()));

    #[cfg(all(target_os = "windows", not(test)))]
    {
        let slot = FG_EVENT.get_or_init(|| Mutex::new(None));
        match slot.lock() {
            Ok(mut guard) => *guard = Some(control_tx.clone()),
            Err(poisoned) => *poisoned.into_inner() = Some(control_tx.clone()),
        }
        thread::spawn(move || unsafe {
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
        });
    }

    #[cfg(any(not(target_os = "windows"), test))]
    {
        // Keep EventSourceHandle's lifecycle uniform when no native hook
        // thread is needed (polling targets and deterministic unit tests).
        drop(hook_stop_rx);
    }

    let monitor_requested_paused = Arc::clone(&requested_paused);
    let monitor_transition_lock = Arc::clone(&transition_lock);
    thread::spawn(move || {
        let interval = poll_interval.max(Duration::from_millis(1));
        let mut state = MonitorState::new(initially_paused);
        let mut last_poll = Instant::now();
        let mut last_observed_at = chrono::Utc::now();
        let mut last_title_check = Instant::now();
        let mut poll_immediately = !initially_paused;

        if initially_paused {
            sink.accept(TrackedEvent::TrackingPaused {
                timestamp: last_observed_at,
            });
        }

        loop {
            let mut trigger_at = None;
            let mut paused_timeout = false;
            let first_command = if poll_immediately {
                poll_immediately = false;
                trigger_at = Some(chrono::Utc::now());
                None
            } else {
                match control_rx.recv_timeout(interval) {
                    Ok(command) => Some(command),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        trigger_at = Some(chrono::Utc::now());
                        paused_timeout = true;
                        None
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            };

            // Drain everything already queued before sampling the OS. In
            // particular, a timestamped pause queued behind a foreground hint
            // wins before that hint can open or switch a session.
            let should_stop = {
                let _transition = match monitor_transition_lock.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
                apply_monitor_commands(
                    first_command.into_iter().chain(control_rx.try_iter()),
                    &mut state,
                    sink.as_mut(),
                    &mut trigger_at,
                    &mut last_poll,
                    &mut last_observed_at,
                    last_title_check,
                )
            };

            if should_stop {
                info!("Monitor stopped");
                break;
            }

            if state.is_paused() {
                if paused_timeout && trigger_at.is_some() {
                    last_poll = Instant::now();
                }
                continue;
            }

            let Some(mut observation_at) = trigger_at else {
                continue;
            };
            // pause_at() flips this gate before queueing its command. A pause
            // racing immediately after the drain therefore suppresses the OS
            // sample until the exact timestamped boundary is consumed.
            if monitor_requested_paused.load(Ordering::SeqCst) {
                continue;
            }
            observation_at = observation_at.max(last_observed_at);
            let observation_instant = Instant::now();
            let observation = collect_foreground_observation(
                &window_resolver,
                &idle_detector,
                idle_threshold,
                &excluded_apps,
            );

            // Collection may cross a user pause. Applying the observation and
            // requesting a pause share this transition mutex, so either the
            // complete observation wins first or the pause gate does. A pause
            // that wins discards the collected foreground identity entirely.
            let _transition = match monitor_transition_lock.lock() {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
            let pause_requested = monitor_requested_paused.load(Ordering::SeqCst);
            close_sleep_gap_if_needed(
                &mut state,
                &mut sink,
                observation_instant,
                last_poll,
                last_observed_at,
                interval,
            );
            if pause_requested {
                continue;
            }
            apply_foreground_observation(observation, &mut state, &mut sink, observation_at);
            last_poll = observation_instant;
            last_observed_at = observation_at;
            last_title_check = observation_instant;
        }
    });

    EventSourceHandle::new(control_tx, hook_stop_tx, requested_paused, transition_lock)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ObservedState {
    Active,
    Idle,
    Excluded,
    Paused,
    Unavailable,
}

struct MonitorState {
    observed: ObservedState,
    current_app: Option<AppInfo>,
}

impl MonitorState {
    fn new(initially_paused: bool) -> Self {
        Self {
            observed: if initially_paused {
                ObservedState::Paused
            } else {
                ObservedState::Unavailable
            },
            current_app: None,
        }
    }

    fn is_paused(&self) -> bool {
        self.observed == ObservedState::Paused
    }
}

fn apply_monitor_commands(
    commands: impl IntoIterator<Item = MonitorCommand>,
    state: &mut MonitorState,
    sink: &mut dyn EventSink,
    trigger_at: &mut Option<chrono::DateTime<chrono::Utc>>,
    last_poll: &mut Instant,
    last_observed_at: &mut chrono::DateTime<chrono::Utc>,
    last_title_check: Instant,
) -> bool {
    for command in commands {
        match command {
            MonitorCommand::Stop => return true,
            MonitorCommand::SetPaused { paused, timestamp } => {
                if paused == state.is_paused() {
                    continue;
                }
                // Wall clocks can move backwards and deterministic callers can
                // supply an older boundary. Preserve the requested timestamp
                // whenever it is valid without ever regressing the event stream.
                let effective_at = timestamp.max(*last_observed_at);
                *trigger_at = None;
                *last_poll = Instant::now();
                *last_observed_at = effective_at;
                state.current_app = None;
                if paused {
                    state.observed = ObservedState::Paused;
                    sink.accept(TrackedEvent::TrackingPaused {
                        timestamp: effective_at,
                    });
                } else {
                    state.observed = ObservedState::Unavailable;
                    sink.accept(TrackedEvent::TrackingResumed {
                        timestamp: effective_at,
                    });
                    // A resumed monitor samples the then-current foreground
                    // instead of restoring the identity held before pausing.
                    *trigger_at = Some(chrono::Utc::now().max(effective_at));
                }
            }
            MonitorCommand::ForegroundHint { timestamp } => {
                if state.is_paused()
                    || Instant::now().duration_since(last_title_check) < Duration::from_millis(500)
                {
                    continue;
                }
                *trigger_at = Some(match *trigger_at {
                    Some(current) => current.max(timestamp),
                    None => timestamp,
                });
            }
        }
    }
    false
}

fn close_sleep_gap_if_needed(
    state: &mut MonitorState,
    sink: &mut Box<dyn EventSink>,
    now: Instant,
    last_poll: Instant,
    last_observed_at: chrono::DateTime<chrono::Utc>,
    poll_interval: Duration,
) {
    let gap = now.duration_since(last_poll);
    if gap <= poll_interval * 5 {
        return;
    }
    info!("Monitor: sleep gap {gap:?} detected - closing session at gap start");
    sink.accept(TrackedEvent::GapDetected {
        timestamp: last_observed_at,
    });
    state.current_app = None;
    state.observed = ObservedState::Unavailable;
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CollectedForegroundObservation {
    Active {
        app: AppInfo,
        idle_duration: Duration,
    },
    Idle {
        grace: Duration,
    },
    Excluded,
    Unavailable,
}

fn collect_foreground_observation<W, I>(
    window_resolver: &W,
    idle_detector: &I,
    idle_threshold: Duration,
    excluded_apps: &[String],
) -> CollectedForegroundObservation
where
    W: WindowResolver,
    I: IdleDetector,
{
    if idle_detector.is_idle(idle_threshold) {
        return CollectedForegroundObservation::Idle {
            grace: idle_threshold,
        };
    }

    let Some(raw_foreground) = window_resolver.get_foreground_app() else {
        return CollectedForegroundObservation::Unavailable;
    };
    if is_lock_or_screensaver(&raw_foreground) {
        return CollectedForegroundObservation::Idle {
            grace: Duration::ZERO,
        };
    }

    let Some(foreground) = canonicalize_app_info(raw_foreground) else {
        return CollectedForegroundObservation::Unavailable;
    };
    if is_excluded(&foreground, excluded_apps) {
        CollectedForegroundObservation::Excluded
    } else {
        CollectedForegroundObservation::Active {
            app: foreground,
            idle_duration: idle_detector.idle_duration(),
        }
    }
}

fn canonicalize_app_info(mut app: AppInfo) -> Option<AppInfo> {
    app.exe_path = normalize_executable_path(&app.exe_path).ok()?;
    Some(app)
}

fn apply_foreground_observation(
    observation: CollectedForegroundObservation,
    state: &mut MonitorState,
    sink: &mut Box<dyn EventSink>,
    timestamp: chrono::DateTime<chrono::Utc>,
) {
    let foreground = match observation {
        CollectedForegroundObservation::Idle { grace } => {
            if state.observed != ObservedState::Idle {
                info!("Monitor: idle started");
                sink.accept(TrackedEvent::IdleStarted { timestamp, grace });
            }
            state.current_app = None;
            state.observed = ObservedState::Idle;
            return;
        }
        CollectedForegroundObservation::Excluded => {
            if state.observed != ObservedState::Excluded {
                sink.accept(TrackedEvent::ForegroundExcluded { timestamp });
            }
            state.current_app = None;
            state.observed = ObservedState::Excluded;
            return;
        }
        CollectedForegroundObservation::Unavailable => {
            if state.observed != ObservedState::Unavailable {
                sink.accept(TrackedEvent::ForegroundUnavailable { timestamp });
            }
            state.current_app = None;
            state.observed = ObservedState::Unavailable;
            return;
        }
        CollectedForegroundObservation::Active { app, idle_duration } => {
            if state.observed == ObservedState::Idle {
                sink.accept(TrackedEvent::IdleEnded {
                    idle_duration,
                    current_app: app.clone(),
                    timestamp,
                });
                state.current_app = Some(app);
                state.observed = ObservedState::Active;
                return;
            }
            app
        }
    };

    let same = state.current_app.as_ref().is_some_and(|current| {
        current.exe_path == foreground.exe_path && current.window_title == foreground.window_title
    });
    if !same {
        let previous = state.current_app.take();
        sink.accept(TrackedEvent::AppSwitched {
            previous,
            current: foreground.clone(),
            timestamp,
        });
        state.current_app = Some(foreground);
    }
    state.observed = ObservedState::Active;
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
    use super::*;
    use crate::contracts::storage::DataStore;
    use crate::engine::{ActivitySnapshotProjector, FanoutEventSink, SessionAggregator};
    use crate::storage::sqlite::MemoryStore;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex as StdMutex};

    struct FakeWindowResolver {
        current: Arc<StdMutex<Option<AppInfo>>>,
        calls: Arc<AtomicUsize>,
    }

    impl WindowResolver for FakeWindowResolver {
        fn get_foreground_app(&self) -> Option<AppInfo> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.current.lock().unwrap().clone()
        }

        fn get_window_title(&self, _hwnd: isize) -> Option<String> {
            None
        }
    }

    struct BlockingWindowResolver {
        first: AppInfo,
        later: Arc<StdMutex<Option<AppInfo>>>,
        calls: Arc<AtomicUsize>,
        second_started: mpsc::Sender<()>,
        release_second: StdMutex<mpsc::Receiver<()>>,
    }

    impl WindowResolver for BlockingWindowResolver {
        fn get_foreground_app(&self) -> Option<AppInfo> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            if call == 0 {
                return Some(self.first.clone());
            }
            let _ = self.second_started.send(());
            let released = match self.release_second.lock() {
                Ok(receiver) => receiver.recv_timeout(Duration::from_secs(2)).is_ok(),
                Err(poisoned) => poisoned
                    .into_inner()
                    .recv_timeout(Duration::from_secs(2))
                    .is_ok(),
            };
            if !released {
                return None;
            }
            match self.later.lock() {
                Ok(app) => app.clone(),
                Err(poisoned) => poisoned.into_inner().clone(),
            }
        }

        fn get_window_title(&self, _hwnd: isize) -> Option<String> {
            None
        }
    }

    struct FakeIdleDetector {
        idle: Arc<AtomicBool>,
        duration: Duration,
    }

    impl IdleDetector for FakeIdleDetector {
        fn is_idle(&self, _threshold: Duration) -> bool {
            self.idle.load(Ordering::SeqCst)
        }

        fn idle_duration(&self) -> Duration {
            self.duration
        }
    }

    struct RecordingSink(Arc<StdMutex<Vec<TrackedEvent>>>);

    impl EventSink for RecordingSink {
        fn accept(&mut self, event: TrackedEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    struct ChannelSink(mpsc::Sender<TrackedEvent>);

    impl EventSink for ChannelSink {
        fn accept(&mut self, event: TrackedEvent) {
            let _ = self.0.send(event);
        }
    }

    fn app(path: &str, name: &str) -> AppInfo {
        AppInfo::new(path.to_string(), name.to_string())
    }

    fn executable_path(name: &str) -> String {
        #[cfg(target_os = "windows")]
        {
            format!(r"C:\Apps\{name}.exe")
        }
        #[cfg(not(target_os = "windows"))]
        {
            format!("/Applications/{name}.app/Contents/MacOS/{name}")
        }
    }

    fn collect_and_apply<W, I>(
        window_resolver: &W,
        idle_detector: &I,
        idle_threshold: Duration,
        excluded_apps: &[String],
        state: &mut MonitorState,
        sink: &mut Box<dyn EventSink>,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) where
        W: WindowResolver,
        I: IdleDetector,
    {
        let observation = collect_foreground_observation(
            window_resolver,
            idle_detector,
            idle_threshold,
            excluded_apps,
        );
        apply_foreground_observation(observation, state, sink, timestamp);
    }

    fn event_timestamp(event: &TrackedEvent) -> chrono::DateTime<chrono::Utc> {
        match event {
            TrackedEvent::AppSwitched { timestamp, .. }
            | TrackedEvent::IdleStarted { timestamp, .. }
            | TrackedEvent::IdleEnded { timestamp, .. }
            | TrackedEvent::TrackingPaused { timestamp }
            | TrackedEvent::TrackingResumed { timestamp }
            | TrackedEvent::GapDetected { timestamp }
            | TrackedEvent::ForegroundExcluded { timestamp }
            | TrackedEvent::ForegroundUnavailable { timestamp } => *timestamp,
        }
    }

    #[test]
    fn excludes_by_exe_name_with_or_without_extension() {
        let app = AppInfo::new(r"C:\Apps\Example.exe".into(), "Example".into());
        assert!(is_excluded(&app, &["example".into()]));
        assert!(is_excluded(&app, &["EXAMPLE.EXE".into()]));
        assert!(!is_excluded(&app, &["other.exe".into()]));
    }

    #[test]
    fn observation_emits_explicit_active_excluded_unavailable_and_idle_boundaries() {
        let current = Arc::new(StdMutex::new(Some(app(
            &executable_path("Editor"),
            "Editor",
        ))));
        let calls = Arc::new(AtomicUsize::new(0));
        let resolver = FakeWindowResolver {
            current: Arc::clone(&current),
            calls,
        };
        let idle = Arc::new(AtomicBool::new(false));
        let detector = FakeIdleDetector {
            idle: Arc::clone(&idle),
            duration: Duration::from_secs(90),
        };
        let events = Arc::new(StdMutex::new(Vec::new()));
        let mut sink: Box<dyn EventSink> = Box::new(RecordingSink(Arc::clone(&events)));
        let mut state = MonitorState::new(false);

        collect_and_apply(
            &resolver,
            &detector,
            Duration::from_secs(60),
            &["Editor".to_string()],
            &mut state,
            &mut sink,
            chrono::DateTime::from_timestamp(1, 0).unwrap(),
        );
        assert_eq!(state.observed, ObservedState::Excluded);

        *current.lock().unwrap() = None;
        collect_and_apply(
            &resolver,
            &detector,
            Duration::from_secs(60),
            &[],
            &mut state,
            &mut sink,
            chrono::DateTime::from_timestamp(2, 0).unwrap(),
        );
        assert_eq!(state.observed, ObservedState::Unavailable);

        idle.store(true, Ordering::SeqCst);
        collect_and_apply(
            &resolver,
            &detector,
            Duration::from_secs(60),
            &[],
            &mut state,
            &mut sink,
            chrono::DateTime::from_timestamp(3, 0).unwrap(),
        );
        assert_eq!(state.observed, ObservedState::Idle);

        idle.store(false, Ordering::SeqCst);
        *current.lock().unwrap() = Some(app(&executable_path("Browser"), "Browser"));
        collect_and_apply(
            &resolver,
            &detector,
            Duration::from_secs(60),
            &[],
            &mut state,
            &mut sink,
            chrono::DateTime::from_timestamp(4, 0).unwrap(),
        );
        assert_eq!(state.observed, ObservedState::Active);

        let captured = events.lock().unwrap();
        assert!(matches!(
            captured[0],
            TrackedEvent::ForegroundExcluded { .. }
        ));
        assert!(matches!(
            captured[1],
            TrackedEvent::ForegroundUnavailable { .. }
        ));
        assert!(matches!(captured[2], TrackedEvent::IdleStarted { .. }));
        assert!(matches!(captured[3], TrackedEvent::IdleEnded { .. }));
    }

    #[test]
    fn invalid_foreground_identity_closes_session_and_snapshot_consistently() {
        let valid = canonicalize_app_info(app(&executable_path("Editor"), "Editor")).unwrap();
        let started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        let unavailable_at = chrono::Utc::now();
        let db = Arc::new(MemoryStore::new());
        let aggregator_db: Arc<dyn DataStore> = db.clone();
        let projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();
        let mut sink: Box<dyn EventSink> = Box::new(FanoutEventSink::new(vec![
            Box::new(SessionAggregator::new(aggregator_db)),
            Box::new(projector),
        ]));
        sink.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: valid.clone(),
            timestamp: started_at,
        });
        let mut state = MonitorState {
            observed: ObservedState::Active,
            current_app: Some(valid),
        };
        let resolver = FakeWindowResolver {
            current: Arc::new(StdMutex::new(Some(app("relative.exe", "Private title")))),
            calls: Arc::new(AtomicUsize::new(0)),
        };
        let detector = FakeIdleDetector {
            idle: Arc::new(AtomicBool::new(false)),
            duration: Duration::ZERO,
        };

        let observation =
            collect_foreground_observation(&resolver, &detector, Duration::from_secs(60), &[]);
        assert_eq!(observation, CollectedForegroundObservation::Unavailable);
        apply_foreground_observation(observation, &mut state, &mut sink, unavailable_at);

        assert!(db.get_active_session().is_none());
        let sessions = db.get_sessions_by_date(chrono::Local::now().date_naive());
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].ended_at, Some(unavailable_at));
        let snapshot = reader.snapshot();
        assert_eq!(snapshot.state, crate::engine::ActivityState::Unavailable);
        assert!(snapshot.app.is_none());
        assert_eq!(snapshot.observed_at, unavailable_at);
    }

    #[test]
    fn sleep_gap_closes_at_last_valid_observation() {
        let events = Arc::new(StdMutex::new(Vec::new()));
        let mut sink: Box<dyn EventSink> = Box::new(RecordingSink(Arc::clone(&events)));
        let mut state = MonitorState {
            observed: ObservedState::Active,
            current_app: Some(app("C:/editor.exe", "Editor")),
        };
        let now = Instant::now();
        let boundary = chrono::DateTime::from_timestamp(100, 0).unwrap();
        close_sleep_gap_if_needed(
            &mut state,
            &mut sink,
            now,
            now - Duration::from_secs(10),
            boundary,
            Duration::from_secs(1),
        );

        assert_eq!(state.observed, ObservedState::Unavailable);
        assert!(state.current_app.is_none());
        assert_eq!(
            events.lock().unwrap().as_slice(),
            &[TrackedEvent::GapDetected {
                timestamp: boundary
            }]
        );
    }

    #[test]
    fn initial_pause_precedes_observation_and_commands_keep_exact_timestamps() {
        let current = Arc::new(StdMutex::new(Some(app(
            &executable_path("Editor"),
            "Editor",
        ))));
        let calls = Arc::new(AtomicUsize::new(0));
        let resolver = FakeWindowResolver {
            current,
            calls: Arc::clone(&calls),
        };
        let detector = FakeIdleDetector {
            idle: Arc::new(AtomicBool::new(false)),
            duration: Duration::ZERO,
        };
        let (tx, rx) = mpsc::channel();
        let handle = run_monitor_loop_with_initial_pause(
            resolver,
            detector,
            Duration::from_secs(1),
            Duration::from_secs(60),
            vec![],
            true,
            Box::new(ChannelSink(tx)),
        );

        let initially_paused_at = match rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            TrackedEvent::TrackingPaused { timestamp } => timestamp,
            event => panic!("expected initial pause boundary, got {event:?}"),
        };
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let resumed_at = initially_paused_at + chrono::Duration::seconds(1);
        handle.resume_at(resumed_at);
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            TrackedEvent::TrackingResumed {
                timestamp: resumed_at
            }
        );
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            TrackedEvent::AppSwitched { .. }
        ));

        let paused_at = resumed_at + chrono::Duration::seconds(1);
        handle.pause_at(paused_at);
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            TrackedEvent::TrackingPaused {
                timestamp: paused_at
            }
        );
        handle.stop();
    }

    #[test]
    fn pause_wins_over_an_in_flight_foreground_observation() {
        let first = app(&executable_path("EditorA"), "Editor A");
        let later = Arc::new(StdMutex::new(Some(app(
            &executable_path("EditorB"),
            "Editor B",
        ))));
        let calls = Arc::new(AtomicUsize::new(0));
        let (second_started_tx, second_started_rx) = mpsc::channel();
        let (release_second_tx, release_second_rx) = mpsc::channel();
        let resolver = BlockingWindowResolver {
            first,
            later,
            calls: Arc::clone(&calls),
            second_started: second_started_tx,
            release_second: StdMutex::new(release_second_rx),
        };
        let detector = FakeIdleDetector {
            idle: Arc::new(AtomicBool::new(false)),
            duration: Duration::ZERO,
        };
        let db = Arc::new(MemoryStore::new());
        let aggregator_db: Arc<dyn DataStore> = db.clone();
        let projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();
        let recorded = Arc::new(StdMutex::new(Vec::new()));
        let sink = FanoutEventSink::new(vec![
            Box::new(SessionAggregator::new(aggregator_db)),
            Box::new(projector),
            Box::new(RecordingSink(Arc::clone(&recorded))),
        ]);
        let handle = run_monitor_loop(
            resolver,
            detector,
            Duration::from_millis(50),
            Duration::from_secs(60),
            vec![],
            Box::new(sink),
        );

        let active_deadline = Instant::now() + Duration::from_secs(1);
        while reader.snapshot().state != crate::engine::ActivityState::Active {
            assert!(
                Instant::now() < active_deadline,
                "first observation did not open A"
            );
            thread::sleep(Duration::from_millis(5));
        }
        second_started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("second observation should block in the resolver");

        let paused_at = chrono::Utc::now();
        handle.pause_at(paused_at);
        release_second_tx
            .send(())
            .expect("release the in-flight observation");

        let pause_deadline = Instant::now() + Duration::from_secs(1);
        while reader.snapshot().state != crate::engine::ActivityState::Paused {
            assert!(
                Instant::now() < pause_deadline,
                "pause boundary was not projected"
            );
            thread::sleep(Duration::from_millis(5));
        }

        let sessions = db.get_sessions_by_date(chrono::Local::now().date_naive());
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].app_name, "Editor A");
        assert_eq!(sessions[0].ended_at, Some(paused_at));
        assert!(
            sessions[0]
                .ended_at
                .is_some_and(|end| end >= sessions[0].started_at)
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(recorded.lock().unwrap().iter().all(|event| {
            !matches!(event, TrackedEvent::AppSwitched { current, .. } if current.display_name == "Editor B")
        }));
        handle.stop();
    }

    #[test]
    fn queued_pause_wins_over_hint_and_keeps_snapshot_and_session_monotonic() {
        #[cfg(target_os = "windows")]
        let path = r"C:\Apps\Editor.exe";
        #[cfg(not(target_os = "windows"))]
        let path = "/Applications/Editor.app/Contents/MacOS/Editor";
        let application = app(path, "Editor");
        let started_at = chrono::Utc::now();
        let hinted_at = started_at + chrono::Duration::milliseconds(500);
        let paused_at = started_at + chrono::Duration::seconds(1);
        let db = Arc::new(MemoryStore::new());
        let aggregator_db: Arc<dyn DataStore> = db.clone();
        let projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();
        let recorded = Arc::new(StdMutex::new(Vec::new()));
        let mut sink: Box<dyn EventSink> = Box::new(FanoutEventSink::new(vec![
            Box::new(SessionAggregator::new(aggregator_db)),
            Box::new(projector),
            Box::new(RecordingSink(Arc::clone(&recorded))),
        ]));
        sink.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: application.clone(),
            timestamp: started_at,
        });
        let mut state = MonitorState {
            observed: ObservedState::Active,
            current_app: Some(application),
        };
        let mut trigger_at = None;
        let mut last_poll = Instant::now();
        let mut last_observed_at = started_at;

        let stopped = apply_monitor_commands(
            [
                MonitorCommand::ForegroundHint {
                    timestamp: hinted_at,
                },
                MonitorCommand::SetPaused {
                    paused: true,
                    timestamp: paused_at,
                },
            ],
            &mut state,
            sink.as_mut(),
            &mut trigger_at,
            &mut last_poll,
            &mut last_observed_at,
            Instant::now() - Duration::from_secs(1),
        );

        assert!(!stopped);
        assert!(trigger_at.is_none(), "pause must discard the queued hint");
        assert_eq!(
            reader.snapshot().state,
            crate::engine::ActivityState::Paused
        );
        assert_eq!(reader.snapshot().observed_at, paused_at);
        let sessions = db.get_sessions_by_date(chrono::Local::now().date_naive());
        assert_eq!(sessions.len(), 1);
        let session = &sessions[0];
        assert_eq!(session.ended_at, Some(paused_at));
        assert!(
            session
                .ended_at
                .is_some_and(|ended| ended >= session.started_at)
        );

        let timestamps: Vec<_> = recorded
            .lock()
            .unwrap()
            .iter()
            .map(|event| match event {
                TrackedEvent::AppSwitched { timestamp, .. }
                | TrackedEvent::IdleStarted { timestamp, .. }
                | TrackedEvent::IdleEnded { timestamp, .. }
                | TrackedEvent::TrackingPaused { timestamp }
                | TrackedEvent::TrackingResumed { timestamp }
                | TrackedEvent::GapDetected { timestamp }
                | TrackedEvent::ForegroundExcluded { timestamp }
                | TrackedEvent::ForegroundUnavailable { timestamp } => *timestamp,
            })
            .collect();
        assert!(timestamps.windows(2).all(|pair| pair[0] <= pair[1]));
    }

    #[test]
    fn stale_pause_and_resume_timestamps_are_clamped_across_every_sink() {
        let application = canonicalize_app_info(app(&executable_path("Editor"), "Editor")).unwrap();
        let started_at = chrono::Utc::now();
        let db = Arc::new(MemoryStore::new());
        let aggregator_db: Arc<dyn DataStore> = db.clone();
        let projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();
        let recorded = Arc::new(StdMutex::new(Vec::new()));
        let mut sink: Box<dyn EventSink> = Box::new(FanoutEventSink::new(vec![
            Box::new(SessionAggregator::new(aggregator_db)),
            Box::new(projector),
            Box::new(RecordingSink(Arc::clone(&recorded))),
        ]));
        sink.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: application.clone(),
            timestamp: started_at,
        });
        let mut state = MonitorState {
            observed: ObservedState::Active,
            current_app: Some(application),
        };
        let mut trigger_at = None;
        let mut last_poll = Instant::now();
        let mut last_observed_at = started_at;

        apply_monitor_commands(
            [MonitorCommand::SetPaused {
                paused: true,
                timestamp: started_at - chrono::Duration::minutes(1),
            }],
            &mut state,
            sink.as_mut(),
            &mut trigger_at,
            &mut last_poll,
            &mut last_observed_at,
            Instant::now(),
        );
        assert_eq!(last_observed_at, started_at);
        assert_eq!(reader.snapshot().observed_at, started_at);
        let session = db
            .get_sessions_by_date(chrono::Local::now().date_naive())
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(session.ended_at, Some(started_at));
        assert!(
            session
                .ended_at
                .is_some_and(|end| end >= session.started_at)
        );

        apply_monitor_commands(
            [MonitorCommand::SetPaused {
                paused: false,
                timestamp: started_at - chrono::Duration::minutes(2),
            }],
            &mut state,
            sink.as_mut(),
            &mut trigger_at,
            &mut last_poll,
            &mut last_observed_at,
            Instant::now(),
        );
        assert_eq!(last_observed_at, started_at);
        assert_eq!(reader.snapshot().observed_at, started_at);
        assert!(trigger_at.is_some_and(|trigger| trigger >= started_at));

        let timestamps: Vec<_> = recorded
            .lock()
            .unwrap()
            .iter()
            .map(event_timestamp)
            .collect();
        assert_eq!(timestamps, vec![started_at, started_at, started_at]);
    }
}
