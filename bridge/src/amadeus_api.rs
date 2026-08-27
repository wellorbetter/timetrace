use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;

use amadeus_core::{
    model_config_path, LivedMemory, LivedMemoryKind, LivedMemorySource,
    LivedMemoryStore, ModelPurpose, ModelRuntimeConfig,
};
use timetrace_core::{
    amadeus_converse, configure_openai_compatible_model, recent_amadeus_memories,
    search_amadeus_memories, shared_amadeus_runtime, take_pending_initiatives,
};

#[derive(Debug, Clone)]
pub struct AmadeusStatusDto {
    pub persona_id: String,
    pub display_name: String,
    pub current_app: Option<String>,
    pub current_window: Option<String>,
    pub familiarity: f64,
    pub memory_count_sample: i64,
    pub model_configured: bool,
}

#[derive(Debug, Clone)]
pub struct AmadeusMemoryDto {
    pub kind: String,
    pub source: String,
    pub content: String,
    pub salience: f64,
    pub created_at: String,
    pub score: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct AmadeusReplyDto {
    pub text: String,
    pub provider: String,
    pub model: String,
    pub created_at: String,
}

#[derive(Debug, Clone)]
pub struct AmadeusInitiativeDto {
    pub reason: String,
    pub text: Option<String>,
    pub error: Option<String>,
    pub created_at: String,
}

#[frb(sync)]
pub fn amadeus_get_status() -> Result<AmadeusStatusDto> {
    let shared = shared_amadeus_runtime().map_err(|error| anyhow!(error.to_string()))?;
    let runtime = shared
        .lock()
        .map_err(|_| anyhow!("Amadeus runtime mutex poisoned"))?;
    let current = runtime.working_context().current_activity.as_ref();
    let memory_count_sample = runtime
        .memory()
        .store()
        .recent_memories(1000)
        .map_err(|error| anyhow!(error.to_string()))?
        .len() as i64;
    Ok(AmadeusStatusDto {
        persona_id: runtime.identity().persona_id().to_owned(),
        display_name: runtime.identity().display_name().to_owned(),
        current_app: current.map(|activity| activity.display_name.clone()),
        current_window: current.and_then(|activity| activity.window_title.clone()),
        familiarity: runtime.persona_state().familiarity() as f64,
        memory_count_sample,
        model_configured: model_configured(),
    })
}

#[frb(sync)]
pub fn amadeus_recent_memory(limit: u32) -> Result<Vec<AmadeusMemoryDto>> {
    Ok(recent_amadeus_memories(limit as usize)
        .map_err(|error| anyhow!(error.to_string()))?
        .into_iter()
        .map(|memory| memory_dto(memory, None))
        .collect())
}

#[frb(sync)]
pub fn amadeus_search_memory(query: String, limit: u32) -> Result<Vec<AmadeusMemoryDto>> {
    Ok(search_amadeus_memories(&query, limit as usize)
        .map_err(|error| anyhow!(error.to_string()))?
        .into_iter()
        .map(|hit| memory_dto(hit.memory, Some(hit.score as f64)))
        .collect())
}

#[frb(sync)]
pub fn amadeus_send_message(text: String) -> Result<AmadeusReplyDto> {
    let turn = amadeus_converse(&text).map_err(|error| anyhow!(error.to_string()))?;
    Ok(AmadeusReplyDto {
        text: turn.assistant_text,
        provider: turn.provider,
        model: turn.model,
        created_at: turn.created_at.to_rfc3339(),
    })
}

/// Configure an OpenAI-compatible chat-completions provider. The actual API key
/// value is never passed or persisted here; `api_key_env` names an environment
/// variable read by the Rust provider at request time.
#[frb(sync)]
pub fn amadeus_configure_model(
    provider_id: String,
    endpoint: String,
    model: String,
    api_key_env: Option<String>,
) -> Result<()> {
    configure_openai_compatible_model(provider_id, endpoint, model, api_key_env)
        .map_err(|error| anyhow!(error.to_string()))
}

#[frb(sync)]
pub fn amadeus_take_initiative(limit: u32) -> Vec<AmadeusInitiativeDto> {
    take_pending_initiatives(limit as usize)
        .into_iter()
        .map(|item| AmadeusInitiativeDto {
            reason: item.reason,
            text: item.text,
            error: item.error,
            created_at: item.created_at.to_rfc3339(),
        })
        .collect()
}

fn model_configured() -> bool {
    ModelRuntimeConfig::load(model_config_path())
        .ok()
        .is_some_and(|config| {
            config
                .routes
                .iter()
                .any(|route| route.purpose == ModelPurpose::Conversation)
        })
}

fn memory_dto(memory: LivedMemory, score: Option<f64>) -> AmadeusMemoryDto {
    AmadeusMemoryDto {
        kind: match memory.kind {
            LivedMemoryKind::Conversation => "conversation",
            LivedMemoryKind::Relationship => "relationship",
            LivedMemoryKind::ProjectFact => "project_fact",
            LivedMemoryKind::Preference => "preference",
            LivedMemoryKind::Reflection => "reflection",
        }
        .into(),
        source: match memory.source {
            LivedMemorySource::Conversation => "conversation",
            LivedMemorySource::Computer => "computer",
            LivedMemorySource::Skill => "skill",
            LivedMemorySource::Trigger => "trigger",
            LivedMemorySource::Reflection => "reflection",
        }
        .into(),
        content: memory.content,
        salience: memory.salience as f64,
        created_at: memory.created_at.to_rfc3339(),
        score,
    }
}
