//! Session aggregator — consumes `TrackedEvent`s and writes to `DataStore`.
//!
//! This is the bridge between the monitor thread and persistent storage.
//! It tracks the current active session in memory and flushes to SQLite
//! on session boundaries.

use std::sync::Arc;

use chrono::Utc;
use tracing::debug;

use crate::contracts::events::{EventSink, TrackedEvent};
use crate::contracts::storage::{DataStore, SessionRecord};

pub struct SessionAggregator {
    db: Arc<dyn DataStore>,
    /// ID of the currently open session in the database (None if no active session).
    current_session_id: Option<i64>,
    /// App name of the current session (for heartbeat updates).
    current_app_name: Option<String>,
}

impl SessionAggregator {
    pub fn new(db: Arc<dyn DataStore>) -> Self {
        Self {
            db,
            current_session_id: None,
            current_app_name: None,
        }
    }

    /// Close any pending active session on shutdown.
    pub fn flush(&mut self) {
        if let Some(id) = self.current_session_id.take() {
            self.db.close_session(id, Utc::now());
            self.current_app_name = None;
        }
    }

    fn close_current(&mut self) {
        if let Some(id) = self.current_session_id.take() {
            self.db.close_session(id, Utc::now());
            self.current_app_name = None;
        }
    }

    fn start_session(&mut self, app: &crate::contracts::events::AppInfo) {
        let now = Utc::now();
        let session = SessionRecord {
            id: 0, // will be assigned by DB
            app_path: app.exe_path.clone(),
            app_name: app.display_name.clone(),
            window_title: app.window_title.clone(),
            started_at: now,
            ended_at: None,
            duration_secs: None,
            is_idle: app.is_idle(),
            date: now.date_naive(),
        };
        let id = self.db.insert_session(&session);
        self.current_session_id = Some(id);
        self.current_app_name = Some(app.display_name.clone());
    }
}

impl EventSink for SessionAggregator {
    fn accept(&mut self, event: TrackedEvent) {
        match event {
            TrackedEvent::AppSwitched { previous, current, .. } => {
                debug!("App switched: {:?} → {}", previous.as_ref().map(|a| &a.display_name), current.display_name);
                self.close_current();
                self.start_session(&current);
            }

            TrackedEvent::IdleStarted { .. } => {
                debug!("Idle started");
                self.close_current();
            }

            TrackedEvent::IdleEnded { current_app, .. } => {
                debug!("Idle ended, resuming: {}", current_app.display_name);
                self.start_session(&current_app);
            }

            TrackedEvent::Heartbeat { .. } => {
                // Heartbeat doesn't change session state.
                // The TUI reads the active session directly from DataStore.
            }
        }
    }
}

impl Drop for SessionAggregator {
    fn drop(&mut self) {
        self.flush();
    }
}
