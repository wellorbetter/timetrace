//! Process-local live activity snapshot for lightweight desktop surfaces.
//!
//! The generated Flutter bridge is intentionally kept out of this hot path.
//! The monitor writes a tiny bounded snapshot in memory and Flutter reads it
//! through two stable C ABI symbols. Nothing is persisted or sent over the
//! network by this module.

use std::collections::VecDeque;
use std::ffi::{CString, c_char};
use std::sync::{Mutex, OnceLock};

use chrono::{DateTime, Utc};
use timetrace_core::{AppInfo, EventSink, SessionAggregator, TrackedEvent};

const HISTORY_LIMIT: usize = 12;

static LIVE_ACTIVITY: OnceLock<Mutex<LiveActivityState>> = OnceLock::new();

fn shared_state() -> &'static Mutex<LiveActivityState> {
    LIVE_ACTIVITY.get_or_init(|| Mutex::new(LiveActivityState::default()))
}

#[derive(Debug, Clone)]
struct LiveEpisode {
    sequence: u64,
    app_path: String,
    app_name: String,
    window_title: Option<String>,
    started_at: DateTime<Utc>,
    ended_at: Option<DateTime<Utc>>,
    is_idle: bool,
}

impl LiveEpisode {
    fn from_app(sequence: u64, app: &AppInfo, started_at: DateTime<Utc>) -> Self {
        Self {
            sequence,
            app_path: app.exe_path.clone(),
            app_name: app.display_name.clone(),
            window_title: app.window_title.clone(),
            started_at,
            ended_at: None,
            is_idle: app.is_idle(),
        }
    }

    fn push_json(&self, out: &mut String) {
        out.push('{');
        out.push_str("\"sequence\":");
        out.push_str(&self.sequence.to_string());
        out.push_str(",\"app_name\":");
        push_json_string(out, &self.app_name);
        out.push_str(",\"window_title\":");
        match self.window_title.as_deref() {
            Some(value) => push_json_string(out, value),
            None => out.push_str("null"),
        }
        out.push_str(",\"started_at\":");
        push_json_string(out, &self.started_at.to_rfc3339());
        out.push_str(",\"ended_at\":");
        match self.ended_at {
            Some(value) => push_json_string(out, &value.to_rfc3339()),
            None => out.push_str("null"),
        }
        out.push_str(",\"is_idle\":");
        out.push_str(if self.is_idle { "true" } else { "false" });
        out.push('}');
    }
}

#[derive(Debug, Default)]
struct LiveActivityState {
    revision: u64,
    paused: bool,
    current: Option<LiveEpisode>,
    history: VecDeque<LiveEpisode>,
}

impl LiveActivityState {
    fn reset(&mut self, paused: bool) {
        *self = Self {
            paused,
            ..Self::default()
        };
        self.bump();
    }

    fn observe(&mut self, event: &TrackedEvent) {
        match event {
            TrackedEvent::AppSwitched {
                current, timestamp, ..
            } => {
                // The overlay itself may briefly become foreground while the
                // user positions it. Close the previous episode, but never
                // create a useless self-referential "using TimeTrace" line.
                if is_timetrace(current) {
                    self.finish_current(*timestamp);
                    return;
                }

                if let Some(active) = self.current.as_mut() {
                    if !active.is_idle && active.app_path == current.exe_path {
                        active.app_name = current.display_name.clone();
                        active.window_title = current.window_title.clone();
                        self.bump();
                        return;
                    }
                }

                self.finish_current(*timestamp);
                self.start(current, *timestamp);
            }
            TrackedEvent::IdleStarted { timestamp, grace } => {
                let idle_start =
                    *timestamp - chrono::Duration::from_std(*grace).unwrap_or_default();
                self.finish_current(idle_start);
                self.start(&AppInfo::idle(), idle_start);
            }
            TrackedEvent::IdleEnded {
                current_app,
                timestamp,
                ..
            } => {
                self.finish_current(*timestamp);
                self.start(current_app, *timestamp);
            }
            TrackedEvent::GapDetected { timestamp } => {
                self.finish_current(*timestamp);
            }
        }
    }

    fn start(&mut self, app: &AppInfo, timestamp: DateTime<Utc>) {
        self.revision = self.revision.wrapping_add(1);
        self.current = Some(LiveEpisode::from_app(self.revision, app, timestamp));
    }

    fn finish_current(&mut self, timestamp: DateTime<Utc>) {
        let Some(mut episode) = self.current.take() else {
            return;
        };
        episode.ended_at = Some(timestamp.max(episode.started_at));
        self.history.push_back(episode);
        while self.history.len() > HISTORY_LIMIT {
            self.history.pop_front();
        }
        self.bump();
    }

    fn set_paused(&mut self, paused: bool) {
        if self.paused == paused {
            return;
        }
        self.paused = paused;
        if paused {
            self.finish_current(Utc::now());
        }
        self.bump();
    }

    fn bump(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }

    fn to_json(&self) -> String {
        let mut out = String::with_capacity(1024);
        out.push_str("{\"version\":1,\"revision\":");
        out.push_str(&self.revision.to_string());
        out.push_str(",\"paused\":");
        out.push_str(if self.paused { "true" } else { "false" });
        out.push_str(",\"current\":");
        match self.current.as_ref() {
            Some(value) => value.push_json(&mut out),
            None => out.push_str("null"),
        }
        out.push_str(",\"history\":[");
        for (index, episode) in self.history.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            episode.push_json(&mut out);
        }
        out.push_str("]}");
        out
    }
}

/// Wraps the existing persistence sink with a bounded process-local view.
pub(crate) struct LiveActivitySink {
    inner: SessionAggregator,
}

impl LiveActivitySink {
    pub(crate) fn new(inner: SessionAggregator) -> Self {
        Self { inner }
    }
}

impl EventSink for LiveActivitySink {
    fn accept(&mut self, event: TrackedEvent) {
        if let Ok(mut state) = shared_state().lock() {
            state.observe(&event);
        }
        self.inner.accept(event);
    }
}

pub(crate) fn reset(paused: bool) {
    if let Ok(mut state) = shared_state().lock() {
        state.reset(paused);
    }
}

pub(crate) fn set_paused(paused: bool) {
    if let Ok(mut state) = shared_state().lock() {
        state.set_paused(paused);
    }
}

fn snapshot_json() -> String {
    shared_state()
        .lock()
        .map(|state| state.to_json())
        .unwrap_or_else(|_| {
            "{\"version\":1,\"revision\":0,\"paused\":false,\"current\":null,\"history\":[]}".into()
        })
}

/// Returns a newly allocated UTF-8 JSON snapshot. The caller must release it
/// with [`timetrace_live_activity_json_free`].
#[unsafe(no_mangle)]
pub extern "C" fn timetrace_live_activity_json() -> *mut c_char {
    CString::new(snapshot_json())
        .unwrap_or_else(|_| CString::new("{}").expect("static JSON has no NUL"))
        .into_raw()
}

/// Releases a pointer returned by [`timetrace_live_activity_json`].
///
/// # Safety
/// `pointer` must be null or a pointer returned by that function exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timetrace_live_activity_json_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}

fn is_timetrace(app: &AppInfo) -> bool {
    let executable = app
        .exe_path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or_default()
        .trim_end_matches(".exe")
        .to_ascii_lowercase();
    app.display_name.eq_ignore_ascii_case("TimeTrace")
        || executable == "timetrace"
        || executable == "timetrace_app"
}

fn push_json_string(out: &mut String, value: &str) {
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            value if value <= '\u{1F}' => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", value as u32);
            }
            value => out.push(value),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(path: &str, name: &str, title: &str) -> AppInfo {
        AppInfo::new(path.into(), name.into()).with_title(title.into())
    }

    #[test]
    fn groups_title_changes_inside_one_application_episode() {
        let start = Utc::now();
        let mut state = LiveActivityState::default();
        state.observe(&TrackedEvent::AppSwitched {
            previous: None,
            current: app("/code", "Code", "one.dart"),
            timestamp: start,
        });
        let sequence = state.current.as_ref().unwrap().sequence;
        state.observe(&TrackedEvent::AppSwitched {
            previous: None,
            current: app("/code", "Code", "two.dart"),
            timestamp: start + chrono::Duration::seconds(5),
        });

        assert!(state.history.is_empty());
        let current = state.current.as_ref().unwrap();
        assert_eq!(current.sequence, sequence);
        assert_eq!(current.window_title.as_deref(), Some("two.dart"));
    }

    #[test]
    fn keeps_a_bounded_oldest_to_newest_history() {
        let start = Utc::now();
        let mut state = LiveActivityState::default();
        for index in 0..HISTORY_LIMIT + 3 {
            state.observe(&TrackedEvent::AppSwitched {
                previous: None,
                current: app(&format!("/app-{index}"), &format!("App {index}"), "title"),
                timestamp: start + chrono::Duration::seconds(index as i64),
            });
        }

        assert_eq!(state.history.len(), HISTORY_LIMIT);
        assert_eq!(state.history.front().unwrap().app_name, "App 2");
        assert_eq!(state.current.as_ref().unwrap().app_name, "App 14");
    }

    #[test]
    fn pause_closes_current_and_json_escapes_titles() {
        let mut state = LiveActivityState::default();
        state.observe(&TrackedEvent::AppSwitched {
            previous: None,
            current: app("/browser", "Browser", "A \"quoted\"\\title\n"),
            timestamp: Utc::now(),
        });
        state.set_paused(true);

        assert!(state.current.is_none());
        assert!(state.paused);
        let json = state.to_json();
        assert!(json.contains("A \\\"quoted\\\"\\\\title\\n"));
        assert!(json.contains("\"paused\":true"));
    }

    #[test]
    fn ignores_timetrace_as_a_live_caption_subject() {
        let start = Utc::now();
        let mut state = LiveActivityState::default();
        state.observe(&TrackedEvent::AppSwitched {
            previous: None,
            current: app("/browser", "Browser", "Reading"),
            timestamp: start,
        });
        state.observe(&TrackedEvent::AppSwitched {
            previous: None,
            current: app("/apps/timetrace_app", "TimeTrace", "Nowline"),
            timestamp: start + chrono::Duration::seconds(1),
        });

        assert!(state.current.is_none());
        assert_eq!(state.history.back().unwrap().app_name, "Browser");
    }
}
