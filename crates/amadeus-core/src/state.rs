use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::evolution::EvolutionCandidate;
use crate::persona::PersonaState;
use crate::trigger::Trigger;

pub const RUNTIME_STATE_SCHEMA_VERSION: u32 = 1;

/// Persisted state created only after persona activation.
///
/// Canonical identity is intentionally absent. A runtime-state restore can
/// recover relationship/persona dynamics, trigger configuration and evolution
/// history, but it can never rewrite the persona pack that defines "who I was".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuntimeStateSnapshot {
    pub schema_version: u32,
    pub persona_state: PersonaState,
    pub triggers: Vec<Trigger>,
    pub evolutions: Vec<EvolutionCandidate>,
}

impl Default for RuntimeStateSnapshot {
    fn default() -> Self {
        Self {
            schema_version: RUNTIME_STATE_SCHEMA_VERSION,
            persona_state: PersonaState::default(),
            triggers: Vec::new(),
            evolutions: Vec::new(),
        }
    }
}

#[derive(Debug, Error)]
pub enum RuntimeStateError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported runtime-state schema: {0}")]
    UnsupportedSchema(u32),
}

#[derive(Debug, Clone)]
pub struct JsonRuntimeStateStore {
    path: PathBuf,
}

impl JsonRuntimeStateStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<RuntimeStateSnapshot, RuntimeStateError> {
        if !self.path.exists() {
            return Ok(RuntimeStateSnapshot::default());
        }
        let snapshot: RuntimeStateSnapshot = serde_json::from_slice(&fs::read(&self.path)?)?;
        if snapshot.schema_version != RUNTIME_STATE_SCHEMA_VERSION {
            return Err(RuntimeStateError::UnsupportedSchema(snapshot.schema_version));
        }
        Ok(snapshot)
    }

    pub fn save(&self, snapshot: &RuntimeStateSnapshot) -> Result<(), RuntimeStateError> {
        if snapshot.schema_version != RUNTIME_STATE_SCHEMA_VERSION {
            return Err(RuntimeStateError::UnsupportedSchema(snapshot.schema_version));
        }
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(snapshot)?)?;
        if self.path.exists() {
            fs::remove_file(&self.path)?;
        }
        fs::rename(tmp, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evolution::{EvolutionDomain, EvolutionRisk, EvolutionStatus};
    use chrono::{DateTime, Utc};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn serialized_runtime_state_cannot_contain_canonical_identity() {
        let snapshot = RuntimeStateSnapshot {
            evolutions: vec![EvolutionCandidate {
                id: "skill-1".into(),
                domain: EvolutionDomain::Skill,
                risk: EvolutionRisk::Low,
                summary: "Prefer a learned debugging plan".into(),
                evidence: vec!["Repeated successful workflow".into()],
                confidence: 0.94,
                created_at: at(100),
                status: EvolutionStatus::Accepted,
            }],
            ..RuntimeStateSnapshot::default()
        };
        let json = serde_json::to_string(&snapshot).unwrap();
        assert!(!json.contains("canonical"));
        assert!(!json.contains("memory_boundary"));
        assert!(!json.contains("persona_id"));
    }
}
