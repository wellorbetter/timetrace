use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::cognition::{CognitionEngine, CognitionInput};
use crate::memory::{
    LivedMemory, LivedMemoryKind, LivedMemorySource, LivedMemoryStore, MemoryError,
};
use crate::model::{ModelError, ModelResponse, ModelRouter};
use crate::runtime::AmadeusRuntime;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversationTurn {
    pub user_text: String,
    pub assistant_text: String,
    pub provider: String,
    pub model: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Error)]
pub enum ConversationError {
    #[error("memory: {0}")]
    Memory(#[from] MemoryError),
    #[error("model: {0}")]
    Model(#[from] ModelError),
}

pub struct ConversationService {
    router: ModelRouter,
}

impl ConversationService {
    pub fn new(router: ModelRouter) -> Self {
        Self { router }
    }

    pub fn router(&self) -> &ModelRouter {
        &self.router
    }

    /// Run one grounded turn. Context is composed before the new user message is
    /// appended so the prompt does not see the same message twice; the message
    /// is still persisted even if the provider call fails.
    pub fn send<S: LivedMemoryStore>(
        &self,
        runtime: &mut AmadeusRuntime<S>,
        user_text: impl Into<String>,
        now: DateTime<Utc>,
    ) -> Result<ConversationTurn, ConversationError> {
        let user_text = user_text.into();
        let context = runtime.compose_context(&user_text, now)?;
        runtime.memory_mut().store_mut().append_memory(&LivedMemory {
            kind: LivedMemoryKind::Conversation,
            source: LivedMemorySource::Conversation,
            content: format!("user: {user_text}"),
            salience: 0.72,
            created_at: now,
        })?;

        let cognition = CognitionEngine::new(runtime.cognitive_principles().to_vec());
        let ModelResponse {
            text,
            model,
            provider,
        } = cognition.respond(
            &self.router,
            &context,
            &CognitionInput::conversation(user_text.clone()),
        )?;

        runtime.memory_mut().store_mut().append_memory(&LivedMemory {
            kind: LivedMemoryKind::Conversation,
            source: LivedMemorySource::Conversation,
            content: format!("assistant: {text}"),
            salience: 0.68,
            created_at: now,
        })?;

        Ok(ConversationTurn {
            user_text,
            assistant_text: text,
            provider,
            model,
            created_at: now,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::IdentityMemory;
    use crate::memory::SqliteLivedMemoryStore;
    use crate::model::{FixedModelProvider, ModelPurpose, ModelRoute};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn a_turn_persists_both_sides_as_lived_memory() {
        let identity = IdentityMemory::from_persona_pack("p", "Persona", None, vec![]);
        let store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        let mut runtime = AmadeusRuntime::new(identity, store);
        let mut router = ModelRouter::default();
        router.register_provider(Box::new(FixedModelProvider::new("fixed", "reply")));
        router.set_route(
            ModelPurpose::Conversation,
            ModelRoute {
                provider: "fixed".into(),
                model: "test".into(),
            },
        );
        let service = ConversationService::new(router);
        let turn = service.send(&mut runtime, "hello", at(100)).unwrap();
        assert_eq!(turn.assistant_text, "reply");
        let memories = runtime.memory().store().recent_memories(10).unwrap();
        assert_eq!(memories.len(), 2);
        assert!(memories.iter().any(|m| m.content == "user: hello"));
        assert!(memories.iter().any(|m| m.content == "assistant: reply"));
    }
}
