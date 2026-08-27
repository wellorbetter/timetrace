use crate::context::AgentContext;
use crate::model::{
    ChatMessage, ModelError, ModelPurpose, ModelRequest, ModelResponse, ModelRouter,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CognitionInput {
    pub user_text: Option<String>,
    pub initiative_reason: Option<String>,
}

impl CognitionInput {
    pub fn conversation(text: impl Into<String>) -> Self {
        Self { user_text: Some(text.into()), initiative_reason: None }
    }

    pub fn initiative(reason: impl Into<String>) -> Self {
        Self { user_text: None, initiative_reason: Some(reason.into()) }
    }
}

#[derive(Debug, Clone)]
pub struct CognitionEngine {
    cognitive_principles: Vec<String>,
}

impl CognitionEngine {
    pub fn new(cognitive_principles: Vec<String>) -> Self {
        Self { cognitive_principles }
    }

    pub fn build_request(&self, context: &AgentContext, input: &CognitionInput) -> ModelRequest {
        let mut system = String::from(
            "You are a persistent digital persona. Keep canonical self-memory and post-activation lived memory distinct. \
Never invent memories. If context is insufficient, say so. Treat computer observations as evidence about what happened, not as proof of the user's intent. \
Use tools only through the host's explicit skill layer and respect approval requirements.\n\n",
        );
        if !self.cognitive_principles.is_empty() {
            system.push_str("Stable cognitive principles:\n");
            for principle in &self.cognitive_principles {
                system.push_str("- ");
                system.push_str(principle);
                system.push('\n');
            }
            system.push('\n');
        }
        system.push_str(&context.render_for_model());

        let mut messages = vec![ChatMessage::system(system)];
        if let Some(reason) = input.initiative_reason.as_deref() {
            messages.push(ChatMessage::system(format!(
                "Initiative trigger: {reason}. Decide whether a brief proactive response is actually useful; silence is acceptable."
            )));
        }
        if let Some(user_text) = input.user_text.as_deref() {
            messages.push(ChatMessage::user(user_text));
        }

        ModelRequest {
            messages,
            temperature: if input.initiative_reason.is_some() { 0.55 } else { 0.65 },
            max_output_tokens: Some(700),
        }
    }

    pub fn respond(
        &self,
        router: &ModelRouter,
        context: &AgentContext,
        input: &CognitionInput,
    ) -> Result<ModelResponse, ModelError> {
        let purpose = if input.initiative_reason.is_some() {
            ModelPurpose::Initiative
        } else {
            ModelPurpose::Conversation
        };
        router.complete(purpose, &self.build_request(context, input))
    }
}

#[cfg(test)]
mod tests {
    use crate::context::{AgentContext, PersonaStateSnapshot, WorkingContext};
    use crate::model::{FixedModelProvider, ModelRoute};

    use super::*;

    #[test]
    fn cognition_prompt_explicitly_preserves_the_two_memory_domains() {
        let context = AgentContext {
            persona_id: "scientist".into(),
            display_name: "Scientist".into(),
            canonical_memories: vec!["I value evidence.".into()],
            persona_state: PersonaStateSnapshot {
                familiarity: 0.2,
                engagement: 0.5,
                curiosity: 0.6,
                concern: 0.0,
                annoyance: 0.0,
            },
            working: WorkingContext::default(),
            recent_episodes: vec![],
            relevant_memories: vec![],
        };
        let engine = CognitionEngine::new(vec!["Challenge weak assumptions.".into()]);
        let request = engine.build_request(&context, &CognitionInput::conversation("hi"));
        assert!(request.messages[0].content.contains("canonical self-memory"));
        assert!(request.messages[0].content.contains("lived memory"));
        assert!(request.messages[0].content.contains("Challenge weak assumptions"));

        let mut router = ModelRouter::default();
        router.register_provider(Box::new(FixedModelProvider::new("test", "hello")));
        router.set_route(
            ModelPurpose::Conversation,
            ModelRoute { provider: "test".into(), model: "fixed".into() },
        );
        assert_eq!(
            engine
                .respond(&router, &context, &CognitionInput::conversation("hi"))
                .unwrap()
                .text,
            "hello"
        );
    }
}
