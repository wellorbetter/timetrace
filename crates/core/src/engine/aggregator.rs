//! Session aggregator — consumes `TrackedEvent`s and writes to `DataStore`.
//!
//! One session per app activation. Window title changes within the same app
//! are recorded as `page_visits` (no session fragmentation).

use std::sync::Arc;

use chrono::{Local, Utc};
use tracing::{debug, info};

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
                info!("Aggregator: IdleStarted — creating __IDLE__ session");
                // Close the active session and open an IDLE session.
                self.close_session();
                self.open_session(&AppInfo::idle());
            }

            TrackedEvent::IdleEnded { idle_duration, current_app, .. } => {
                info!("Aggregator: IdleEnded — closing idle session, opening {}", current_app.display_name);
                // Close the idle session (records idle time), then open the app.
                self.close_session();
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::events::AppInfo;
    use crate::storage::sqlite::MemoryStore;

    #[test]
    fn test_idle_session_recorded() {
        let db = Arc::new(MemoryStore::new());
        let mut agg = SessionAggregator::new(db.clone());

        // App session starts
        let code = AppInfo::new("C:/code.exe".into(), "code".into());
        agg.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: code.clone(),
            timestamp: chrono::Utc::now(),
        });

        // User goes idle
        agg.accept(TrackedEvent::IdleStarted {
            timestamp: chrono::Utc::now(),
        });

        // User returns after 300s
        let idle_dur = std::time::Duration::from_secs(300);
        agg.accept(TrackedEvent::IdleEnded {
            idle_duration: idle_dur,
            current_app: code.clone(),
            timestamp: chrono::Utc::now(),
        });

        // An idle session must exist with is_idle = true
        let sessions = db.get_sessions_by_date(chrono::Local::now().date_naive());
        let idle_sessions: Vec<_> = sessions.iter().filter(|s| s.is_idle).collect();
        assert!(!idle_sessions.is_empty(), "no idle session recorded");
        assert_eq!(idle_sessions[0].app_name, "__IDLE__");
    }

    #[test]
    fn test_usage_split_excludes_idle_app_row() {
        let db = Arc::new(MemoryStore::new());
        let mut agg = SessionAggregator::new(db.clone());

        let code = AppInfo::new("C:/code.exe".into(), "code".into());
        agg.accept(TrackedEvent::AppSwitched { previous: None, current: code, timestamp: chrono::Utc::now() });
        agg.accept(TrackedEvent::IdleStarted { timestamp: chrono::Utc::now() });
        agg.accept(TrackedEvent::IdleEnded {
            idle_duration: std::time::Duration::from_secs(120),
            current_app: AppInfo::new("C:/code.exe".into(), "code".into()),
            timestamp: chrono::Utc::now(),
        });

        let today = chrono::Local::now().date_naive();
        let split = db.get_usage_split(today, today);
        assert!(split.iter().all(|s| s.app_name != "__IDLE__"), "idle must not appear as app row");
    }
}
