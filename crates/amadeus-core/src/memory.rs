use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::perception::{ComputerActivity, PerceptionEvent};

#[derive(Debug, Error)]
pub enum MemoryError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("serialization: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("timestamp: {0}")]
    Timestamp(#[from] chrono::ParseError),
}

/// One contiguous foreground span inside a larger computer episode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivitySpan {
    pub activity: ComputerActivity,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
}

/// A lived computer episode.
///
/// Multiple app/window switches stay inside one episode. Idle/gap boundaries
/// finish it. Semantic summarization, project inference and reflection happen
/// later; raw window switches never become long-term memories directly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComputerEpisode {
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub spans: Vec<ActivitySpan>,
}

impl ComputerEpisode {
    pub fn duration(&self) -> Duration {
        self.ended_at - self.started_at
    }

    pub fn app_names(&self) -> Vec<&str> {
        let mut names = Vec::new();
        for span in &self.spans {
            if !names.contains(&span.activity.display_name.as_str()) {
                names.push(span.activity.display_name.as_str());
            }
        }
        names
    }
}

#[derive(Debug)]
struct OpenEpisode {
    started_at: DateTime<Utc>,
    current_activity: ComputerActivity,
    current_started_at: DateTime<Utc>,
    spans: Vec<ActivitySpan>,
}

/// Converts perception events into human-scale computer episodes.
#[derive(Debug, Default)]
pub struct EpisodeBuilder {
    open: Option<OpenEpisode>,
}

impl EpisodeBuilder {
    pub fn ingest(&mut self, event: PerceptionEvent) -> Option<ComputerEpisode> {
        match event {
            PerceptionEvent::ForegroundChanged { current, at, .. } => {
                if let Some(open) = self.open.as_mut() {
                    Self::close_current_span(open, at);
                    open.current_activity = current;
                    open.current_started_at = at;
                } else {
                    self.open = Some(OpenEpisode {
                        started_at: at,
                        current_activity: current,
                        current_started_at: at,
                        spans: Vec::new(),
                    });
                }
                None
            }
            PerceptionEvent::IdleStarted { at, grace_ms } => {
                let grace = Duration::milliseconds(grace_ms.min(i64::MAX as u64) as i64);
                self.finish(at - grace)
            }
            PerceptionEvent::GapDetected { at } => self.finish(at),
            PerceptionEvent::IdleEnded { current, at } => {
                let previous = self.finish(at);
                self.open = Some(OpenEpisode {
                    started_at: at,
                    current_activity: current,
                    current_started_at: at,
                    spans: Vec::new(),
                });
                previous
            }
        }
    }

    pub fn flush(&mut self, at: DateTime<Utc>) -> Option<ComputerEpisode> {
        self.finish(at)
    }

    fn finish(&mut self, ended_at: DateTime<Utc>) -> Option<ComputerEpisode> {
        let mut open = self.open.take()?;
        let effective_end = ended_at.max(open.started_at);
        Self::close_current_span(&mut open, effective_end);
        if open.spans.is_empty() {
            return None;
        }
        Some(ComputerEpisode {
            started_at: open.started_at,
            ended_at: effective_end,
            spans: open.spans,
        })
    }

    fn close_current_span(open: &mut OpenEpisode, at: DateTime<Utc>) {
        let end = at.max(open.current_started_at);
        if end <= open.current_started_at {
            return;
        }
        open.spans.push(ActivitySpan {
            activity: open.current_activity.clone(),
            started_at: open.current_started_at,
            ended_at: end,
        });
    }
}

/// Runtime-written memory categories. Canonical/self memory does not appear in
/// this enum on purpose: identity has a separate protected storage path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LivedMemoryKind {
    Conversation,
    Relationship,
    ProjectFact,
    Preference,
    Reflection,
}

impl LivedMemoryKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Conversation => "conversation",
            Self::Relationship => "relationship",
            Self::ProjectFact => "project_fact",
            Self::Preference => "preference",
            Self::Reflection => "reflection",
        }
    }

    fn from_str(value: &str) -> Self {
        match value {
            "relationship" => Self::Relationship,
            "project_fact" => Self::ProjectFact,
            "preference" => Self::Preference,
            "reflection" => Self::Reflection,
            _ => Self::Conversation,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LivedMemorySource {
    Conversation,
    Computer,
    Skill,
    Trigger,
    Reflection,
}

impl LivedMemorySource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Conversation => "conversation",
            Self::Computer => "computer",
            Self::Skill => "skill",
            Self::Trigger => "trigger",
            Self::Reflection => "reflection",
        }
    }

    fn from_str(value: &str) -> Self {
        match value {
            "computer" => Self::Computer,
            "skill" => Self::Skill,
            "trigger" => Self::Trigger,
            "reflection" => Self::Reflection,
            _ => Self::Conversation,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LivedMemory {
    pub kind: LivedMemoryKind,
    pub source: LivedMemorySource,
    pub content: String,
    pub salience: f32,
    pub created_at: DateTime<Utc>,
}

pub trait LivedMemoryStore {
    fn append_episode(&mut self, episode: &ComputerEpisode) -> Result<i64, MemoryError>;
    fn recent_episodes(&self, limit: usize) -> Result<Vec<ComputerEpisode>, MemoryError>;
    fn append_memory(&mut self, memory: &LivedMemory) -> Result<i64, MemoryError>;
    fn recent_memories(&self, limit: usize) -> Result<Vec<LivedMemory>, MemoryError>;
}

/// SQLite persistence owned by Amadeus, independent from TimeTrace storage.
pub struct SqliteLivedMemoryStore {
    conn: Connection,
}

impl SqliteLivedMemoryStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, MemoryError> {
        let conn = Connection::open(path)?;
        let store = Self { conn };
        store.ensure_schema()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, MemoryError> {
        let conn = Connection::open_in_memory()?;
        let store = Self { conn };
        store.ensure_schema()?;
        Ok(store)
    }

    fn ensure_schema(&self) -> Result<(), MemoryError> {
        self.conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS computer_episodes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_computer_episodes_started
                ON computer_episodes(started_at DESC);

            CREATE TABLE IF NOT EXISTS lived_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                source TEXT NOT NULL,
                content TEXT NOT NULL,
                salience REAL NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lived_memories_created
                ON lived_memories(created_at DESC);
            ",
        )?;
        Ok(())
    }
}

impl LivedMemoryStore for SqliteLivedMemoryStore {
    fn append_episode(&mut self, episode: &ComputerEpisode) -> Result<i64, MemoryError> {
        let payload = serde_json::to_string(episode)?;
        self.conn.execute(
            "INSERT INTO computer_episodes(started_at, ended_at, payload_json) VALUES (?1, ?2, ?3)",
            params![episode.started_at.to_rfc3339(), episode.ended_at.to_rfc3339(), payload],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    fn recent_episodes(&self, limit: usize) -> Result<Vec<ComputerEpisode>, MemoryError> {
        let mut statement = self.conn.prepare(
            "SELECT payload_json FROM computer_episodes ORDER BY started_at DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], |row| row.get::<_, String>(0))?;
        let mut episodes = Vec::new();
        for row in rows {
            episodes.push(serde_json::from_str(&row?)?);
        }
        Ok(episodes)
    }

    fn append_memory(&mut self, memory: &LivedMemory) -> Result<i64, MemoryError> {
        self.conn.execute(
            "INSERT INTO lived_memories(kind, source, content, salience, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                memory.kind.as_str(),
                memory.source.as_str(),
                &memory.content,
                memory.salience,
                memory.created_at.to_rfc3339(),
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    fn recent_memories(&self, limit: usize) -> Result<Vec<LivedMemory>, MemoryError> {
        let mut statement = self.conn.prepare(
            "SELECT kind, source, content, salience, created_at
             FROM lived_memories ORDER BY created_at DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], |row| {
            let kind: String = row.get(0)?;
            let source: String = row.get(1)?;
            let content: String = row.get(2)?;
            let salience: f32 = row.get(3)?;
            let created_at: String = row.get(4)?;
            Ok((kind, source, content, salience, created_at))
        })?;

        let mut memories = Vec::new();
        for row in rows {
            let (kind, source, content, salience, created_at) = row?;
            let created_at = DateTime::parse_from_rfc3339(&created_at)?.with_timezone(&Utc);
            memories.push(LivedMemory {
                kind: LivedMemoryKind::from_str(&kind),
                source: LivedMemorySource::from_str(&source),
                content,
                salience,
                created_at,
            });
        }
        Ok(memories)
    }
}

/// Coordinates perception-to-episode persistence.
pub struct MemoryCore<S: LivedMemoryStore> {
    store: S,
    episode_builder: EpisodeBuilder,
}

impl<S: LivedMemoryStore> MemoryCore<S> {
    pub fn new(store: S) -> Self {
        Self {
            store,
            episode_builder: EpisodeBuilder::default(),
        }
    }

    pub fn ingest(&mut self, event: PerceptionEvent) -> Result<Option<i64>, MemoryError> {
        let episode = self.episode_builder.ingest(event);
        episode
            .as_ref()
            .map(|episode| self.store.append_episode(episode))
            .transpose()
    }

    pub fn flush(&mut self, at: DateTime<Utc>) -> Result<Option<i64>, MemoryError> {
        let episode = self.episode_builder.flush(at);
        episode
            .as_ref()
            .map(|episode| self.store.append_episode(episode))
            .transpose()
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut S {
        &mut self.store
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    fn activity(name: &str) -> ComputerActivity {
        ComputerActivity::new(name.to_lowercase(), name)
    }

    #[test]
    fn builder_groups_app_switches_until_an_idle_boundary() {
        let mut builder = EpisodeBuilder::default();
        assert!(builder
            .ingest(PerceptionEvent::ForegroundChanged {
                previous: None,
                current: activity("Editor"),
                at: at(100),
            })
            .is_none());
        assert!(builder
            .ingest(PerceptionEvent::ForegroundChanged {
                previous: Some(activity("Editor")),
                current: activity("Browser"),
                at: at(160),
            })
            .is_none());

        let episode = builder
            .ingest(PerceptionEvent::IdleStarted {
                at: at(220),
                grace_ms: 0,
            })
            .unwrap();

        assert_eq!(episode.started_at, at(100));
        assert_eq!(episode.ended_at, at(220));
        assert_eq!(episode.spans.len(), 2);
        assert_eq!(episode.app_names(), vec!["Editor", "Browser"]);
    }

    #[test]
    fn sqlite_round_trips_lived_memory_and_computer_episode() {
        let mut store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let episode = ComputerEpisode {
            started_at: at(100),
            ended_at: at(160),
            spans: vec![ActivitySpan {
                activity: activity("Editor"),
                started_at: at(100),
                ended_at: at(160),
            }],
        };
        store.append_episode(&episode).unwrap();
        assert_eq!(store.recent_episodes(1).unwrap(), vec![episode]);

        let memory = LivedMemory {
            kind: LivedMemoryKind::Relationship,
            source: LivedMemorySource::Conversation,
            content: "We decided that identity and lived memory must remain separate.".into(),
            salience: 0.9,
            created_at: at(200),
        };
        store.append_memory(&memory).unwrap();
        assert_eq!(store.recent_memories(1).unwrap(), vec![memory]);
    }
}
