use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::http_model::{OpenAiCompatibleProvider, OpenAiCompatibleProviderConfig};
use crate::model::{ModelPurpose, ModelRoute, ModelRouter};

pub const MODEL_CONFIG_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PurposeRouteConfig {
    pub purpose: ModelPurpose,
    pub provider: String,
    pub model: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelRuntimeConfig {
    pub schema_version: u32,
    #[serde(default)]
    pub openai_compatible: Vec<OpenAiCompatibleProviderConfig>,
    #[serde(default)]
    pub routes: Vec<PurposeRouteConfig>,
}

impl Default for ModelRuntimeConfig {
    fn default() -> Self {
        Self {
            schema_version: MODEL_CONFIG_SCHEMA_VERSION,
            openai_compatible: Vec::new(),
            routes: Vec::new(),
        }
    }
}

#[derive(Debug, Error)]
pub enum ModelConfigError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported model config schema: {0}")]
    UnsupportedSchema(u32),
}

impl ModelRuntimeConfig {
    pub fn load(path: impl AsRef<Path>) -> Result<Self, ModelConfigError> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::default());
        }
        let config: Self = serde_json::from_slice(&fs::read(path)?)?;
        config.validate()?;
        Ok(config)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), ModelConfigError> {
        self.validate()?;
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_json::to_vec_pretty(self)?)?;
        Ok(())
    }

    pub fn build_router(&self) -> Result<ModelRouter, ModelConfigError> {
        self.validate()?;
        let mut router = ModelRouter::default();
        for provider in &self.openai_compatible {
            router.register_provider(Box::new(OpenAiCompatibleProvider::new(provider.clone())));
        }
        for route in &self.routes {
            router.set_route(
                route.purpose,
                ModelRoute {
                    provider: route.provider.clone(),
                    model: route.model.clone(),
                },
            );
        }
        Ok(router)
    }

    pub fn validate(&self) -> Result<(), ModelConfigError> {
        if self.schema_version != MODEL_CONFIG_SCHEMA_VERSION {
            return Err(ModelConfigError::UnsupportedSchema(self.schema_version));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_keeps_secret_values_out_of_json() {
        let config = ModelRuntimeConfig {
            schema_version: MODEL_CONFIG_SCHEMA_VERSION,
            openai_compatible: vec![OpenAiCompatibleProviderConfig {
                id: "gateway".into(),
                endpoint: "http://localhost:8080/v1/chat/completions".into(),
                api_key_env: Some("AMADEUS_GATEWAY_KEY".into()),
                extra_headers: Default::default(),
            }],
            routes: vec![PurposeRouteConfig {
                purpose: ModelPurpose::Conversation,
                provider: "gateway".into(),
                model: "model".into(),
            }],
        };
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("AMADEUS_GATEWAY_KEY"));
        assert!(!json.contains("Bearer "));
    }
}
