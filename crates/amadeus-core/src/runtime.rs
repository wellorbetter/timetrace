use chrono::{DateTime, Utc};

use crate::consolidation::EpisodeConsolidator;
use crate::context::{AgentContext, ContextComposer, WorkingContext};
use crate::evolution::{
    EvolutionCandidate, EvolutionDecision, EvolutionPolicy, EvolutionStatus,
};
use crate::identity::IdentityMemory;
use crate::memory::{LivedMemoryStore, MemoryCore, MemoryError};
use crate::perception::PerceptionEvent;
use crate::persona::{PersonaPack, PersonaState, PersonaStateDelta};
use crate::skills::SkillRegistry;
use crate::state::{RuntimeStateSnapshot, RUNTIME_STATE_SCHEMA_VERSION};
use crate::trigger::{TriggerEngine, TriggeredAction};

#[derive(Debug, Default)]
pub struct RuntimeEffect {
    pub persisted_episode_id: Option<i64>,
    pub consolidated_memory_id: Option<i64>,
    pub triggered_actions: Vec<TriggeredAction>,
}

/// Persistent-agent runtime independent from any particular UI or model.
///
/// Perception updates working context immediately, completed activity becomes
/// lived memory, and triggers can produce proactive actions. Canonical identity
/// remains outside mutable runtime state; only post-activation persona dynamics,
/// triggers and evolution history are snapshotted/restored.
pub struct AmadeusRuntime<S: LivedMemoryStore> {
    identity: IdentityMemory,
    cognitive_principles: Vec<String>,
    persona_state: PersonaState,
    working: WorkingContext,
    memory: MemoryCore<S>,
    consolidator: EpisodeConsolidator,
    context_composer: ContextComposer,
    skills: SkillRegistry,
    triggers: TriggerEngine,
    evolution_policy: EvolutionPolicy,
    evolutions: Vec<EvolutionCandidate>,
}

impl<S: LivedMemoryStore> AmadeusRuntime<S> {
    pub fn new(identity: IdentityMemory, store: S) -> Self {
        Self {
            identity,
            cognitive_principles: vec![],
            persona_state: PersonaState::default(),
            working: WorkingContext::default(),
            memory: MemoryCore::new(store),
            consolidator: EpisodeConsolidator::default(),
            context_composer: ContextComposer::default(),
            skills: SkillRegistry::default(),
            triggers: TriggerEngine::default(),
            evolution_policy: EvolutionPolicy::default(),
            evolutions: Vec::new(),
        }
    }

    pub fn from_persona_pack(pack: PersonaPack, store: S) -> Self {
        let PersonaPack {
            identity,
            cognitive_principles,
            ..
        } = pack;
        let mut runtime = Self::new(identity, store);
        runtime.cognitive_principles = cognitive_principles;
        runtime
    }

    pub fn ingest_perception(
        &mut self,
        event: PerceptionEvent,
    ) -> Result<RuntimeEffect, MemoryError> {
        let triggered_actions = self.triggers.evaluate(&event);
        self.update_working_context(&event);
        let persisted_episode_id = self.memory.ingest(event)?;

        let consolidated_memory_id = if persisted_episode_id.is_some() {
            let episode = self.memory.store().recent_episodes(1)?.into_iter().next();
            if let Some(memory) = episode
                .as_ref()
                .and_then(|episode| self.consolidator.consolidate(episode))
            {
                Some(self.memory.store_mut().append_memory(&memory)?)
            } else {
                None
            }
        } else {
            None
        };

        Ok(RuntimeEffect {
            persisted_episode_id,
            consolidated_memory_id,
            triggered_actions,
        })
    }

    pub fn flush(&mut self, at: DateTime<Utc>) -> Result<RuntimeEffect, MemoryError> {
        let persisted_episode_id = self.memory.flush(at)?;
        let consolidated_memory_id = if persisted_episode_id.is_some() {
            let episode = self.memory.store().recent_episodes(1)?.into_iter().next();
            if let Some(memory) = episode
                .as_ref()
                .and_then(|episode| self.consolidator.consolidate(episode))
            {
                Some(self.memory.store_mut().append_memory(&memory)?)
            } else {
                None
            }
        } else {
            None
        };
        Ok(RuntimeEffect {
            persisted_episode_id,
            consolidated_memory_id,
            triggered_actions: vec![],
        })
    }

    pub fn compose_context(
        &self,
        query: &str,
        now: DateTime<Utc>,
    ) -> Result<AgentContext, MemoryError> {
        self.context_composer.compose(
            &self.identity,
            &self.persona_state,
            &self.working,
            self.memory.store(),
            query,
            now,
        )
    }

    fn update_working_context(&mut self, event: &PerceptionEvent) {
        match event {
            PerceptionEvent::ForegroundChanged { current, at, .. }
            | PerceptionEvent::IdleEnded { current, at } => {
                self.working.on_foreground(current.clone(), *at);
            }
            PerceptionEvent::IdleStarted { at, .. }
            | PerceptionEvent::GapDetected { at } => self.working.on_idle_or_gap(*at),
        }
    }

    /// Snapshot only post-activation mutable state. Identity/canonical memory is
    /// structurally impossible to include in this value.
    pub fn snapshot_state(&self) -> RuntimeStateSnapshot {
        RuntimeStateSnapshot {
            schema_version: RUNTIME_STATE_SCHEMA_VERSION,
            persona_state: self.persona_state.clone(),
            triggers: self.triggers.definitions().to_vec(),
            evolutions: self.evolutions.clone(),
        }
    }

    pub fn restore_state(&mut self, snapshot: RuntimeStateSnapshot) {
        self.persona_state = snapshot.persona_state;
        self.triggers.replace_definitions(snapshot.triggers);
        self.evolutions = snapshot.evolutions;
    }

    pub fn propose_evolution(&mut self, mut candidate: EvolutionCandidate) -> EvolutionDecision {
        let decision = self.evolution_policy.decide(&candidate);
        if decision == EvolutionDecision::AutoAccept {
            candidate.status = EvolutionStatus::Accepted;
        }
        self.evolutions.push(candidate);
        decision
    }

    pub fn evolutions(&self) -> &[EvolutionCandidate] {
        &self.evolutions
    }

    pub fn identity(&self) -> &IdentityMemory {
        &self.identity
    }

    pub fn cognitive_principles(&self) -> &[String] {
        &self.cognitive_principles
    }

    pub fn persona_state(&self) -> &PersonaState {
        &self.persona_state
    }

    pub fn apply_persona_delta(&mut self, delta: PersonaStateDelta) {
        self.persona_state.apply_delta(delta);
    }

    pub fn working_context(&self) -> &WorkingContext {
        &self.working
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

#[cfg(test)]
mod tests {
    use chrono::DateTime;

    use super::*;
    use crate::evolution::{EvolutionDomain, EvolutionRisk};
    use crate::identity::IdentityMemory;
    use crate::memory::SqliteLivedMemoryStore;
    use crate::perception::ComputerActivity;
    use crate::trigger::{Trigger, TriggerAction, TriggerCondition};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn completed_work_becomes_episode_and_consolidated_lived_memory() {
        let identity = IdentityMemory::from_persona_pack("p", "Persona", None, vec![]);
        let store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut runtime = AmadeusRuntime::new(identity, store);
        runtime
            .ingest_perception(PerceptionEvent::ForegroundChanged {
                previous: None,
                current: ComputerActivity::new("editor", "Editor")
                    .with_window_title("memory.rs"),
                at: at(100),
            })
            .unwrap();
        let effect = runtime
            .ingest_perception(PerceptionEvent::IdleStarted {
                at: at(200),
                grace_ms: 0,
            })
            .unwrap();
        assert!(effect.persisted_episode_id.is_some());
        assert!(effect.consolidated_memory_id.is_some());
        assert_eq!(runtime.memory().store().recent_memories(10).unwrap().len(), 1);
    }

    #[test]
    fn working_context_is_visible_before_an_episode_is_closed() {
        let identity = IdentityMemory::from_persona_pack("p", "Persona", None, vec![]);
        let store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut runtime = AmadeusRuntime::new(identity, store);
        runtime
            .ingest_perception(PerceptionEvent::ForegroundChanged {
                previous: None,
                current: ComputerActivity::new("editor", "Editor"),
                at: at(100),
            })
            .unwrap();
        assert_eq!(
            runtime.working_context().current_activity.as_ref().unwrap().display_name,
            "Editor"
        );
        let context = runtime.compose_context("Editor", at(110)).unwrap();
        assert_eq!(context.working.current_activity.unwrap().display_name, "Editor");
    }

    #[test]
    fn state_round_trip_preserves_lived_persona_and_triggers_not_identity() {
        let identity = IdentityMemory::from_persona_pack("self", "Self", None, vec![]);
        let store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut runtime = AmadeusRuntime::new(identity.clone(), store);
        runtime.apply_persona_delta(PersonaStateDelta {
            familiarity: 0.4,
            ..PersonaStateDelta::default()
        });
        runtime.triggers_mut().add(Trigger {
            id: "long-work".into(),
            enabled: true,
            condition: TriggerCondition::ContinuousComputerActivity { min_seconds: 7200 },
            action: TriggerAction::ConsiderInitiative { reason: "long work".into() },
            cooldown_seconds: 3600,
        });
        runtime.propose_evolution(EvolutionCandidate {
            id: "debug-flow".into(),
            domain: EvolutionDomain::Skill,
            risk: EvolutionRisk::Low,
            summary: "Prefer log-first debugging".into(),
            evidence: vec!["Repeated success".into()],
            confidence: 0.95,
            created_at: at(100),
            status: EvolutionStatus::Proposed,
        });
        let snapshot = runtime.snapshot_state();

        let store2 = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut restored = AmadeusRuntime::new(identity.clone(), store2);
        restored.restore_state(snapshot);
        assert_eq!(restored.identity(), &identity);
        assert_eq!(restored.persona_state().familiarity(), 0.4);
        assert_eq!(restored.triggers().definitions().len(), 1);
        assert_eq!(restored.evolutions().len(), 1);
    }
}
