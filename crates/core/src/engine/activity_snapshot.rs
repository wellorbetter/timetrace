//! In-memory projection of the canonical foreground activity lifecycle.
//!
//! The monitor remains the single OS observation pipeline. This projection is
//! a constant-time, read-only view for real-time features and deliberately
//! omits window titles.

use std::sync::{Arc, RwLock};

use chrono::{DateTime, Utc};

use crate::contracts::events::{AppInfo, EventSink, TrackedEvent};
use crate::engine::app_identity::{normalize_executable_path, privacy_safe_app_name};

/// Eligibility state of the latest foreground activity observation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityState {
    /// A stable, non-excluded application is active.
    Active,
    /// The user is idle or the desktop is locked.
    Idle,
    /// The current foreground application is excluded from tracking.
    Excluded,
    /// Tracking was explicitly paused by the user.
    Paused,
    /// No stable foreground application is currently available.
    Unavailable,
}

/// Privacy-safe executable identity attached only to active snapshots.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityApp {
    /// Platform-normalized absolute executable path used for local matching.
    pub app_path: String,
    /// Friendly display name. No window-title content is retained.
    pub app_name: String,
}

/// One immutable read model of current foreground activity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivitySnapshot {
    /// Monotonic in-process revision incremented for each lifecycle event.
    pub revision: u64,
    /// Latest eligibility state.
    pub state: ActivityState,
    /// Explicit pause bit for bridge consumers that do not model state enums.
    pub tracking_paused: bool,
    /// Stable application identity only when [`ActivityState::Active`].
    pub app: Option<ActivityApp>,
    /// Event boundary represented by this snapshot.
    pub observed_at: DateTime<Utc>,
}

impl ActivitySnapshot {
    fn initial(initially_paused: bool) -> Self {
        Self {
            revision: 0,
            state: if initially_paused {
                ActivityState::Paused
            } else {
                ActivityState::Unavailable
            },
            tracking_paused: initially_paused,
            app: None,
            observed_at: Utc::now(),
        }
    }
}

/// Write-side event projection for [`ActivitySnapshotReader`].
pub struct ActivitySnapshotProjector {
    shared: Arc<RwLock<ActivitySnapshot>>,
}

impl ActivitySnapshotProjector {
    /// Create a projection in the process startup pause state.
    pub fn new(initially_paused: bool) -> Self {
        Self {
            shared: Arc::new(RwLock::new(ActivitySnapshot::initial(initially_paused))),
        }
    }

    /// Create a constant-time reader backed by the same in-memory snapshot.
    pub fn reader(&self) -> ActivitySnapshotReader {
        ActivitySnapshotReader {
            shared: Arc::clone(&self.shared),
        }
    }

    fn update(
        &self,
        state: ActivityState,
        tracking_paused: bool,
        app: Option<ActivityApp>,
        observed_at: DateTime<Utc>,
    ) {
        let mut snapshot = match self.shared.write() {
            Ok(snapshot) => snapshot,
            Err(poisoned) => poisoned.into_inner(),
        };
        snapshot.revision = snapshot.revision.saturating_add(1);
        snapshot.state = state;
        snapshot.tracking_paused = tracking_paused;
        snapshot.app = app;
        snapshot.observed_at = observed_at;
    }
}

impl EventSink for ActivitySnapshotProjector {
    fn accept(&mut self, event: TrackedEvent) {
        match event {
            TrackedEvent::AppSwitched {
                current, timestamp, ..
            }
            | TrackedEvent::IdleEnded {
                current_app: current,
                timestamp,
                ..
            } => match activity_app(&current) {
                Some(app) => self.update(ActivityState::Active, false, Some(app), timestamp),
                None => self.update(ActivityState::Unavailable, false, None, timestamp),
            },
            TrackedEvent::IdleStarted { timestamp, .. } => {
                self.update(ActivityState::Idle, false, None, timestamp);
            }
            TrackedEvent::TrackingPaused { timestamp } => {
                self.update(ActivityState::Paused, true, None, timestamp);
            }
            TrackedEvent::TrackingResumed { timestamp }
            | TrackedEvent::GapDetected { timestamp }
            | TrackedEvent::ForegroundUnavailable { timestamp } => {
                self.update(ActivityState::Unavailable, false, None, timestamp);
            }
            TrackedEvent::ForegroundExcluded { timestamp } => {
                self.update(ActivityState::Excluded, false, None, timestamp);
            }
        }
    }
}

fn activity_app(app: &AppInfo) -> Option<ActivityApp> {
    let app_path = normalize_executable_path(&app.exe_path).ok()?;
    Some(ActivityApp {
        app_path,
        // Reminder-facing names must not inherit title-derived labels or
        // arbitrary parent directories from the historical tracker.
        app_name: privacy_safe_app_name(&app.exe_path, None),
    })
}

/// Cloneable constant-time read handle for the latest activity snapshot.
#[derive(Clone)]
pub struct ActivitySnapshotReader {
    shared: Arc<RwLock<ActivitySnapshot>>,
}

impl ActivitySnapshotReader {
    /// Return a cloned snapshot without querying the OS or SQLite.
    pub fn snapshot(&self) -> ActivitySnapshot {
        match self.shared.read() {
            Ok(snapshot) => snapshot.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }
}

/// Event sink that sends each lifecycle event through one ordered pipeline to
/// multiple projections/consumers.
pub struct FanoutEventSink {
    sinks: Vec<Box<dyn EventSink>>,
}

impl FanoutEventSink {
    /// Construct an ordered fan-out from one or more event sinks.
    pub fn new(sinks: Vec<Box<dyn EventSink>>) -> Self {
        Self { sinks }
    }

    /// Append a sink that will receive subsequent events after existing ones.
    pub fn push(&mut self, sink: Box<dyn EventSink>) {
        self.sinks.push(sink);
    }
}

impl EventSink for FanoutEventSink {
    fn accept(&mut self, event: TrackedEvent) {
        for sink in &mut self.sinks {
            sink.accept(event.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    fn app() -> AppInfo {
        #[cfg(target_os = "windows")]
        let path = r"C:\Apps\Editor.exe";
        #[cfg(not(target_os = "windows"))]
        let path = "/Applications/Editor.app/Contents/MacOS/Editor";
        AppInfo::new(path.to_string(), "Editor".to_string())
            .with_title("private-document.txt".to_string())
    }

    #[test]
    fn initial_pause_is_visible_without_a_monitor_race() {
        let projector = ActivitySnapshotProjector::new(true);
        let snapshot = projector.reader().snapshot();
        assert_eq!(snapshot.state, ActivityState::Paused);
        assert!(snapshot.tracking_paused);
        assert!(snapshot.app.is_none());
    }

    #[test]
    fn projector_maps_every_invalid_boundary_and_drops_titles() {
        let mut projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();
        projector.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: app(),
            timestamp: ts(10),
        });
        let active = reader.snapshot();
        assert_eq!(active.state, ActivityState::Active);
        assert_eq!(active.app.as_ref().unwrap().app_name, "Editor");
        assert!(!format!("{active:?}").contains("private-document"));

        projector.accept(TrackedEvent::IdleStarted {
            timestamp: ts(20),
            grace: std::time::Duration::ZERO,
        });
        assert_eq!(reader.snapshot().state, ActivityState::Idle);
        projector.accept(TrackedEvent::ForegroundExcluded { timestamp: ts(30) });
        assert_eq!(reader.snapshot().state, ActivityState::Excluded);
        projector.accept(TrackedEvent::TrackingPaused { timestamp: ts(40) });
        assert_eq!(reader.snapshot().state, ActivityState::Paused);
        projector.accept(TrackedEvent::TrackingResumed { timestamp: ts(50) });
        assert_eq!(reader.snapshot().state, ActivityState::Unavailable);
        projector.accept(TrackedEvent::GapDetected { timestamp: ts(60) });
        let unavailable = reader.snapshot();
        assert_eq!(unavailable.state, ActivityState::Unavailable);
        assert_eq!(unavailable.revision, 6);
        assert!(unavailable.app.is_none());
    }

    #[test]
    fn projector_does_not_expose_private_runtime_parent_as_display_name() {
        #[cfg(target_os = "windows")]
        let path = r"C:\Users\Alice\secret-client\node.exe";
        #[cfg(not(target_os = "windows"))]
        let path = "/Users/alice/secret-client/node";
        let private_label = "secret-client";
        let mut projector = ActivitySnapshotProjector::new(false);
        let reader = projector.reader();

        projector.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: AppInfo::new(path.to_string(), private_label.to_string())
                .with_title("private-document.txt".to_string()),
            timestamp: ts(10),
        });

        let snapshot = reader.snapshot();
        assert_eq!(snapshot.app.as_ref().unwrap().app_name, "Node.js");
        assert!(
            !snapshot
                .app
                .as_ref()
                .unwrap()
                .app_name
                .contains(private_label)
        );
        assert!(!format!("{snapshot:?}").contains("private-document"));
    }

    struct RecordingSink(Arc<Mutex<Vec<TrackedEvent>>>);

    impl EventSink for RecordingSink {
        fn accept(&mut self, event: TrackedEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    #[test]
    fn fanout_preserves_event_order_for_every_sink() {
        let left = Arc::new(Mutex::new(Vec::new()));
        let right = Arc::new(Mutex::new(Vec::new()));
        let mut fanout = FanoutEventSink::new(vec![
            Box::new(RecordingSink(Arc::clone(&left))),
            Box::new(RecordingSink(Arc::clone(&right))),
        ]);
        let events = vec![
            TrackedEvent::TrackingPaused { timestamp: ts(1) },
            TrackedEvent::TrackingResumed { timestamp: ts(2) },
            TrackedEvent::ForegroundUnavailable { timestamp: ts(3) },
        ];
        for event in &events {
            fanout.accept(event.clone());
        }
        assert_eq!(*left.lock().unwrap(), events);
        assert_eq!(*right.lock().unwrap(), events);
    }
}
