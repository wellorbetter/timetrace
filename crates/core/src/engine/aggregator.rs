//! Session aggregator — consumes `TrackedEvent`s and writes to `DataStore`.
//!
//! One session per app activation. Window title changes within the same app
//! are recorded as `page_visits` (no session fragmentation).

use std::sync::Arc;

use chrono::{DateTime, Local, Utc};
use tracing::{debug, info, warn};

use crate::contracts::accounting::{
    CanonicalBatch, CheckpointReason, ProducerCheckpointState, ProductionCheckpoint,
    ProductionCheckpointError,
};
use crate::contracts::events::{AppInfo, EventSink, TrackedEvent};
use crate::contracts::storage::{DataStore, SessionRecord};
use crate::engine::app_identity::normalize_app_name;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointReceipt {
    pub durable_observed_through: DateTime<Utc>,
}

/// Atomic storage operation used by the monitor's successful-observation
/// path. The contract temporarily lives here because this P0 job cannot edit
/// `contracts/storage.rs`; P1 should move it to the storage contract module.
pub trait CheckpointStore: DataStore {
    fn checkpoint_open_interval(
        &self,
        session_id: i64,
        page_id: Option<i64>,
        observed_at: DateTime<Utc>,
    ) -> Result<CheckpointReceipt, String>;
}

pub struct SessionAggregator {
    db: Arc<dyn CheckpointStore>,
    current_session_id: Option<i64>,
    current_app_path: Option<String>,
    current_app_name: Option<String>,
    current_page_id: Option<i64>,
    current_page_title: Option<String>,
    durable_observed_through: Option<DateTime<Utc>>,
}

impl SessionAggregator {
    pub fn new(db: Arc<dyn CheckpointStore>) -> Self {
        Self {
            db,
            current_session_id: None,
            current_app_path: None,
            current_app_name: None,
            current_page_id: None,
            current_page_title: None,
            durable_observed_through: None,
        }
    }

    pub fn db(&self) -> &dyn CheckpointStore {
        &*self.db
    }

    pub fn durable_observed_through(&self) -> Option<DateTime<Utc>> {
        self.durable_observed_through
    }

    pub fn stage_production_checkpoint(
        &self,
        state: &ProducerCheckpointState,
        reason: CheckpointReason,
        boundary: DateTime<Utc>,
        source_identity: impl Into<String>,
        source_revision: i64,
        mut batch: CanonicalBatch,
    ) -> Result<ProductionCheckpoint, ProductionCheckpointError> {
        let first_cutover = matches!(state, ProducerCheckpointState::LegacyPreCutover { .. });
        if first_cutover != (reason == CheckpointReason::FirstCutover) {
            return Err(ProductionCheckpointError::ModeConflict(
                "legacy state requires FirstCutover; canonical state forbids it".to_owned(),
            ));
        }
        batch.observed_through = boundary;
        ProductionCheckpoint::staged(
            reason,
            boundary,
            state.observed_through(),
            source_identity.into(),
            source_revision,
            batch,
            first_cutover,
        )
    }

    fn checkpoint(&mut self, observed_at: DateTime<Utc>) -> bool {
        let Some(session_id) = self.current_session_id else {
            return false;
        };
        match self
            .db
            .checkpoint_open_interval(session_id, self.current_page_id, observed_at)
        {
            Ok(receipt) => {
                self.durable_observed_through = Some(receipt.durable_observed_through);
                true
            }
            Err(error) => {
                warn!("open interval checkpoint failed: {error}");
                false
            }
        }
    }

    fn close_page(&mut self, end_time: DateTime<Utc>) {
        if let Some(pid) = self.current_page_id.take() {
            self.db.close_page_visit(pid, end_time);
        }
        self.current_page_title = None;
    }

    fn close_session(&mut self, end_time: DateTime<Utc>) {
        self.close_page(end_time);
        if let Some(id) = self.current_session_id.take() {
            self.db.close_session(id, end_time);
        }
        self.current_app_path = None;
        self.current_app_name = None;
    }

    fn open_session(&mut self, app: &AppInfo, started_at: DateTime<Utc>) {
        let session = SessionRecord {
            id: 0,
            app_path: app.exe_path.clone(),
            app_name: normalize_app_name(&app.display_name),
            window_title: None,
            started_at,
            ended_at: None,
            duration_secs: None,
            is_idle: app.is_idle(),
            date: started_at.with_timezone(&Local).date_naive(),
        };
        let sid = self.db.insert_session(&session);
        self.current_session_id = Some(sid);
        self.current_app_path = Some(app.exe_path.clone());
        self.current_app_name = Some(app.display_name.clone());
        self.start_page(app, started_at);
    }

    fn start_page(&mut self, app: &AppInfo, started_at: DateTime<Utc>) {
        self.close_page(started_at);
        let sid = self.current_session_id.unwrap_or(-1);
        let pid = self.db.start_page_visit(
            sid,
            &normalize_app_name(&app.display_name),
            app.window_title.as_deref(),
            started_at,
            started_at.with_timezone(&Local).date_naive(),
        );
        self.current_page_id = (pid >= 0).then_some(pid);
        self.current_page_title = app.window_title.clone();
    }
}

impl EventSink for SessionAggregator {
    fn accept(&mut self, event: TrackedEvent) {
        match event {
            TrackedEvent::AppSwitched {
                current, timestamp, ..
            } => {
                // Every successful observation advances the durable boundary.
                // A repeated app/title is a checkpoint, not a new page visit.
                if self.current_app_path.as_deref() == Some(current.exe_path.as_str()) {
                    self.checkpoint(timestamp);
                    if self.current_page_title != current.window_title {
                        debug!(
                            "Page change in {}: {:?}",
                            current.display_name, current.window_title
                        );
                        self.start_page(&current, timestamp);
                    }
                    return;
                }
                // Different app -- close old session, open new at same timestamp.
                debug!("App switched: {}", current.display_name);
                self.close_session(timestamp);
                self.open_session(&current, timestamp);
            }

            TrackedEvent::IdleStarted { timestamp, grace } => {
                info!("Aggregator: IdleStarted - creating __IDLE__ session");
                // The input-threshold grace (or nothing for lock/screensaver)
                // is excluded from the previous app; the idle session starts
                // at the same moment so the trailing grace is never counted.
                let idle_start = timestamp - grace;
                self.close_session(idle_start);
                self.open_session(&AppInfo::idle(), idle_start);
            }

            TrackedEvent::IdleEnded {
                current_app,
                timestamp,
                ..
            } => {
                info!(
                    "Aggregator: IdleEnded - closing idle session, opening {}",
                    current_app.display_name
                );
                self.close_session(timestamp);
                self.open_session(&current_app, timestamp);
            }

            TrackedEvent::GapDetected { timestamp } => {
                info!("Aggregator: GapDetected - closing dangling session at {timestamp}");
                self.close_session(timestamp);
            }
        }
    }
}

impl Drop for SessionAggregator {
    fn drop(&mut self) {
        // A drop is not an observation. Keep the row open at its last durable
        // checkpoint; lifecycle shutdown owns the eventual close/flush fence.
        debug!("SessionAggregator dropped with last checkpoint preserved");
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
        let code = AppInfo::new("C:/chrome.exe".into(), "chrome".into());
        agg.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: code.clone(),
            timestamp: chrono::Utc::now(),
        });

        // User goes idle
        agg.accept(TrackedEvent::IdleStarted {
            timestamp: chrono::Utc::now(),
            grace: std::time::Duration::from_secs(0),
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

        let code = AppInfo::new("C:/chrome.exe".into(), "chrome".into());
        agg.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: code,
            timestamp: chrono::Utc::now(),
        });
        agg.accept(TrackedEvent::IdleStarted {
            timestamp: chrono::Utc::now(),
            grace: std::time::Duration::from_secs(0),
        });
        agg.accept(TrackedEvent::IdleEnded {
            idle_duration: std::time::Duration::from_secs(120),
            current_app: AppInfo::new("C:/chrome.exe".into(), "chrome".into()),
            timestamp: chrono::Utc::now(),
        });

        let today = chrono::Local::now().date_naive();
        let split = db.get_usage_split(today, today);
        assert!(
            split.iter().all(|s| s.app_name != "__IDLE__"),
            "idle must not appear as app row"
        );
    }
    #[test]
    fn test_gap_detected_closes_session_at_gap_time() {
        let db = Arc::new(MemoryStore::new());
        let mut agg = SessionAggregator::new(db.clone());
        let code = AppInfo::new("C:/chrome.exe".into(), "chrome".into());
        let t0 = chrono::DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        agg.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: code,
            timestamp: t0,
        });
        let gap = t0 + chrono::Duration::minutes(20);
        agg.accept(TrackedEvent::GapDetected { timestamp: gap });
        let sessions = db.get_sessions_by_date(t0.date_naive());
        let app = sessions
            .iter()
            .find(|s| s.app_name == "chrome")
            .expect("code session");
        let d = (app.ended_at.expect("closed") - app.started_at).num_seconds();
        assert_eq!(d, 1200, "expected exact 20min session, got {d}s");
    }

    #[test]
    fn test_idle_grace_excluded_from_previous_app() {
        let db = Arc::new(MemoryStore::new());
        let mut agg = SessionAggregator::new(db.clone());
        let code = AppInfo::new("C:/chrome.exe".into(), "chrome".into());
        let t0 = chrono::DateTime::parse_from_rfc3339("2026-01-15T10:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        agg.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: code,
            timestamp: t0,
        });
        agg.accept(TrackedEvent::IdleStarted {
            timestamp: t0 + chrono::Duration::minutes(30),
            grace: std::time::Duration::from_secs(300),
        });
        let sessions = db.get_sessions_by_date(t0.date_naive());
        let app = sessions
            .iter()
            .find(|s| s.app_name == "chrome")
            .expect("code session");
        let d = (app.ended_at.expect("closed") - app.started_at).num_seconds();
        assert_eq!(d, 1500, "expected exact 25min grace exclusion, got {d}s");
        assert!(
            sessions.iter().any(|s| s.is_idle && s.ended_at.is_none()),
            "idle session should still be open"
        );
    }

    #[test]
    fn production_staging_is_pure_deterministic_and_mode_checked() {
        let db = Arc::new(MemoryStore::new());
        let agg = SessionAggregator::new(db);
        let boundary = chrono::DateTime::parse_from_rfc3339("2026-01-15T10:10:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let start = boundary - chrono::Duration::minutes(10);
        let state = ProducerCheckpointState::LegacyPreCutover {
            legacy_observed_through: None,
        };
        let batch = CanonicalBatch {
            intervals: vec![crate::contracts::accounting::AccountingInterval {
                range: crate::contracts::accounting::UtcInterval::new(start, boundary).unwrap(),
                state: crate::contracts::accounting::AccountingState::Active,
                attribution: crate::contracts::accounting::AttributionIdentity {
                    app_id: Some("fixture-app".into()),
                    ..Default::default()
                },
                source_identity: "monitor:fixture".into(),
                source_revision: 1,
            }],
            observed_through: start,
        };

        let first = agg
            .stage_production_checkpoint(
                &state,
                CheckpointReason::FirstCutover,
                boundary,
                "producer:fixture",
                1,
                batch.clone(),
            )
            .unwrap();
        let second = agg
            .stage_production_checkpoint(
                &state,
                CheckpointReason::FirstCutover,
                boundary,
                "producer:fixture",
                1,
                batch.clone(),
            )
            .unwrap();
        assert_eq!(first, second);
        assert_eq!(first.batch.observed_through, boundary);
        assert_eq!(agg.durable_observed_through(), None);
        assert!(matches!(
            agg.stage_production_checkpoint(
                &state,
                CheckpointReason::Heartbeat,
                boundary,
                "producer:fixture",
                1,
                batch,
            ),
            Err(ProductionCheckpointError::ModeConflict(_))
        ));
    }
}
