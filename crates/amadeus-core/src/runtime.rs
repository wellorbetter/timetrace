use crate::identity::IdentityMemory;
use crate::memory::{LivedMemoryStore, MemoryCore, MemoryError};
use crate::perception::PerceptionEvent;
use crate::skills::SkillRegistry;
use crate::trigger::{TriggerEngine, TriggeredAction};

#[derive(Debug, Default)]
pub struct RuntimeEffect {
    pub persisted_episode_id: Option<i64>,
    pub triggered_actions: Vec<TriggeredAction>,
}

/// Minimal persistent-agent runtime before an LLM/cognition layer is attached.
///
/// It already has identity continuity, lived-memory ingestion, skills and
/// proactive triggers. Cognition can later consume `RuntimeEffect`s without
/// changing the perception/memory contract.
pub struct AmadeusRuntime<S: LivedMemoryStore> {
    identity: IdentityMemory,
    memory: MemoryCore<S>,
    skills: SkillRegistry,
    triggers: TriggerEngine,
}

impl<S: LivedMemoryStore> AmadeusRuntime<S> {
    pub fn new(identity: IdentityMemory, store: S) -> Self {
        Self {
            identity,
            memory: MemoryCore::new(store),
            skills: SkillRegistry::default(),
            triggers: TriggerEngine::default(),
        }
    }

    pub fn ingest_perception(
        &mut self,
        event: PerceptionEvent,
    ) -> Result<RuntimeEffect, MemoryError> {
        let triggered_actions = self.triggers.evaluate(&event);
        let persisted_episode_id = self.memory.ingest(event)?;
        Ok(RuntimeEffect {
            persisted_episode_id,
            triggered_actions,
        })
    }

    pub fn identity(&self) -> &IdentityMemory {
        &self.identity
    }

    pub fn memory(&self) -> &MemoryCore<S> {
        &self.memory
    }

    pub fn memory_mut(&mut self) -> &mut MemoryCore<S> {
        &mut self.memory
    }

    pub fn skills(&self) -> &SkillRegistry {
        &self.skills
    }

    pub fn skills_mut(&mut self) -> &mut SkillRegistry {
        &mut self.skills
    }

    pub fn triggers(&self) -> &TriggerEngine {
        &self.triggers
    }

    pub fn triggers_mut(&mut self) -> &mut TriggerEngine {
        &mut self.triggers
    }
}
