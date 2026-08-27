use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum ModelPurpose {
    Conversation,
    Initiative,
    Consolidation,
    Reflection,
    Embedding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChatRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

impl ChatMessage {
    pub fn system(content: impl Into<String>) -> Self {
        Self { role: ChatRole::System, content: content.into() }
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self { role: ChatRole::User, content: content.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelRequest {
    pub messages: Vec<ChatMessage>,
    pub temperature: f32,
    pub max_output_tokens: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelResponse {
    pub text: String,
    pub model: String,
    pub provider: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelRoute {
    pub provider: String,
    pub model: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ModelError {
    #[error("no model route configured for {0:?}")]
    MissingRoute(ModelPurpose),
    #[error("unknown model provider: {0}")]
    UnknownProvider(String),
    #[error("model provider error: {0}")]
    Provider(String),
}

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;
    fn complete(&self, model: &str, request: &ModelRequest) -> Result<ModelResponse, ModelError>;
}

#[derive(Default)]
pub struct ModelRouter {
    providers: BTreeMap<String, Box<dyn ModelProvider>>,
    routes: BTreeMap<ModelPurpose, ModelRoute>,
}

impl ModelRouter {
    pub fn register_provider(&mut self, provider: Box<dyn ModelProvider>) {
        self.providers.insert(provider.id().to_owned(), provider);
    }

    pub fn set_route(&mut self, purpose: ModelPurpose, route: ModelRoute) {
        self.routes.insert(purpose, route);
    }

    pub fn route(&self, purpose: ModelPurpose) -> Option<&ModelRoute> {
        self.routes.get(&purpose)
    }

    pub fn complete(
        &self,
        purpose: ModelPurpose,
        request: &ModelRequest,
    ) -> Result<ModelResponse, ModelError> {
        let route = self
            .routes
            .get(&purpose)
            .ok_or(ModelError::MissingRoute(purpose))?;
        let provider = self
            .providers
            .get(&route.provider)
            .ok_or_else(|| ModelError::UnknownProvider(route.provider.clone()))?;
        provider.complete(&route.model, request)
    }
}

/// A deterministic provider used by tests and offline development surfaces.
/// It deliberately does not pretend to be an intelligent model.
pub struct FixedModelProvider {
    id: String,
    response: String,
}

impl FixedModelProvider {
    pub fn new(id: impl Into<String>, response: impl Into<String>) -> Self {
        Self { id: id.into(), response: response.into() }
    }
}

impl ModelProvider for FixedModelProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn complete(&self, model: &str, _request: &ModelRequest) -> Result<ModelResponse, ModelError> {
        Ok(ModelResponse {
            text: self.response.clone(),
            model: model.to_owned(),
            provider: self.id.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_different_cognition_purposes_without_binding_to_one_provider() {
        let mut router = ModelRouter::default();
        router.register_provider(Box::new(FixedModelProvider::new("local", "ok")));
        router.set_route(
            ModelPurpose::Conversation,
            ModelRoute { provider: "local".into(), model: "small".into() },
        );
        let response = router
            .complete(
                ModelPurpose::Conversation,
                &ModelRequest {
                    messages: vec![ChatMessage::user("hello")],
                    temperature: 0.3,
                    max_output_tokens: Some(128),
                },
            )
            .unwrap();
        assert_eq!(response.provider, "local");
        assert_eq!(response.model, "small");
    }
}
