use std::fs;
use std::sync::{Arc, Mutex, OnceLock};

use amadeus_core::{
    ensure_data_dir, memory_database_path, persona_pack_path, runtime_state_path,
    AmadeusRuntime, CanonicalMemory, IdentityMemory, JsonRuntimeStateStore,
    MemoryError, PersonaPack, PersonaPackMetadata, SqliteLivedMemoryStore,
    Trigger, TriggerAction, TriggerCondition, PERSONA_PACK_SCHEMA_VERSION,
};
use thiserror::Error;

pub type SharedAmadeusRuntime = Arc<Mutex<AmadeusRuntime<SqliteLivedMemoryStore>>>;

static SHARED_RUNTIME: OnceLock<SharedAmadeusRuntime> = OnceLock::new();
static STATE_STORE: OnceLock<JsonRuntimeStateStore> = OnceLock::new();

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
    }

    let runtime = Arc::new(Mutex::new(runtime));
    let _ = STATE_STORE.set(state_store);
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
