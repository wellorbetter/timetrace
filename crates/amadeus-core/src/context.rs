use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::identity::IdentityMemory;
use crate::memory::{ComputerEpisode, LivedMemoryStore, MemoryError};
use crate::perception::ComputerActivity;
use crate::persona::PersonaState;
use crate::retrieval::{MemoryHit, MemoryQuery, MemoryRetriever};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkingContext {
    pub current_activity: Option<ComputerActivity>,
    pub active_since: Option<DateTime<Utc>>,
    pub last_event_at: Option<DateTime<Utc>>,
}

impl WorkingContext {
    pub fn on_foreground(&mut self, activity: ComputerActivity, at: DateTime<Utc>) {
        if self.current_activity.is_none() {
            self.active_since = Some(at);
        }
        self.current_activity = Some(activity);
        self.last_event_at = Some(at);
    }

    pub fn on_idle_or_gap(&mut self, at: DateTime<Utc>) {
        self.current_activity = None;
        self.active_since = None;
        self.last_event_at = Some(at);
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PersonaStateSnapshot {
    pub familiarity: f32,
    pub engagement: f32,
    pub curiosity: f32,
    pub concern: f32,
    pub annoyance: f32,
}

impl From<&PersonaState> for PersonaStateSnapshot {
    fn from(state: &PersonaState) -> Self {
        Self {
            familiarity: state.familiarity(),
            engagement: state.engagement(),
            curiosity: state.curiosity(),
            concern: state.concern(),
            annoyance: state.annoyance(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentContext {
    pub persona_id: String,
    pub display_name: String,
    pub canonical_memories: Vec<String>,
    pub persona_state: PersonaStateSnapshot,
    pub working: WorkingContext,
    pub recent_episodes: Vec<ComputerEpisode>,
    pub relevant_memories: Vec<MemoryHit>,
}

impl AgentContext {
    pub fn render_for_model(&self) -> String {
        let mut lines = vec![
            format!("Persona: {} ({})", self.display_name, self.persona_id),
            "Canonical self memory (pre-activation; protected):".into(),
        ];
        if self.canonical_memories.is_empty() {
            lines.push("- none loaded".into());
        } else {
            lines.extend(self.canonical_memories.iter().map(|memory| format!("- {memory}")));
        }

        lines.push("Post-activation persona state:".into());
        lines.push(format!(
            "- familiarity={:.2}, engagement={:.2}, curiosity={:.2}, concern={:.2}, annoyance={:.2}",
            self.persona_state.familiarity,
            self.persona_state.engagement,
            self.persona_state.curiosity,
            self.persona_state.concern,
            self.persona_state.annoyance,
        ));

        lines.push("Working computer context:".into());
        if let Some(activity) = &self.working.current_activity {
            lines.push(format!(
                "- current app: {}{}",
                activity.display_name,
                activity
                    .window_title
                    .as_deref()
                    .map(|title| format!(" · {title}"))
                    .unwrap_or_default()
            ));
        } else {
            lines.push("- no active foreground context".into());
        }

        lines.push("Relevant lived memories (post-activation):".into());
        if self.relevant_memories.is_empty() {
            lines.push("- none".into());
        } else {
            lines.extend(self.relevant_memories.iter().map(|hit| {
                format!("- [{:.2}] {}", hit.score, hit.memory.content)
            }));
        }

        lines.push("Recent computer episodes:".into());
        for episode in &self.recent_episodes {
            lines.push(format!(
                "- {} → {} · {}",
                episode.started_at.to_rfc3339(),
                episode.ended_at.to_rfc3339(),
                episode.app_names().join(", ")
            ));
        }
        lines.join("\n")
    }
}

#[derive(Debug, Clone)]
pub struct ContextComposer {
    retriever: MemoryRetriever,
    canonical_limit: usize,
    episode_limit: usize,
}

impl Default for ContextComposer {
    fn default() -> Self {
        Self {
            retriever: MemoryRetriever::default(),
            canonical_limit: 12,
            episode_limit: 6,
        }
    }
}

impl ContextComposer {
    pub fn compose<S: LivedMemoryStore>(
        &self,
        identity: &IdentityMemory,
        persona_state: &PersonaState,
        working: &WorkingContext,
        store: &S,
        query: &str,
        now: DateTime<Utc>,
    ) -> Result<AgentContext, MemoryError> {
        let canonical_memories = identity
            .canonical()
            .iter()
            .take(self.canonical_limit)
            .map(|memory| memory.content().to_owned())
            .collect();
        let relevant_memories = self.retriever.search(
            store,
            &MemoryQuery {
                text: query.to_owned(),
                limit: 8,
                ..MemoryQuery::default()
            },
            now,
        )?;
        let recent_episodes = store.recent_episodes(self.episode_limit)?;

        Ok(AgentContext {
            persona_id: identity.persona_id().to_owned(),
            display_name: identity.display_name().to_owned(),
            canonical_memories,
            persona_state: PersonaStateSnapshot::from(persona_state),
            working: working.clone(),
            recent_episodes,
            relevant_memories,
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;

    use super::*;
    use crate::identity::CanonicalMemory;
    use crate::memory::{LivedMemory, LivedMemoryKind, LivedMemorySource, SqliteLivedMemoryStore};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn context_keeps_canonical_and_lived_memory_visibly_separate() {
        let identity = IdentityMemory::from_persona_pack(
            "scientist",
            "Scientist",
            None,
            vec![CanonicalMemory::new("origin", "I value evidence.", vec![], None)],
        );
        let mut store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        store
            .append_memory(&LivedMemory {
                kind: LivedMemoryKind::Relationship,
                source: LivedMemorySource::Conversation,
                content: "We built the memory core together.".into(),
                salience: 0.9,
                created_at: at(90),
            })
            .unwrap();
        let context = ContextComposer::default()
            .compose(
                &identity,
                &PersonaState::default(),
                &WorkingContext::default(),
                &store,
                "memory core",
                at(100),
            )
            .unwrap();
        let rendered = context.render_for_model();
        assert!(rendered.contains("Canonical self memory"));
        assert!(rendered.contains("I value evidence"));
        assert!(rendered.contains("Relevant lived memories"));
        assert!(rendered.contains("built the memory core together"));
    }
}
