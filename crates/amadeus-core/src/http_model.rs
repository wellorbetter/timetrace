use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::model::{ChatRole, ModelError, ModelProvider, ModelRequest, ModelResponse};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenAiCompatibleProviderConfig {
    pub id: String,
    /// Full chat-completions endpoint, for example a local gateway or hosted
    /// OpenAI-compatible `/v1/chat/completions` URL.
    pub endpoint: String,
    /// Environment variable holding the bearer token. Secrets are deliberately
    /// not stored in Amadeus JSON configuration.
    pub api_key_env: Option<String>,
    #[serde(default)]
    pub extra_headers: BTreeMap<String, String>,
}

pub struct OpenAiCompatibleProvider {
    config: OpenAiCompatibleProviderConfig,
    agent: ureq::Agent,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiCompatibleProviderConfig) -> Self {
        Self {
            config,
            agent: ureq::agent(),
        }
    }
}

#[derive(Serialize)]
struct ChatCompletionRequest<'a> {
    model: &'a str,
    messages: Vec<WireMessage<'a>>,
    temperature: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
}

#[derive(Serialize)]
struct WireMessage<'a> {
    role: &'static str,
    content: &'a str,
}

#[derive(Deserialize)]
struct ChatCompletionResponse {
    #[serde(default)]
    model: String,
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: ChoiceMessage,
}

#[derive(Deserialize)]
struct ChoiceMessage {
    content: Option<String>,
}

impl ModelProvider for OpenAiCompatibleProvider {
    fn id(&self) -> &str {
        &self.config.id
    }

    fn complete(&self, model: &str, request: &ModelRequest) -> Result<ModelResponse, ModelError> {
        let messages = request
            .messages
            .iter()
            .map(|message| WireMessage {
                role: match message.role {
                    ChatRole::System => "system",
                    ChatRole::User => "user",
                    ChatRole::Assistant => "assistant",
                    ChatRole::Tool => "tool",
                },
                content: &message.content,
            })
            .collect();
        let payload = ChatCompletionRequest {
            model,
            messages,
            temperature: request.temperature,
            max_tokens: request.max_output_tokens,
        };

        let mut outgoing = self.agent.post(&self.config.endpoint);
        if let Some(env_name) = &self.config.api_key_env {
            let key = std::env::var(env_name).map_err(|_| {
                ModelError::Provider(format!(
                    "missing model API key environment variable: {env_name}"
                ))
            })?;
            outgoing = outgoing.header("Authorization", &format!("Bearer {key}"));
        }
        for (name, value) in &self.config.extra_headers {
            outgoing = outgoing.header(name, value);
        }

        let mut response = outgoing
            .send_json(&payload)
            .map_err(|error| ModelError::Provider(error.to_string()))?;
        let body: ChatCompletionResponse = response
            .body_mut()
            .with_config()
            .limit(4 * 1024 * 1024)
            .read_json()
            .map_err(|error| ModelError::Provider(error.to_string()))?;
        let text = body
            .choices
            .into_iter()
            .find_map(|choice| choice.message.content)
            .filter(|text| !text.trim().is_empty())
            .ok_or_else(|| ModelError::Provider("model returned no textual choice".into()))?;

        Ok(ModelResponse {
            text,
            model: if body.model.is_empty() {
                model.to_owned()
            } else {
                body.model
            },
            provider: self.config.id.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_config_never_contains_an_api_key_value() {
        let config = OpenAiCompatibleProviderConfig {
            id: "router".into(),
            endpoint: "http://127.0.0.1:8080/v1/chat/completions".into(),
            api_key_env: Some("AMADEUS_MODEL_KEY".into()),
            extra_headers: BTreeMap::new(),
        };
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("AMADEUS_MODEL_KEY"));
        assert!(!json.contains("Bearer"));
    }
}
