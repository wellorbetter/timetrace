//! Migration adapter from TimeTrace tracking events into Amadeus perception.
//!
//! Dependency direction matters: TimeTrace depends on `amadeus-core`; Amadeus
//! never imports a TimeTrace type. This module can disappear once the native
//! platform observer has been fully moved into Amadeus.

use amadeus_core::{
    ensure_data_dir, memory_database_path, ComputerActivity, MemoryCore, MemoryError,
    PerceptionEvent, SqliteLivedMemoryStore,
};
use chrono::Utc;
use tracing::warn;

use crate::contracts::events::{AppInfo, EventSink, TrackedEvent};

pub fn adapt_tracked_event(event: &TrackedEvent) -> PerceptionEvent {
    match event {
        TrackedEvent::AppSwitched {
            previous,
            current,
            timestamp,
        } => PerceptionEvent::ForegroundChanged {
            previous: previous.as_ref().map(adapt_app),
            current: adapt_app(current),
            at: *timestamp,
        },
        TrackedEvent::IdleStarted { timestamp, grace } => PerceptionEvent::IdleStarted {
            at: *timestamp,
            grace_ms: grace.as_millis().min(u64::MAX as u128) as u64,
        },
        TrackedEvent::IdleEnded {
            current_app,
            timestamp,
            ..
        } => PerceptionEvent::IdleEnded {
            current: adapt_app(current_app),
            at: *timestamp,
        },
        TrackedEvent::GapDetected { timestamp } => PerceptionEvent::GapDetected { at: *timestamp },
    }
}

fn adapt_app(app: &AppInfo) -> ComputerActivity {
    let app_id = if app.exe_path.trim().is_empty() {
        app.display_name.to_lowercase()
    } else {
        app.exe_path.to_lowercase()
    };
    let mut activity = ComputerActivity::new(app_id, app.display_name.clone());
    if !app.exe_path.trim().is_empty() {
        activity = activity.with_executable_path(app.exe_path.clone());
    }
    if let Some(title) = app.window_title.as_ref().filter(|title| !title.trim().is_empty()) {
        activity = activity.with_window_title(title.clone());
    }
    activity
}

/// Event sink that writes human-scale episodes into Amadeus-owned storage.
pub struct AmadeusMemorySink {
    core: MemoryCore<SqliteLivedMemoryStore>,
}

impl AmadeusMemorySink {
    pub fn open_default() -> Result<Self, MemoryError> {
        ensure_data_dir()?;
        let store = SqliteLivedMemoryStore::open(memory_database_path())?;
        Ok(Self {
            core: MemoryCore::new(store),
        })
    }

    pub fn from_store(store: SqliteLivedMemoryStore) -> Self {
        Self {
            core: MemoryCore::new(store),
        }
    }
}

impl EventSink for AmadeusMemorySink {
    fn accept(&mut self, event: TrackedEvent) {
        if let Err(error) = self.core.ingest(adapt_tracked_event(&event)) {
            warn!("Amadeus lived-memory ingest failed: {error}");
        }
    }
}

impl Drop for AmadeusMemorySink {
    fn drop(&mut self) {
        if let Err(error) = self.core.flush(Utc::now()) {
            warn!("Amadeus lived-memory flush failed: {error}");
        }
    }
}

/// Duplicates one tracking stream into legacy TimeTrace storage and the new
/// Amadeus memory pipeline during migration.
pub struct FanoutEventSink {
    primary: Box<dyn EventSink>,
    secondary: Box<dyn EventSink>,
}

impl FanoutEventSink {
    pub fn new(primary: Box<dyn EventSink>, secondary: Box<dyn EventSink>) -> Self {
        Self { primary, secondary }
    }
}

impl EventSink for FanoutEventSink {
    fn accept(&mut self, event: TrackedEvent) {
        self.primary.accept(event.clone());
        self.secondary.accept(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_window_context_without_leaking_timetrace_types() {
        let app = AppInfo::new("/Applications/Editor.app".into(), "Editor".into())
            .with_title("amadeus-core/src/memory.rs".into());
        let event = TrackedEvent::AppSwitched {
            previous: None,
            current: app,
            timestamp: Utc::now(),
        };

        match adapt_tracked_event(&event) {
            PerceptionEvent::ForegroundChanged { current, .. } => {
                assert_eq!(current.display_name, "Editor");
                assert_eq!(
                    current.window_title.as_deref(),
                    Some("amadeus-core/src/memory.rs")
                );
                assert_eq!(
                    current.executable_path.as_deref(),
                    Some("/Applications/Editor.app")
                );
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }
}
