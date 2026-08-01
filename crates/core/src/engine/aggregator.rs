//! Session aggregator — consumes `TrackedEvent`s and writes to `DataStore`.
//!
//! One session per app activation. Window title changes within the same app
//! are recorded as `page_visits` (no session fragmentation).

use std::sync::Arc;

use chrono::{Local, Utc};
use tracing::debug;

use crate::contracts::events::{AppInfo, EventSink, TrackedEvent};
use crate::contracts::storage::{DataStore, SessionRecord};

pub struct SessionAggregator {
    db: Arc<dyn DataStore>,
    current_session_id: Option<i64>,
    current_app_path: Option<String>,
    current_app_name: Option<String>,
    current_page_id: Option<i64>,
}

impl SessionAggregator {
    pub fn new(db: Arc<dyn DataStore>) -> Self {
        Self { db, current_session_id: None, current_app_path: None, current_app_name: None, current_page_id: None }
    }

    pub fn db(&self) -> &dyn DataStore { &*self.db }

    fn close_page(&mut self) {
        if let Some(pid) = self.current_page_id.take() {
            self.db.close_page_visit(pid, Utc::now());
        }
    }

    fn close_session(&mut self) {
        self.close_page();
        if let Some(id) = self.current_session_id.take() {
            self.db.close_session(id, Utc::now());
        }
        self.current_app_path = None;
        self.current_app_name = None;
    }

    fn open_session(&mut self, app: &AppInfo) {
        let now = Utc::now();
        let session = SessionRecord {
            id: 0,
            app_path: app.exe_path.clone(),
            app_name: app.display_name.clone(),
            window_title: None,
            started_at: now,
            ended_at: None,
            duration_secs: None,
            is_idle: app.is_idle(),
            date: Local::now().date_naive(),
        };
        let sid = self.db.insert_session(&session);
        self.current_session_id = Some(sid);
        self.current_app_path = Some(app.exe_path.clone());
        self.current_app_name = Some(app.display_name.clone());
        self.start_page(app);
    }

    fn start_page(&mut self, app: &AppInfo) {
        self.close_page();
        let sid = self.current_session_id.unwrap_or(-1);
        let pid = self.db.start_page_visit(
            sid,
            &app.display_name,
            app.window_title.as_deref(),
            Local::now().date_naive(),
        );
        self.current_page_id = Some(pid);
    }
}

impl EventSink for SessionAggregator {
    fn accept(&mut self, event: TrackedEvent) {
        match event {
            TrackedEvent::AppSwitched { current, .. } => {
                // Same app (exe)? Just a page change — record page visit.
                if self.current_app_path.as_deref() == Some(current.exe_path.as_str()) {
                    debug!("Page change in {}: {:?}", current.display_name, current.window_title);
                    self.start_page(&current);
                    return;
                }
                // Different app — close old session, open new.
                debug!("App switched: {}", current.display_name);
                self.close_session();
                self.open_session(&current);
            }

            TrackedEvent::IdleStarted { .. } => {
                debug!("Idle started");
                self.close_session();
            }

            TrackedEvent::IdleEnded { current_app, .. } => {
                debug!("Idle ended: {}", current_app.display_name);
                self.open_session(&current_app);
            }

            TrackedEvent::Heartbeat { .. } => {}
        }
    }
}

impl Drop for SessionAggregator {
    fn drop(&mut self) {
        self.close_session();
    }
}
