//! Foreground window monitor — the core tracking loop.
//!
//! Event-driven (like RescueTime): a WinEventHook on
//! EVENT_SYSTEM_FOREGROUND pushes foreground switches instantly, so
//! switching apps is captured in milliseconds instead of waiting for the
//! poll tick. The timed poll remains as a fallback (covers fullscreen
//! games / UAC where the hook may not fire).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use tracing::{info, warn};

use windows::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EVENT_OBJECT_NAMECHANGE, EVENT_SYSTEM_FOREGROUND, MSG, PM_REMOVE,
    PeekMessageW, TranslateMessage, WINEVENT_OUTOFCONTEXT,
};

use crate::contracts::accounting::{
    AccountingClock, AccountingInterval, AccountingState, AccountingStore, AttributionIdentity,
    CanonicalBatch, CheckpointAck, CheckpointReason, ProducerCheckpointState,
    SystemAccountingClock, UtcInterval,
};
use crate::contracts::events::{
    AppInfo, EventSink, EventSourceHandle, MonitorCommand, TrackedEvent,
};
use crate::contracts::idle::IdleDetector;
use crate::contracts::window::WindowResolver;
use crate::engine::aggregator::{CheckpointStore, SessionAggregator};

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
        || (event == EVENT_OBJECT_NAMECHANGE && id_object == 0/* OBJID_WINDOW */)
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
    sink: Box<dyn EventSink>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    run_monitor_loop_with_clock(
        window_resolver,
        idle_detector,
        poll_interval,
        idle_threshold,
        excluded_apps,
        sink,
        Arc::new(SystemAccountingClock),
    )
}

enum MonitorWake {
    Command(MonitorCommand),
    Hook,
    Poll,
    Disconnected,
}

const SIGNAL_CHECK_INTERVAL: Duration = Duration::from_millis(50);

fn use_compatibility_sleep(remaining: Duration) -> bool {
    remaining <= SIGNAL_CHECK_INTERVAL
}

/// Signal checks are not observations. Long waits are control-wakeable; short
/// waits preserve the legacy sleep primitive (including a long wait's tail).
/// Commands in that tail are checked after at most a 50ms requested sleep,
/// not immediately. OS scheduling can add latency to either wait primitive.
/// The bounded hook drain cannot starve control or move the poll deadline.
fn wait_monitor_signal(
    control: &mpsc::Receiver<MonitorCommand>,
    foreground: &mpsc::Receiver<()>,
    poll_deadline: Instant,
    last_title_check: Instant,
    paused: bool,
    pending_hook: &mut bool,
    foreground_closed: &mut bool,
) -> MonitorWake {
    loop {
        match control.try_recv() {
            Ok(command) => return MonitorWake::Command(command),
            Err(mpsc::TryRecvError::Disconnected) => return MonitorWake::Disconnected,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if !*foreground_closed {
            for _ in 0..32 {
                match foreground.try_recv() {
                    Ok(()) => {
                        if !paused {
                            *pending_hook = true;
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        *foreground_closed = true;
                        break;
                    }
                }
            }
        }
        if paused {
            *pending_hook = false;
        }
        let now = Instant::now();
        let hook_deadline = last_title_check + Duration::from_millis(500);
        if *pending_hook && now >= hook_deadline {
            *pending_hook = false;
            return MonitorWake::Hook;
        }
        if now >= poll_deadline {
            return MonitorWake::Poll;
        }
        let mut remaining = poll_deadline - now;
        if *pending_hook {
            remaining = remaining.min(hook_deadline.saturating_duration_since(now));
        }
        let timeout = SIGNAL_CHECK_INTERVAL.min(remaining);
        if use_compatibility_sleep(remaining) {
            // The original short poll used thread::sleep. recv_timeout is a
            // different Windows wait primitive. The new wait path regressed
            // the unchanged 1ms lifecycle fixture; exact OS timing is unknown.
            // Keep the old short-wait primitive without
            // changing the accounting gap threshold. A short tail is bounded,
            // while a long poll still receives control immediately below.
            thread::sleep(timeout);
            continue;
        }
        match control.recv_timeout(timeout) {
            Ok(command) => return MonitorWake::Command(command),
            Err(mpsc::RecvTimeoutError::Disconnected) => return MonitorWake::Disconnected,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

fn run_monitor_loop_with_clock<W, I>(
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    excluded_apps: Vec<String>,
    mut sink: Box<dyn EventSink>,
    observation_clock: Arc<dyn AccountingClock>,
) -> EventSourceHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    let (control_tx, control_rx) = mpsc::channel::<MonitorCommand>();
    let (hook_stop_tx, hook_stop_rx) = mpsc::channel::<()>();
    let (fg_tx, fg_rx) = mpsc::channel::<()>();

    // Event-hook thread: SetWinEventHook needs a message loop on the
    // registering thread. Foreground switches are pushed to the monitor.
    let hook_join = {
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
        })
    };

    let monitor_join = thread::spawn(move || {
        let mut current_app: Option<AppInfo> = None;
        let mut is_paused = false;
        let mut is_idle = false;
        let mut last_successful_observation_at: Option<chrono::DateTime<chrono::Utc>> = None;
        let mut last_poll = Instant::now();
        let mut last_title_check = Instant::now();
        let mut pending_command = None;
        let mut wake_hook = false;
        let mut pending_hook = false;
        let mut foreground_closed = false;

        loop {
            let command = if let Some(command) = pending_command.take() {
                Some(command)
            } else {
                match control_rx.try_recv() {
                    Ok(command) => Some(command),
                    Err(mpsc::TryRecvError::Empty) => None,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        if (current_app.is_some() || is_idle) && last_successful_observation_at.is_some() {
                            sink.accept(TrackedEvent::GapDetected { timestamp: last_successful_observation_at.unwrap() });
                        }
                        break;
                    }
                }
            };
            if let Some(command) = command {
                match command {
                    MonitorCommand::Stop { ack } => {
                        if (current_app.is_some() || is_idle)
                            && last_successful_observation_at.is_some()
                        {
                            sink.accept(TrackedEvent::GapDetected {
                                timestamp: last_successful_observation_at.unwrap(),
                            });
                        }
                        current_app = None;
                        is_idle = false;
                        let _ = ack.send(true);
                        info!("Monitor stopped");
                        break;
                    }
                    MonitorCommand::SetPaused { paused, ack } => {
                        if paused != is_paused {
                            if paused
                                && (current_app.is_some() || is_idle)
                                && last_successful_observation_at.is_some()
                            {
                                sink.accept(TrackedEvent::GapDetected {
                                    timestamp: last_successful_observation_at.unwrap(),
                                });
                            }
                            current_app = None;
                            is_idle = false;
                            is_paused = paused;
                        }
                        let _ = ack.send(true);
                    }
                }
            }

            let now = Instant::now();
            // Sleep/resume (or system freeze): close the dangling DB session
            // at the last known active time so the gap is never attributed
            // to the pre-gap app.
            let gap = now - last_poll;
            last_poll = now;
            if gap > poll_interval * 5 {
                info!("Monitor: sleep gap {gap:?} detected - closing session at gap start");
                let gap_start = observation_clock.now_utc()
                    - chrono::Duration::from_std(gap).unwrap_or_default();
                sink.accept(TrackedEvent::GapDetected {
                    timestamp: gap_start,
                });
                current_app = None;
                is_idle = false;
            }

            // A WinEventHook fired -> foreground/title changed -> check now.
            // Title-change events can be chatty, so cap rechecks at ~2/s.
            let hook_fired = wake_hook;
            wake_hook = false;
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
                    let timestamp = observation_clock.now_utc();
                    sink.accept(TrackedEvent::IdleStarted {
                        timestamp,
                        grace: idle_threshold,
                    });
                    current_app = None;
                    sink.observation_checkpoint(AppInfo::idle(), timestamp);
                    last_successful_observation_at = Some(timestamp);
                } else if now_idle_input {
                    let timestamp = observation_clock.now_utc();
                    sink.observation_checkpoint(AppInfo::idle(), timestamp);
                    last_successful_observation_at = Some(timestamp);
                } else if !now_idle_input {
                    let raw_foreground = window_resolver.get_foreground_app();
                    let excluded = raw_foreground
                        .as_ref()
                        .is_some_and(|app| is_excluded(app, &excluded_apps));
                    if excluded && current_app.take().is_some() {
                        sink.accept(TrackedEvent::GapDetected {
                            timestamp: observation_clock.now_utc(),
                        });
                    }
                    let foreground = raw_foreground.filter(|app| !is_excluded(app, &excluded_apps));
                    let lock = foreground.as_ref().map_or(false, is_lock_or_screensaver);

                    if lock && !is_idle {
                        // Lock screen / screensaver: away instantly, no grace.
                        is_idle = true;
                        info!("Monitor: idle started (lock/screensaver)");
                        let timestamp = observation_clock.now_utc();
                        sink.accept(TrackedEvent::IdleStarted {
                            timestamp,
                            grace: Duration::ZERO,
                        });
                        current_app = None;
                        sink.observation_checkpoint(AppInfo::idle(), timestamp);
                        last_successful_observation_at = Some(timestamp);
                    } else if !lock && is_idle {
                        is_idle = false;
                        let ts = observation_clock.now_utc();
                        let dur = idle_detector.idle_duration();
                        if let Some(cur) = foreground {
                            sink.accept(TrackedEvent::IdleEnded {
                                idle_duration: dur,
                                current_app: cur.clone(),
                                timestamp: ts,
                            });
                            sink.observation_checkpoint(cur.clone(), ts);
                            last_successful_observation_at = Some(ts);
                            current_app = Some(cur);
                        } else {
                            sink.accept(TrackedEvent::GapDetected { timestamp: ts });
                            current_app = None;
                        }
                    } else if !is_idle {
                        if let Some(fg) = foreground {
                            // Track per-window-title: "Edge - Bilibili" vs "Edge - GitHub".
                            let same = current_app.as_ref().map_or(false, |c| {
                                c.exe_path == fg.exe_path && c.window_title == fg.window_title
                            });
                            let timestamp = observation_clock.now_utc();
                            if !same {
                                let prev = current_app.take();
                                sink.accept(TrackedEvent::AppSwitched {
                                    previous: prev,
                                    current: fg.clone(),
                                    timestamp,
                                });
                                current_app = Some(fg.clone());
                            }
                            sink.observation_checkpoint(fg, timestamp);
                            last_successful_observation_at = Some(timestamp);
                        } else if current_app.is_some() {
                            if let Some(timestamp) = last_successful_observation_at {
                                sink.accept(TrackedEvent::GapDetected { timestamp });
                            }
                            current_app = None;
                        }
                    }
                }
            }

            match wait_monitor_signal(
                &control_rx,
                &fg_rx,
                Instant::now() + poll_interval,
                last_title_check,
                is_paused,
                &mut pending_hook,
                &mut foreground_closed,
            ) {
                MonitorWake::Command(command) => pending_command = Some(command),
                MonitorWake::Hook => wake_hook = true,
                MonitorWake::Poll => {}
                MonitorWake::Disconnected => {
                    if (current_app.is_some() || is_idle)
                        && last_successful_observation_at.is_some()
                    {
                        sink.accept(TrackedEvent::GapDetected {
                            timestamp: last_successful_observation_at.unwrap(),
                        });
                    }
                    break;
                }
            }
        }
    });

    EventSourceHandle::new(control_tx, hook_stop_tx, monitor_join, hook_join)
}

/// Failure returned by the canonical producer fence. The last acknowledged
/// watermark is included so callers can request one conserved partial snapshot
/// without inventing or advancing durability in the bridge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalCheckpointFailure {
    pub reason: CheckpointReason,
    pub requested_as_of: chrono::DateTime<chrono::Utc>,
    pub last_acknowledged_observed_through: Option<chrono::DateTime<chrono::Utc>>,
    pub message: String,
}

enum CanonicalMonitorCommand {
    Checkpoint {
        reason: CheckpointReason,
        requested_as_of: chrono::DateTime<chrono::Utc>,
        reply: mpsc::Sender<Result<CheckpointAck, CanonicalCheckpointFailure>>,
    },
    Shutdown,
}

/// Production bridge handle. It preserves the existing monitor behavior while
/// adding a non-pausing canonical producer fence on an independent reply
/// channel. The checkpoint worker and monitor sink share one serialized
/// producer state; neither the bridge nor storage derives competing time.
pub struct CanonicalMonitorHandle {
    monitor: Option<Box<dyn MonitorLifecycle>>,
    checkpoint_tx: mpsc::Sender<CanonicalMonitorCommand>,
    checkpoint_join: Option<thread::JoinHandle<()>>,
    clock: Arc<dyn AccountingClock>,
    last_ack: Arc<Mutex<Option<CheckpointAck>>>,
    command_lock: Mutex<()>,
    observations_suspended: Arc<AtomicBool>,
}

trait MonitorLifecycle: Send {
    fn pause(&self) -> bool;
    fn resume(&self) -> bool;
    fn stop(self: Box<Self>) -> bool;
}

impl MonitorLifecycle for EventSourceHandle {
    fn pause(&self) -> bool {
        EventSourceHandle::pause(self)
    }

    fn resume(&self) -> bool {
        EventSourceHandle::resume(self)
    }

    fn stop(self: Box<Self>) -> bool {
        EventSourceHandle::stop(*self)
    }
}

impl CanonicalMonitorHandle {
    pub fn checkpoint_current(
        &self,
        timeout: Duration,
    ) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        let _guard = self.command_guard();
        self.observations_suspended.store(true, Ordering::SeqCst);
        let requested_as_of = self.clock.now_utc();
        let result =
            self.request_checkpoint(CheckpointReason::CurrentRead, requested_as_of, timeout);
        self.observations_suspended.store(false, Ordering::SeqCst);
        result
    }

    pub fn pause(&self, timeout: Duration) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        let _guard = self.command_guard();
        self.observations_suspended.store(true, Ordering::SeqCst);
        let requested_as_of = self.clock.now_utc();
        if !self.monitor.as_ref().is_some_and(|monitor| monitor.pause()) {
            self.observations_suspended.store(false, Ordering::SeqCst);
            return Err(self.transport_failure(
                CheckpointReason::Pause,
                requested_as_of,
                "monitor pause failed",
            ));
        }
        let result =
            match self.request_checkpoint(CheckpointReason::Pause, requested_as_of, timeout) {
                Ok(ack) => Ok(ack),
                Err(mut error) => {
                    if !self
                        .monitor
                        .as_ref()
                        .is_some_and(|monitor| monitor.resume())
                    {
                        error
                            .message
                            .push_str("; monitor resume compensation failed");
                    }
                    Err(error)
                }
            };
        self.observations_suspended.store(false, Ordering::SeqCst);
        result
    }

    pub fn resume(&self, timeout: Duration) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        let _guard = self.command_guard();
        self.observations_suspended.store(true, Ordering::SeqCst);
        let requested_as_of = self.clock.now_utc();
        if !self
            .monitor
            .as_ref()
            .is_some_and(|monitor| monitor.resume())
        {
            self.observations_suspended.store(false, Ordering::SeqCst);
            return Err(self.transport_failure(
                CheckpointReason::Resume,
                requested_as_of,
                "monitor resume failed",
            ));
        }
        let result =
            match self.request_checkpoint(CheckpointReason::Resume, requested_as_of, timeout) {
                Ok(ack) => Ok(ack),
                Err(mut error) => {
                    if !self.monitor.as_ref().is_some_and(|monitor| monitor.pause()) {
                        error
                            .message
                            .push_str("; monitor pause compensation failed");
                    }
                    Err(error)
                }
            };
        self.observations_suspended.store(false, Ordering::SeqCst);
        result
    }

    pub fn stop(mut self, timeout: Duration) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        self.observations_suspended.store(true, Ordering::SeqCst);
        let requested_as_of = self.clock.now_utc();
        let pause_ok = self.monitor.as_ref().is_none_or(|monitor| monitor.pause());
        let result = if pause_ok {
            self.request_checkpoint(CheckpointReason::Stop, requested_as_of, timeout)
        } else {
            Err(self.transport_failure(
                CheckpointReason::Stop,
                requested_as_of,
                "monitor close fence failed",
            ))
        };
        let monitor_ok = self.monitor.take().is_none_or(|monitor| monitor.stop());
        self.shutdown_checkpoint_worker();
        if !monitor_ok {
            return Err(self.transport_failure(
                CheckpointReason::Stop,
                requested_as_of,
                "monitor stop/join failed",
            ));
        }
        result
    }

    fn request_checkpoint(
        &self,
        reason: CheckpointReason,
        requested_as_of: chrono::DateTime<chrono::Utc>,
        timeout: Duration,
    ) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        if timeout.is_zero() {
            return Err(self.transport_failure(
                reason,
                requested_as_of,
                "checkpoint acknowledgement timed out",
            ));
        }
        let (reply, response) = mpsc::channel();
        self.checkpoint_tx
            .send(CanonicalMonitorCommand::Checkpoint {
                reason,
                requested_as_of,
                reply,
            })
            .map_err(|_| {
                self.transport_failure(reason, requested_as_of, "checkpoint worker is unavailable")
            })?;
        response.recv_timeout(timeout).map_err(|_| {
            self.transport_failure(
                reason,
                requested_as_of,
                "checkpoint acknowledgement timed out",
            )
        })?
    }

    fn transport_failure(
        &self,
        reason: CheckpointReason,
        requested_as_of: chrono::DateTime<chrono::Utc>,
        message: &str,
    ) -> CanonicalCheckpointFailure {
        CanonicalCheckpointFailure {
            reason,
            requested_as_of,
            last_acknowledged_observed_through: self
                .last_ack
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_ref()
                .map(|ack| ack.durable_observed_through),
            message: message.to_owned(),
        }
    }

    fn command_guard(&self) -> std::sync::MutexGuard<'_, ()> {
        self.command_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn shutdown_checkpoint_worker(&mut self) {
        let _ = self.checkpoint_tx.send(CanonicalMonitorCommand::Shutdown);
        if let Some(join) = self.checkpoint_join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for CanonicalMonitorHandle {
    fn drop(&mut self) {
        self.observations_suspended.store(true, Ordering::SeqCst);
        if let Some(monitor) = self.monitor.take() {
            let _ = monitor.stop();
        }
        self.shutdown_checkpoint_worker();
    }
}

/// Start the compatibility monitor with a canonical producer wrapper. Legacy
/// rows remain available during cutover, but every authoritative canonical
/// heartbeat and lifecycle fence is staged and committed through the single
/// `AccountingStore::commit_production_checkpoint` seam.
pub fn run_canonical_monitor_loop<W, I>(
    window_resolver: W,
    idle_detector: I,
    poll_interval: Duration,
    idle_threshold: Duration,
    excluded_apps: Vec<String>,
    legacy_sink: Box<dyn EventSink>,
    accounting_store: Arc<dyn AccountingStore>,
    staging_store: Arc<dyn CheckpointStore>,
    clock: Arc<dyn AccountingClock>,
) -> CanonicalMonitorHandle
where
    W: WindowResolver + 'static,
    I: IdleDetector + 'static,
{
    let producer = Arc::new(Mutex::new(CanonicalProducer::new(
        accounting_store,
        staging_store,
    )));
    let last_ack = Arc::new(Mutex::new(None));
    let observations_suspended = Arc::new(AtomicBool::new(false));
    with_producer(&producer, |producer| {
        match producer.advance(CheckpointReason::StartupRecovery, clock.now_utc()) {
            Ok(ack) => {
                *last_ack
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(ack)
            }
            Err(error) => warn!("canonical startup checkpoint failed: {}", error.message),
        }
    });

    let canonical_sink: Box<dyn EventSink> = Box::new(CanonicalEventSink {
        legacy: legacy_sink,
        producer: producer.clone(),
        last_ack: last_ack.clone(),
        observations_suspended: observations_suspended.clone(),
    });
    let monitor = run_monitor_loop_with_clock(
        window_resolver,
        idle_detector,
        poll_interval,
        idle_threshold,
        excluded_apps,
        canonical_sink,
        clock.clone(),
    );
    let (checkpoint_tx, checkpoint_rx) = mpsc::channel();
    let worker_last_ack = last_ack.clone();
    let handle_clock = clock.clone();
    let checkpoint_join = thread::spawn(move || {
        while let Ok(command) = checkpoint_rx.recv() {
            match command {
                CanonicalMonitorCommand::Checkpoint {
                    reason,
                    requested_as_of,
                    reply,
                } => {
                    let result = with_producer(&producer, |producer| {
                        let transitions_before = producer.transitions.clone();
                        match reason {
                            CheckpointReason::Pause => {
                                producer.record_state(requested_as_of, ObservedAccounting::paused())
                            }
                            CheckpointReason::Resume | CheckpointReason::Stop => producer
                                .record_state(requested_as_of, ObservedAccounting::unknown()),
                            _ => {}
                        }
                        let result = producer.advance(reason, requested_as_of);
                        if result.is_err()
                            && matches!(
                                reason,
                                CheckpointReason::Pause
                                    | CheckpointReason::Resume
                                    | CheckpointReason::Stop
                            )
                        {
                            producer.transitions = transitions_before;
                        }
                        result
                    });
                    if let Ok(ack) = &result {
                        *worker_last_ack
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(ack.clone());
                    }
                    let _ = reply.send(result);
                }
                CanonicalMonitorCommand::Shutdown => break,
            }
        }
    });
    CanonicalMonitorHandle {
        monitor: Some(Box::new(monitor)),
        checkpoint_tx,
        checkpoint_join: Some(checkpoint_join),
        clock: handle_clock,
        last_ack,
        command_lock: Mutex::new(()),
        observations_suspended,
    }
}

#[derive(Clone)]
struct ObservedAccounting {
    state: AccountingState,
    attribution: AttributionIdentity,
}

impl ObservedAccounting {
    fn active(app: &AppInfo) -> Self {
        let app_id = app.display_name.clone();
        let window_id = app.window_title.clone();
        Self {
            state: AccountingState::Active,
            attribution: AttributionIdentity {
                app_id: Some(app_id.clone()),
                window_id: window_id.clone(),
                window_app_id: window_id.as_ref().map(|_| app_id),
                page_id: window_id.clone(),
                page_window_id: window_id,
            },
        }
    }

    fn idle() -> Self {
        Self {
            state: AccountingState::Idle,
            attribution: AttributionIdentity::default(),
        }
    }

    fn paused() -> Self {
        Self {
            state: AccountingState::Paused,
            attribution: AttributionIdentity::default(),
        }
    }

    fn unknown() -> Self {
        Self {
            state: AccountingState::Unknown,
            attribution: AttributionIdentity::default(),
        }
    }
}

struct CanonicalProducer {
    store: Arc<dyn AccountingStore>,
    stager: SessionAggregator,
    durable_state: ProducerCheckpointState,
    base_state: ObservedAccounting,
    transitions: Vec<(chrono::DateTime<chrono::Utc>, ObservedAccounting)>,
    pending_corrections: Vec<(UtcInterval, ObservedAccounting)>,
    source_identity: String,
    next_revision: i64,
    last_ack: Option<CheckpointAck>,
}

impl CanonicalProducer {
    fn new(store: Arc<dyn AccountingStore>, staging_store: Arc<dyn CheckpointStore>) -> Self {
        let durable_state = ProducerCheckpointState::load(&*store).unwrap_or(
            ProducerCheckpointState::LegacyPreCutover {
                legacy_observed_through: None,
            },
        );
        let next_revision = match &durable_state {
            ProducerCheckpointState::CanonicalCurrent {
                last_source_revision,
                ..
            } => last_source_revision.saturating_add(1),
            ProducerCheckpointState::LegacyPreCutover { .. } => 1,
        };
        Self {
            store,
            stager: SessionAggregator::new(staging_store),
            durable_state,
            base_state: ObservedAccounting::unknown(),
            transitions: Vec::new(),
            pending_corrections: Vec::new(),
            source_identity: "monitor:canonical:v8".to_owned(),
            next_revision,
            last_ack: None,
        }
    }

    fn record_state(&mut self, boundary: chrono::DateTime<chrono::Utc>, state: ObservedAccounting) {
        let boundary = canonical_boundary(boundary);
        if self
            .durable_state
            .observed_through()
            .is_some_and(|durable| boundary < durable)
        {
            return;
        }
        if let Some((last_boundary, last_state)) = self.transitions.last_mut() {
            if *last_boundary == boundary {
                *last_state = state;
                return;
            }
        }
        self.transitions.push((boundary, state));
        self.transitions.sort_by_key(|(at, _)| *at);
    }

    fn record_idle_correction(
        &mut self,
        start: chrono::DateTime<chrono::Utc>,
        end: chrono::DateTime<chrono::Utc>,
    ) {
        let start = canonical_boundary(start);
        let end = canonical_boundary(end);
        if start >= end {
            return;
        }
        let range = UtcInterval { start, end };
        if self
            .pending_corrections
            .iter()
            .any(|(existing, state)| *existing == range && state.state == AccountingState::Idle)
        {
            return;
        }
        self.pending_corrections
            .push((range, ObservedAccounting::idle()));
    }

    fn advance(
        &mut self,
        requested_reason: CheckpointReason,
        boundary: chrono::DateTime<chrono::Utc>,
    ) -> Result<CheckpointAck, CanonicalCheckpointFailure> {
        let requested_as_of = boundary;
        let boundary = canonical_boundary(boundary);
        let expected_from = self.durable_state.observed_through();
        if expected_from.is_some_and(|durable| boundary < durable) {
            return Err(self.failure(
                requested_reason,
                requested_as_of,
                "producer clock moved before the canonical watermark".to_owned(),
            ));
        }
        if expected_from == Some(boundary) && self.pending_corrections.is_empty() {
            if let ProducerCheckpointState::CanonicalCurrent {
                cutover_at,
                lifecycle,
                last_source_identity,
                last_source_revision,
                last_content_hash,
                ..
            } = &self.durable_state
            {
                return Ok(CheckpointAck {
                    durable_observed_through: boundary,
                    cutover_at: *cutover_at,
                    lifecycle: *lifecycle,
                    source_identity: last_source_identity.clone(),
                    source_revision: *last_source_revision,
                    content_hash: last_content_hash.clone(),
                    replayed: true,
                });
            }
        }
        let reason = if matches!(
            self.durable_state,
            ProducerCheckpointState::LegacyPreCutover { .. }
        ) {
            CheckpointReason::FirstCutover
        } else {
            requested_reason
        };
        let mut intervals = expected_from
            .filter(|start| *start < boundary)
            .map(|start| self.intervals_between(start, boundary))
            .unwrap_or_default();
        intervals.extend(
            self.pending_corrections
                .iter()
                .map(|(range, state)| self.interval(range.start, range.end, state)),
        );
        intervals.sort_by_key(|item| (item.range.start, item.range.end));
        let checkpoint = self
            .stager
            .stage_production_checkpoint(
                &self.durable_state,
                reason,
                boundary,
                self.source_identity.clone(),
                self.next_revision,
                CanonicalBatch {
                    intervals,
                    observed_through: boundary,
                },
            )
            .map_err(|error| self.failure(requested_reason, requested_as_of, error.to_string()))?;
        let ack = self
            .store
            .commit_production_checkpoint(&checkpoint)
            .map_err(|error| self.failure(requested_reason, requested_as_of, error.to_string()))?;
        self.durable_state = ProducerCheckpointState::load(&*self.store)
            .map_err(|error| self.failure(requested_reason, requested_as_of, error.to_string()))?;
        self.next_revision = ack.source_revision.saturating_add(1);
        self.commit_timeline(boundary);
        self.pending_corrections.clear();
        self.last_ack = Some(ack.clone());
        Ok(ack)
    }

    fn intervals_between(
        &self,
        start: chrono::DateTime<chrono::Utc>,
        end: chrono::DateTime<chrono::Utc>,
    ) -> Vec<AccountingInterval> {
        let mut state = self.base_state.clone();
        for (_, next) in self.transitions.iter().filter(|(at, _)| *at <= start) {
            state = next.clone();
        }
        let mut cursor = start;
        let mut intervals = Vec::new();
        for (at, next) in self
            .transitions
            .iter()
            .filter(|(at, _)| *at > start && *at < end)
        {
            intervals.push(self.interval(cursor, *at, &state));
            cursor = *at;
            state = next.clone();
        }
        if cursor < end {
            intervals.push(self.interval(cursor, end, &state));
        }
        intervals
    }

    fn interval(
        &self,
        start: chrono::DateTime<chrono::Utc>,
        end: chrono::DateTime<chrono::Utc>,
        observed: &ObservedAccounting,
    ) -> AccountingInterval {
        AccountingInterval {
            range: UtcInterval { start, end },
            state: observed.state,
            attribution: observed.attribution.clone(),
            source_identity: format!("{}:interval:{}", self.source_identity, self.next_revision),
            source_revision: 0,
        }
    }

    fn commit_timeline(&mut self, boundary: chrono::DateTime<chrono::Utc>) {
        for (_, state) in self.transitions.iter().filter(|(at, _)| *at <= boundary) {
            self.base_state = state.clone();
        }
        self.transitions.retain(|(at, _)| *at > boundary);
    }

    fn failure(
        &self,
        reason: CheckpointReason,
        requested_as_of: chrono::DateTime<chrono::Utc>,
        message: String,
    ) -> CanonicalCheckpointFailure {
        CanonicalCheckpointFailure {
            reason,
            requested_as_of,
            last_acknowledged_observed_through: self
                .last_ack
                .as_ref()
                .map(|ack| ack.durable_observed_through)
                .or_else(|| self.durable_state.observed_through()),
            message,
        }
    }
}

struct CanonicalEventSink {
    legacy: Box<dyn EventSink>,
    producer: Arc<Mutex<CanonicalProducer>>,
    last_ack: Arc<Mutex<Option<CheckpointAck>>>,
    observations_suspended: Arc<AtomicBool>,
}

impl EventSink for CanonicalEventSink {
    fn accept(&mut self, event: TrackedEvent) {
        if !self.observations_suspended.load(Ordering::SeqCst) {
            with_producer(&self.producer, |producer| {
                let boundary = match &event {
                    TrackedEvent::AppSwitched {
                        current, timestamp, ..
                    } => {
                        producer.record_state(*timestamp, ObservedAccounting::active(current));
                        *timestamp
                    }
                    TrackedEvent::IdleStarted {
                        timestamp, grace, ..
                    } => {
                        let idle_start =
                            *timestamp - chrono::Duration::from_std(*grace).unwrap_or_default();
                        producer.record_idle_correction(idle_start, *timestamp);
                        producer.record_state(*timestamp, ObservedAccounting::idle());
                        *timestamp
                    }
                    TrackedEvent::IdleEnded {
                        current_app,
                        timestamp,
                        ..
                    } => {
                        producer.record_state(*timestamp, ObservedAccounting::active(current_app));
                        *timestamp
                    }
                    TrackedEvent::GapDetected { timestamp } => {
                        producer.record_state(*timestamp, ObservedAccounting::unknown());
                        *timestamp
                    }
                };
                match producer.advance(CheckpointReason::Heartbeat, boundary) {
                    Ok(ack) => record_ack(&self.last_ack, ack),
                    Err(error) => warn!("canonical event checkpoint failed: {}", error.message),
                }
            });
        }
        self.legacy.accept(event);
    }

    fn observation_checkpoint(
        &mut self,
        current: AppInfo,
        timestamp: chrono::DateTime<chrono::Utc>,
    ) {
        if !self.observations_suspended.load(Ordering::SeqCst) {
            with_producer(&self.producer, |producer| {
                let state = if current.is_idle() {
                    ObservedAccounting::idle()
                } else {
                    ObservedAccounting::active(&current)
                };
                producer.record_state(timestamp, state);
                match producer.advance(CheckpointReason::Heartbeat, timestamp) {
                    Ok(ack) => record_ack(&self.last_ack, ack),
                    Err(error) => warn!("canonical heartbeat failed: {}", error.message),
                }
            });
        }
        self.legacy.observation_checkpoint(current, timestamp);
    }
}

fn with_producer<T>(
    producer: &Arc<Mutex<CanonicalProducer>>,
    operation: impl FnOnce(&mut CanonicalProducer) -> T,
) -> T {
    match producer.lock() {
        Ok(mut guard) => operation(&mut guard),
        Err(poisoned) => operation(&mut poisoned.into_inner()),
    }
}

fn record_ack(receipt: &Arc<Mutex<Option<CheckpointAck>>>, ack: CheckpointAck) {
    *receipt
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(ack);
}

fn canonical_boundary(value: chrono::DateTime<chrono::Utc>) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::from_timestamp(value.timestamp(), 0).unwrap_or(value)
}

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
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    use super::*;
    use crate::contracts::accounting::{
        AccountingError, AccountingQuery, FixedAccountingClock, ProductionCheckpoint,
        ProductionCheckpointError, RecoveryPoint, SnapshotIntegrity,
    };
    use crate::engine::accounting::AccountingQueryService;
    use crate::storage::SqliteStore;

    static NEXT_TEST_DB: AtomicUsize = AtomicUsize::new(0);

    fn isolated_store(label: &str) -> (PathBuf, Arc<SqliteStore>) {
        let id = NEXT_TEST_DB.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "timetrace-monitor-{label}-{}-{id}.sqlite3",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let store = Arc::new(SqliteStore::open(path.clone()).expect("open test ledger"));
        (path, store)
    }

    struct FailIdleCheckpointStore {
        inner: Arc<SqliteStore>,
        fail_next_idle: AtomicBool,
    }

    impl FailIdleCheckpointStore {
        fn new(inner: Arc<SqliteStore>) -> Self {
            Self {
                inner,
                fail_next_idle: AtomicBool::new(false),
            }
        }
    }

    impl AccountingStore for FailIdleCheckpointStore {
        fn load_producer_checkpoint_state(
            &self,
        ) -> Result<ProducerCheckpointState, ProductionCheckpointError> {
            self.inner.load_producer_checkpoint_state()
        }

        fn commit_production_checkpoint(
            &self,
            checkpoint: &ProductionCheckpoint,
        ) -> Result<CheckpointAck, ProductionCheckpointError> {
            if checkpoint
                .batch
                .intervals
                .iter()
                .any(|item| item.state == AccountingState::Idle)
                && self.fail_next_idle.swap(false, Ordering::SeqCst)
            {
                return Err(ProductionCheckpointError::InvalidCheckpoint(
                    "injected idle correction failure".to_owned(),
                ));
            }
            self.inner.commit_production_checkpoint(checkpoint)
        }

        fn write_canonical_batch(&self, batch: &CanonicalBatch) -> Result<(), AccountingError> {
            self.inner.write_canonical_batch(batch)
        }

        fn load_accounting_intervals(
            &self,
            range: &UtcInterval,
        ) -> Result<Vec<AccountingInterval>, AccountingError> {
            self.inner.load_accounting_intervals(range)
        }

        fn durable_observed_through(
            &self,
        ) -> Result<Option<chrono::DateTime<Utc>>, AccountingError> {
            self.inner.durable_observed_through()
        }

        fn last_known_observed_through(&self) -> Option<chrono::DateTime<Utc>> {
            self.inner.last_known_observed_through()
        }

        fn refresh_current(
            &self,
            as_of: chrono::DateTime<Utc>,
        ) -> Result<Option<chrono::DateTime<Utc>>, AccountingError> {
            self.inner.refresh_current(as_of)
        }

        fn load_last_durable_intervals(
            &self,
            range: &UtcInterval,
        ) -> Result<Vec<AccountingInterval>, AccountingError> {
            self.inner.load_last_durable_intervals(range)
        }

        fn recover_after_restart(&self, point: &RecoveryPoint) -> Result<(), AccountingError> {
            self.inner.recover_after_restart(point)
        }
    }

    struct FakeLifecycle {
        paused: Arc<AtomicBool>,
        fail_resume: Arc<AtomicBool>,
        stopped: Arc<AtomicBool>,
    }

    impl MonitorLifecycle for FakeLifecycle {
        fn pause(&self) -> bool {
            self.paused.store(true, Ordering::SeqCst);
            true
        }

        fn resume(&self) -> bool {
            if self.fail_resume.swap(false, Ordering::SeqCst) {
                return false;
            }
            self.paused.store(false, Ordering::SeqCst);
            true
        }

        fn stop(self: Box<Self>) -> bool {
            self.stopped.store(true, Ordering::SeqCst);
            true
        }
    }

    fn checkpoint_ack(at: chrono::DateTime<Utc>, reason: CheckpointReason) -> CheckpointAck {
        CheckpointAck {
            durable_observed_through: at,
            cutover_at: at,
            lifecycle: reason,
            source_identity: "monitor:canonical:v8".to_owned(),
            source_revision: 1,
            content_hash: "fixture".to_owned(),
            replayed: false,
        }
    }

    fn scripted_handle(
        clock: FixedAccountingClock,
        initial_ack: CheckpointAck,
        initially_paused: bool,
        fail_resume: bool,
        fail_checkpoint: Option<CheckpointReason>,
    ) -> (CanonicalMonitorHandle, Arc<AtomicBool>) {
        let paused = Arc::new(AtomicBool::new(initially_paused));
        let last_ack = Arc::new(Mutex::new(Some(initial_ack.clone())));
        let (checkpoint_tx, checkpoint_rx) = mpsc::channel();
        let worker_ack = last_ack.clone();
        let checkpoint_join = thread::spawn(move || {
            while let Ok(command) = checkpoint_rx.recv() {
                match command {
                    CanonicalMonitorCommand::Checkpoint {
                        reason,
                        requested_as_of,
                        reply,
                    } => {
                        if fail_checkpoint == Some(reason) {
                            let _ = reply.send(Err(CanonicalCheckpointFailure {
                                reason,
                                requested_as_of,
                                last_acknowledged_observed_through: Some(
                                    initial_ack.durable_observed_through,
                                ),
                                message: "injected checkpoint failure".to_owned(),
                            }));
                        } else {
                            let ack = checkpoint_ack(requested_as_of, reason);
                            *worker_ack.lock().unwrap() = Some(ack.clone());
                            let _ = reply.send(Ok(ack));
                        }
                    }
                    CanonicalMonitorCommand::Shutdown => break,
                }
            }
        });
        let monitor = FakeLifecycle {
            paused: paused.clone(),
            fail_resume: Arc::new(AtomicBool::new(fail_resume)),
            stopped: Arc::new(AtomicBool::new(false)),
        };
        (
            CanonicalMonitorHandle {
                monitor: Some(Box::new(monitor)),
                checkpoint_tx,
                checkpoint_join: Some(checkpoint_join),
                clock: Arc::new(clock),
                last_ack,
                command_lock: Mutex::new(()),
                observations_suspended: Arc::new(AtomicBool::new(false)),
            },
            paused,
        )
    }

    #[test]
    fn excludes_by_exe_name_with_or_without_extension() {
        let app = AppInfo::new(r"C:\Apps\Example.exe".into(), "Example".into());
        assert!(is_excluded(&app, &["example".into()]));
        assert!(is_excluded(&app, &["EXAMPLE.EXE".into()]));
        assert!(!is_excluded(&app, &["other.exe".into()]));
    }

    #[test]
    fn idle_grace_correction_survives_failure_retry_and_restart() {
        let (path, sqlite) = isolated_store("idle-correction");
        let store = Arc::new(FailIdleCheckpointStore::new(sqlite.clone()));
        let t0 = Utc
            .with_ymd_and_hms(2026, 1, 15, 10, 0, 0)
            .single()
            .unwrap();
        let mut producer = CanonicalProducer::new(store.clone(), sqlite.clone());
        producer
            .advance(CheckpointReason::StartupRecovery, t0)
            .expect("first cutover");
        let app = AppInfo::new("C:/fixture.exe".into(), "fixture-app".into());
        producer.record_state(t0, ObservedAccounting::active(&app));
        producer
            .advance(
                CheckpointReason::Heartbeat,
                t0 + ChronoDuration::seconds(3000),
            )
            .expect("first active heartbeat");
        producer.record_state(
            t0 + ChronoDuration::seconds(3500),
            ObservedAccounting::active(&app),
        );
        producer
            .advance(
                CheckpointReason::Heartbeat,
                t0 + ChronoDuration::seconds(3500),
            )
            .expect("second active heartbeat");

        producer.record_idle_correction(
            t0 + ChronoDuration::seconds(3000),
            t0 + ChronoDuration::seconds(3600),
        );
        producer.record_state(
            t0 + ChronoDuration::seconds(3600),
            ObservedAccounting::idle(),
        );
        store.fail_next_idle.store(true, Ordering::SeqCst);
        assert!(producer
            .advance(
                CheckpointReason::Heartbeat,
                t0 + ChronoDuration::seconds(3600)
            )
            .is_err());
        producer
            .advance(
                CheckpointReason::Heartbeat,
                t0 + ChronoDuration::seconds(3600),
            )
            .expect("idle correction retry");

        let range = UtcInterval::new(t0, t0 + ChronoDuration::seconds(3600)).unwrap();
        let clock = FixedAccountingClock::new(range.end);
        let snapshot = AccountingQueryService::new(&*store, &clock)
            .snapshot(range.clone(), AccountingQuery::At { as_of: range.end })
            .expect("corrected snapshot");
        assert_eq!(snapshot.integrity, SnapshotIntegrity::Complete);
        assert_eq!(snapshot.totals.active_seconds, 3000);
        assert_eq!(snapshot.totals.idle_seconds, 600);
        assert_eq!(snapshot.totals.accounted_seconds(), 3600);
        assert_eq!(
            snapshot
                .attribution
                .apps
                .iter()
                .map(|item| item.seconds)
                .sum::<i64>(),
            3000
        );
        let rows = store.load_accounting_intervals(&range).unwrap();

        drop(producer);
        drop(store);
        drop(sqlite);
        let reopened = SqliteStore::open(path.clone()).expect("reopen corrected ledger");
        assert_eq!(reopened.load_accounting_intervals(&range).unwrap(), rows);
        let reopened_snapshot = AccountingQueryService::new(&reopened, &clock)
            .snapshot(range.clone(), AccountingQuery::At { as_of: range.end })
            .unwrap();
        assert_eq!(reopened_snapshot.totals, snapshot.totals);
        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn lifecycle_failures_restore_physical_state_and_keep_producer_receipt() {
        let t0 = Utc
            .with_ymd_and_hms(2026, 1, 15, 10, 0, 0)
            .single()
            .unwrap();
        let clock = FixedAccountingClock::new(t0 + ChronoDuration::seconds(10));
        let (pause_handle, physically_paused) = scripted_handle(
            clock,
            checkpoint_ack(t0, CheckpointReason::Heartbeat),
            false,
            false,
            Some(CheckpointReason::Pause),
        );
        let failure = pause_handle
            .pause(Duration::from_secs(1))
            .expect_err("Pause commit failure");
        assert!(!physically_paused.load(Ordering::SeqCst));
        assert_eq!(failure.requested_as_of, t0 + ChronoDuration::seconds(10));
        assert_eq!(failure.last_acknowledged_observed_through, Some(t0));
        drop(pause_handle);

        let resume_clock = FixedAccountingClock::new(t0 + ChronoDuration::seconds(20));
        let (resume_handle, physically_paused) = scripted_handle(
            resume_clock,
            checkpoint_ack(t0, CheckpointReason::Pause),
            true,
            true,
            None,
        );
        let failure = resume_handle
            .resume(Duration::from_secs(1))
            .expect_err("Resume transport failure");
        assert!(physically_paused.load(Ordering::SeqCst));
        assert_eq!(failure.requested_as_of, t0 + ChronoDuration::seconds(20));
        assert_eq!(failure.last_acknowledged_observed_through, Some(t0));
        drop(resume_handle);
    }
    #[test]
    fn compatibility_wait_boundary_uses_existing_control_quantum() {
        assert!(use_compatibility_sleep(Duration::ZERO));
        assert!(use_compatibility_sleep(Duration::from_millis(1)));
        assert!(use_compatibility_sleep(SIGNAL_CHECK_INTERVAL));
        assert!(!use_compatibility_sleep(SIGNAL_CHECK_INTERVAL + Duration::from_nanos(1)));
        assert!(!use_compatibility_sleep(Duration::from_secs(60)));
    }

    #[test]
    fn short_poll_uses_real_sleep_without_early_observation_or_native_hook() {
        let (_control_tx, control_rx) = mpsc::channel();
        let (_fg_tx, fg_rx) = mpsc::channel();
        let mut pending = false;
        let mut closed = false;
        for _ in 0..12 {
            let start = Instant::now();
            let deadline = start + Duration::from_millis(1);
            assert!(matches!(
                wait_monitor_signal(
                    &control_rx, &fg_rx, deadline, start, false,
                    &mut pending, &mut closed,
                ),
                MonitorWake::Poll
            ));
            // No brittle upper wall-clock threshold: the unchanged native
            // accounting fixture, run by the host, decides compatibility.
            assert!(Instant::now() >= deadline);
            assert!(!pending);
            assert!(!closed);
        }
    }

    #[test]
    fn short_tail_checks_control_before_sampling_and_disconnects_without_spin() {
        let (control_tx, control_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            let mut pending = false;
            let mut closed = false;
            let mut polls = 0;
            ready_tx.send(()).unwrap();
            loop {
                match wait_monitor_signal(
                    &control_rx, &fg_rx,
                    Instant::now() + Duration::from_millis(25),
                    Instant::now(), false, &mut pending, &mut closed,
                ) {
                    MonitorWake::Command(MonitorCommand::Stop { ack }) => {
                        ack.send(true).unwrap();
                    }
                    MonitorWake::Disconnected => return polls,
                    MonitorWake::Poll => polls += 1,
                    _ => panic!("no foreground event or other command was sent"),
                }
            }
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let (ack, receipt) = mpsc::channel();
        control_tx.send(MonitorCommand::Stop { ack }).unwrap();
        assert!(receipt.recv_timeout(Duration::from_secs(1)).unwrap());
        // Both already-enqueued commands and disconnect are checked before a
        // deadline observation. No native monitor thread is constructed here.
        drop(control_tx);
        drop(fg_tx);
        worker.join().unwrap();
    }

    #[test]
    fn long_poll_control_ack_and_drop_use_wakeable_wait_without_native_hook() {
        let (control_tx, control_rx) = mpsc::channel();
        let (hook_stop_tx, hook_stop_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        let monitor = thread::spawn(move || {
            let mut paused = false;
            let mut pending = false;
            let mut closed = false;
            loop {
                match wait_monitor_signal(
                    &control_rx,
                    &fg_rx,
                    Instant::now() + Duration::from_secs(60),
                    Instant::now(),
                    paused,
                    &mut pending,
                    &mut closed,
                ) {
                    MonitorWake::Command(MonitorCommand::SetPaused { paused: next, ack }) => {
                        paused = next;
                        ack.send(true).unwrap();
                    }
                    MonitorWake::Command(MonitorCommand::Stop { ack }) => {
                        ack.send(true).unwrap();
                        break;
                    }
                    MonitorWake::Disconnected => break,
                    MonitorWake::Hook | MonitorWake::Poll => {}
                }
            }
        });
        let hook = thread::spawn(move || {
            hook_stop_rx.recv().unwrap();
        });
        let handle = EventSourceHandle::new(control_tx, hook_stop_tx, monitor, hook);
        let start = Instant::now();
        assert!(handle.pause());
        assert!(handle.resume());
        drop(handle);
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(fg_tx);
    }

    #[test]
    fn early_hook_is_coalesced_until_original_half_second_gate() {
        let (_control_tx, control_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        for _ in 0..100 {
            fg_tx.send(()).unwrap();
        }
        let start = Instant::now();
        let mut pending = false;
        let mut closed = false;
        let wake = wait_monitor_signal(
            &control_rx,
            &fg_rx,
            start + Duration::from_secs(60),
            start,
            false,
            &mut pending,
            &mut closed,
        );
        assert!(matches!(wake, MonitorWake::Hook));
        assert!(start.elapsed() >= Duration::from_millis(500));
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(!pending);
    }

    #[test]
    fn signal_slices_do_not_observe_before_poll_and_paused_hook_is_ignored() {
        let (_control_tx, control_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        fg_tx.send(()).unwrap();
        let start = Instant::now();
        let mut pending = true;
        let mut closed = false;
        let wake = wait_monitor_signal(
            &control_rx,
            &fg_rx,
            start + Duration::from_millis(160),
            start - Duration::from_secs(1),
            true,
            &mut pending,
            &mut closed,
        );
        assert!(matches!(wake, MonitorWake::Poll));
        assert!(start.elapsed() >= Duration::from_millis(160));
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(!pending);
    }

    #[test]
    fn disconnected_hook_waits_real_deadline_and_control_disconnect_exits() {
        let (control_tx, control_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        drop(fg_tx);
        let start = Instant::now();
        let mut pending = false;
        let mut closed = false;
        assert!(matches!(
            wait_monitor_signal(
                &control_rx,
                &fg_rx,
                start + Duration::from_millis(100),
                start,
                false,
                &mut pending,
                &mut closed
            ),
            MonitorWake::Poll
        ));
        assert!(closed);
        assert!(start.elapsed() >= Duration::from_millis(100));
        drop(control_tx);
        assert!(matches!(
            wait_monitor_signal(
                &control_rx,
                &fg_rx,
                Instant::now() + Duration::from_secs(60),
                start,
                false,
                &mut pending,
                &mut closed
            ),
            MonitorWake::Disconnected
        ));
        assert!(matches!(
            wait_monitor_signal(
                &control_rx,
                &fg_rx,
                Instant::now(),
                start,
                false,
                &mut pending,
                &mut closed
            ),
            MonitorWake::Disconnected
        ));
    }

    #[test]
    fn hook_flood_cannot_starve_control_or_resurrect_after_stop() {
        let (control_tx, control_rx) = mpsc::channel();
        let (fg_tx, fg_rx) = mpsc::channel();
        for _ in 0..10000 {
            fg_tx.send(()).unwrap();
        }
        let (ack, receipt) = mpsc::channel();
        let sender = thread::spawn(move || {
            thread::sleep(Duration::from_millis(20));
            control_tx.send(MonitorCommand::Stop { ack }).unwrap();
        });
        let start = Instant::now();
        let mut pending = false;
        let mut closed = false;
        match wait_monitor_signal(
            &control_rx,
            &fg_rx,
            start + Duration::from_secs(60),
            start,
            false,
            &mut pending,
            &mut closed,
        ) {
            MonitorWake::Command(MonitorCommand::Stop { ack }) => ack.send(true).unwrap(),
            _ => panic!("control must win before the throttled hook"),
        }
        assert!(receipt.recv_timeout(Duration::from_secs(1)).unwrap());
        assert!(start.elapsed() < Duration::from_secs(1));
        sender.join().unwrap();
    }

}
