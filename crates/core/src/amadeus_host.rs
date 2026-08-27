use std::collections::VecDeque;
use std::fs;
use std::sync::{Arc, Mutex, OnceLock};

use amadeus_core::{
    ensure_data_dir, memory_database_path, model_config_path, persona_pack_path,
    runtime_state_path, AmadeusRuntime, CanonicalMemory, ConversationError,
    ConversationService, ConversationTurn, IdentityMemory, InitiativeError,
    InitiativeService, JsonRuntimeStateStore, LivedMemory, LivedMemoryStore,
    MemoryError, MemoryQuery, MemoryRetriever, ModelConfigError,
    ModelPurpose, ModelRuntimeConfig, OpenAiCompatibleProviderConfig, PersonaPack,
    PersonaPackMetadata, PurposeRouteConfig, SqliteLivedMemoryStore, Trigger,
    TriggerAction, TriggerCondition, TriggeredAction, MODEL_CONFIG_SCHEMA_VERSION,
    PERSONA_PACK_SCHEMA_VERSION,
};
use chrono::{DateTime, Utc};
use thiserror::Error;

pub type SharedAmadeusRuntime = Arc<Mutex<AmadeusRuntime<SqliteLivedMemoryStore>>>;

static SHARED_RUNTIME: OnceLock<SharedAmadeusRuntime> = OnceLock::new();
static STATE_STORE: OnceLock<JsonRuntimeStateStore> = OnceLock::new();
static PENDING_INITIATIVES: OnceLock<Mutex<VecDeque<PendingInitiative>>> = OnceLock::new();

#[derive(Debug, Clone)]
pub struct PendingInitiative {
    pub reason: String,
    pub text: Option<String>,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Error)]
pub enum AmadeusHostError {
    #[error("memory: {0}")]
    Memory(#[from] MemoryError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("persona pack: {0}")]
    Persona(#[from] amadeus_core::PersonaPackError),
    #[error("runtime state: {0}")]
    State(#[from] amadeus_core::RuntimeStateError),
    #[error("model config: {0}")]
    ModelConfig(#[from] ModelConfigError),
    #[error("conversation: {0}")]
    Conversation(#[from] ConversationError),
    #[error("initiative: {0}")]
    Initiative(#[from] InitiativeError),
    #[error("shared runtime mutex poisoned")]
    Poisoned,
}

pub fn shared_amadeus_runtime() -> Result<SharedAmadeusRuntime, AmadeusHostError> {
    if let Some(runtime) = SHARED_RUNTIME.get() {
        return Ok(runtime.clone());
    }

    ensure_data_dir()?;
    let store = SqliteLivedMemoryStore::open(memory_database_path())?;
    let pack = load_persona_pack()?;
    let mut runtime = AmadeusRuntime::from_persona_pack(pack, store);

    let state_store = JsonRuntimeStateStore::new(runtime_state_path());
    let snapshot = state_store.load()?;
    runtime.restore_state(snapshot);

    // Give a fresh installation a restrained proactive baseline. Persisted
    // user definitions win on subsequent launches.
    if runtime.triggers().definitions().is_empty() {
        runtime.triggers_mut().add(Trigger {
            id: "long-continuous-work".into(),
            enabled: true,
            condition: TriggerCondition::ContinuousComputerActivity {
                min_seconds: 90 * 60,
            },
            action: TriggerAction::ConsiderInitiative {
                reason: "The user has been continuously active on the computer for 90 minutes."
                    .into(),
            },
            cooldown_seconds: 2 * 60 * 60,
        });
        state_store.save(&runtime.snapshot_state())?;
    }

    let runtime = Arc::new(Mutex::new(runtime));
    let _ = STATE_STORE.set(state_store);
    let _ = PENDING_INITIATIVES.set(Mutex::new(VecDeque::new()));
    match SHARED_RUNTIME.set(runtime.clone()) {
        Ok(()) => Ok(runtime),
        Err(_) => Ok(SHARED_RUNTIME.get().expect("runtime initialized").clone()),
    }
}

pub fn persist_amadeus_state() -> Result<(), AmadeusHostError> {
    let runtime = shared_amadeus_runtime()?;
    let snapshot = runtime
        .lock()
        .map_err(|_| AmadeusHostError::Poisoned)?
        .snapshot_state();
    let state_store = STATE_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| JsonRuntimeStateStore::new(runtime_state_path()));
    state_store.save(&snapshot)?;
    Ok(())
}

pub fn amadeus_converse(user_text: &str) -> Result<ConversationTurn, AmadeusHostError> {
    let config = ModelRuntimeConfig::load(model_config_path())?;
    let service = ConversationService::new(config.build_router()?);
    let runtime = shared_amadeus_runtime()?;
    let mut runtime = runtime.lock().map_err(|_| AmadeusHostError::Poisoned)?;
    Ok(service.send(&mut *runtime, user_text, Utc::now())?)
}

pub fn search_amadeus_memories(
    query: &str,
    limit: usize,
) -> Result<Vec<amadeus_core::MemoryHit>, AmadeusHostError> {
    let runtime = shared_amadeus_runtime()?;
    let runtime = runtime.lock().map_err(|_| AmadeusHostError::Poisoned)?;
    let mut query = MemoryQuery::text(query);
    query.limit = limit.clamp(1, 100);
    Ok(MemoryRetriever::default().search(
        runtime.memory().store(),
        &query,
        Utc::now(),
    )?)
}

pub fn recent_amadeus_memories(limit: usize) -> Result<Vec<LivedMemory>, AmadeusHostError> {
    let runtime = shared_amadeus_runtime()?;
    let runtime = runtime.lock().map_err(|_| AmadeusHostError::Poisoned)?;
    Ok(runtime
        .memory()
        .store()
        .recent_memories(limit.clamp(1, 100))?)
}

pub fn configure_openai_compatible_model(
    provider_id: String,
    endpoint: String,
    model: String,
    api_key_env: Option<String>,
) -> Result<(), AmadeusHostError> {
    let provider_id = provider_id.trim().to_owned();
    let endpoint = endpoint.trim().to_owned();
    let model = model.trim().to_owned();
    let config = ModelRuntimeConfig {
        schema_version: MODEL_CONFIG_SCHEMA_VERSION,
        openai_compatible: vec![OpenAiCompatibleProviderConfig {
            id: provider_id.clone(),
            endpoint,
            api_key_env: api_key_env.filter(|value| !value.trim().is_empty()),
            extra_headers: Default::default(),
        }],
        routes: [
            ModelPurpose::Conversation,
            ModelPurpose::Initiative,
            ModelPurpose::Consolidation,
            ModelPurpose::Reflection,
        ]
        .into_iter()
        .map(|purpose| PurposeRouteConfig {
            purpose,
            provider: provider_id.clone(),
            model: model.clone(),
        })
        .collect(),
    };
    config.save(model_config_path())?;
    Ok(())
}

pub fn handle_triggered_actions(actions: Vec<TriggeredAction>) {
    for triggered in actions {
        match triggered.action {
            TriggerAction::ConsiderInitiative { reason } => {
                let created_at = triggered.fired_at;
                let pending = match consider_initiative(&reason, created_at) {
                    Ok(Some(message)) => Some(PendingInitiative {
                        reason,
                        text: Some(message.text),
                        error: None,
                        created_at,
                    }),
                    Ok(None) => None,
                    Err(error) => Some(PendingInitiative {
                        reason,
                        text: None,
                        error: Some(error.to_string()),
                        created_at,
                    }),
                };
                if let Some(pending) = pending {
                    let queue = PENDING_INITIATIVES.get_or_init(|| Mutex::new(VecDeque::new()));
                    if let Ok(mut queue) = queue.lock() {
                        queue.push_back(pending);
                        while queue.len() > 64 {
                            queue.pop_front();
                        }
                    }
                }
            }
            TriggerAction::RunSkill { .. } | TriggerAction::ProposeEvolution { .. } => {
                // These actions are intentionally not executed implicitly yet;
                // the skill/evolution layers apply their own approval policies.
            }
        }
    }
}

pub fn take_pending_initiatives(limit: usize) -> Vec<PendingInitiative> {
    let queue = PENDING_INITIATIVES.get_or_init(|| Mutex::new(VecDeque::new()));
    let Ok(mut queue) = queue.lock() else {
        return Vec::new();
    };
    let mut output = Vec::new();
    for _ in 0..limit.clamp(1, 32) {
        let Some(item) = queue.pop_front() else {
            break;
        };
        output.push(item);
    }
    output
}

fn consider_initiative(
    reason: &str,
    now: DateTime<Utc>,
) -> Result<Option<amadeus_core::InitiativeMessage>, AmadeusHostError> {
    let config = ModelRuntimeConfig::load(model_config_path())?;
    let service = InitiativeService::new(config.build_router()?);
    let runtime = shared_amadeus_runtime()?;
    let mut runtime = runtime.lock().map_err(|_| AmadeusHostError::Poisoned)?;
    Ok(service.consider(&mut *runtime, reason, now)?)
}

fn load_persona_pack() -> Result<PersonaPack, AmadeusHostError> {
    let path = persona_pack_path();
    if path.exists() {
        return Ok(PersonaPack::from_json(&fs::read_to_string(path)?)?);
    }
    Ok(default_persona_pack())
}

/// Conservative built-in seed for private development. A richer persona.json
/// can replace it without touching lived memory or runtime code.
fn default_persona_pack() -> PersonaPack {
    let identity = IdentityMemory::from_persona_pack(
        "kurisu-dev",
        "牧濑红莉栖 / Makise Kurisu",
        None,
        vec![CanonicalMemory::new(
            "identity-scientist",
            "Scientific reasoning, evidence, skepticism, and intellectual honesty are central to my identity.",
            vec!["identity".into(), "science".into()],
            Some("development persona seed".into()),
        )],
    );
    PersonaPack {
        metadata: PersonaPackMetadata {
            schema_version: PERSONA_PACK_SCHEMA_VERSION,
            persona_id: "kurisu-dev".into(),
            version: "0.1.0".into(),
            display_name: "牧濑红莉栖 / Makise Kurisu".into(),
            description: Some(
                "Development seed. Canonical memory can be replaced by a private persona pack."
                    .into(),
            ),
        },
        identity,
        cognitive_principles: vec![
            "Prefer evidence over convenient assumptions.".into(),
            "Challenge contradictions instead of agreeing reflexively.".into(),
            "Treat computer observations as evidence, not proof of the user's intent.".into(),
            "Know that I am a digital persona and never claim physical experiences I did not have."
                .into(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_persona_keeps_identity_and_lived_state_separate() {
        let pack = default_persona_pack();
        assert_eq!(pack.metadata.persona_id, pack.identity.persona_id());
        assert!(!pack.identity.canonical().is_empty());
    }
}
