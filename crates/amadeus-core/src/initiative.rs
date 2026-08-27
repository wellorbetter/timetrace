use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::cognition::{CognitionEngine, CognitionInput};
use crate::memory::{
    LivedMemory, LivedMemoryKind, LivedMemorySource, LivedMemoryStore, MemoryError,
};
use crate::model::{ModelError, ModelRouter};
use crate::runtime::AmadeusRuntime;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InitiativeMessage {
    pub reason: String,
    pub text: String,
    pub provider: String,
    pub model: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Error)]
pub enum InitiativeError {
    #[error("memory: {0}")]
    Memory(#[from] MemoryError),
    #[error("model: {0}")]
    Model(#[from] ModelError),
}

pub struct InitiativeService {
    router: ModelRouter,
}

impl InitiativeService {
    pub fn new(router: ModelRouter) -> Self {
        Self { router }
    }

    pub fn consider<S: LivedMemoryStore>(
        &self,
        runtime: &mut AmadeusRuntime<S>,
        reason: impl Into<String>,
        now: DateTime<Utc>,
    ) -> Result<Option<InitiativeMessage>, InitiativeError> {
        let reason = reason.into();
        let context = runtime.compose_context(&reason, now)?;
        let cognition = CognitionEngine::new(runtime.cognitive_principles().to_vec());
        let response = cognition.respond(
            &self.router,
            &context,
            &CognitionInput::initiative(reason.clone()),
        )?;
        let text = response.text.trim().to_owned();
        if text.is_empty()
            || text.eq_ignore_ascii_case("silence")
            || text.eq_ignore_ascii_case("[silence]")
        {
            return Ok(None);
        }

        runtime.memory_mut().store_mut().append_memory(&LivedMemory {
            kind: LivedMemoryKind::Conversation,
            source: LivedMemorySource::Trigger,
            content: format!("assistant initiative: {text}"),
            salience: 0.64,
            created_at: now,
        })?;
        Ok(Some(InitiativeMessage {
            reason,
            text,
            provider: response.provider,
            model: response.model,
            created_at: now,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::IdentityMemory;
    use crate::memory::SqliteLivedMemoryStore;
    use crate::model::{FixedModelProvider, ModelPurpose, ModelRoute};

    #[test]
    fn explicit_silence_does_not_create_a_fake_conversation_memory() {
        let identity = IdentityMemory::from_persona_pack("p", "Persona", None, vec![]);
        let store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut runtime = AmadeusRuntime::new(identity, store);
        let mut router = ModelRouter::default();
        router.register_provider(Box::new(FixedModelProvider::new("fixed", "[silence]")));
        router.set_route(
            ModelPurpose::Initiative,
            ModelRoute {
                provider: "fixed".into(),
                model: "test".into(),
            },
        );
        let service = InitiativeService::new(router);
        assert!(service.consider(&mut runtime, "long work", Utc::now()).unwrap().is_none());
        assert!(runtime.memory().store().recent_memories(10).unwrap().is_empty());
    }
}
