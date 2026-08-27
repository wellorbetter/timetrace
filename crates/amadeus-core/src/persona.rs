use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::identity::IdentityMemory;

pub const PERSONA_PACK_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersonaPackMetadata {
    pub schema_version: u32,
    pub persona_id: String,
    pub version: String,
    pub display_name: String,
    pub description: Option<String>,
}

/// Versioned, protected persona seed.
///
/// A persona pack answers "who was I before activation?". It is loaded once
/// and never receives ordinary runtime writes. New experiences must go into
/// lived memory or mutable [`PersonaState`] instead.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersonaPack {
    pub metadata: PersonaPackMetadata,
    pub identity: IdentityMemory,
    /// Stable reasoning/behavioral principles distilled from the persona's
    /// canonical experiences. These are guidance, not mutable relationship
    /// state and not conversation history.
    pub cognitive_principles: Vec<String>,
}

#[derive(Debug, Error)]
pub enum PersonaPackError {
    #[error("invalid persona pack json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported persona pack schema: {0}")]
    UnsupportedSchema(u32),
    #[error("persona id mismatch: metadata={metadata}, identity={identity}")]
    PersonaIdMismatch { metadata: String, identity: String },
}

impl PersonaPack {
    pub fn from_json(input: &str) -> Result<Self, PersonaPackError> {
        let pack: Self = serde_json::from_str(input)?;
        pack.validate()?;
        Ok(pack)
    }

    pub fn to_json_pretty(&self) -> Result<String, PersonaPackError> {
        self.validate()?;
        Ok(serde_json::to_string_pretty(self)?)
    }

    pub fn validate(&self) -> Result<(), PersonaPackError> {
        if self.metadata.schema_version != PERSONA_PACK_SCHEMA_VERSION {
            return Err(PersonaPackError::UnsupportedSchema(
                self.metadata.schema_version,
            ));
        }
        if self.metadata.persona_id != self.identity.persona_id() {
            return Err(PersonaPackError::PersonaIdMismatch {
                metadata: self.metadata.persona_id.clone(),
                identity: self.identity.persona_id().to_owned(),
            });
        }
        Ok(())
    }

    pub fn into_identity(self) -> IdentityMemory {
        self.identity
    }
}

/// Mutable state produced by life after activation.
///
/// These values affect initiative and tone but do not redefine canonical
/// identity. They can evolve, be persisted, audited, and rolled back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PersonaState {
    familiarity: f32,
    engagement: f32,
    curiosity: f32,
    concern: f32,
    annoyance: f32,
    updated_at: DateTime<Utc>,
}

impl Default for PersonaState {
    fn default() -> Self {
        Self {
            familiarity: 0.0,
            engagement: 0.5,
            curiosity: 0.5,
            concern: 0.0,
            annoyance: 0.0,
            updated_at: Utc::now(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct PersonaStateDelta {
    pub familiarity: f32,
    pub engagement: f32,
    pub curiosity: f32,
    pub concern: f32,
    pub annoyance: f32,
}

impl PersonaState {
    pub fn familiarity(&self) -> f32 {
        self.familiarity
    }

    pub fn engagement(&self) -> f32 {
        self.engagement
    }

    pub fn curiosity(&self) -> f32 {
        self.curiosity
    }

    pub fn concern(&self) -> f32 {
        self.concern
    }

    pub fn annoyance(&self) -> f32 {
        self.annoyance
    }

    pub fn updated_at(&self) -> DateTime<Utc> {
        self.updated_at
    }

    pub fn apply_delta(&mut self, delta: PersonaStateDelta) {
        self.apply_delta_at(delta, Utc::now());
    }

    pub fn apply_delta_at(&mut self, delta: PersonaStateDelta, at: DateTime<Utc>) {
        self.familiarity = unit(self.familiarity + delta.familiarity);
        self.engagement = unit(self.engagement + delta.engagement);
        self.curiosity = unit(self.curiosity + delta.curiosity);
        self.concern = unit(self.concern + delta.concern);
        self.annoyance = unit(self.annoyance + delta.annoyance);
        self.updated_at = at;
    }
}

fn unit(value: f32) -> f32 {
    value.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::CanonicalMemory;

    fn pack() -> PersonaPack {
        PersonaPack {
            metadata: PersonaPackMetadata {
                schema_version: PERSONA_PACK_SCHEMA_VERSION,
                persona_id: "scientist".into(),
                version: "1.0.0".into(),
                display_name: "Scientist".into(),
                description: None,
            },
            identity: IdentityMemory::from_persona_pack(
                "scientist",
                "Scientist",
                None,
                vec![CanonicalMemory::new(
                    "origin",
                    "Scientific reasoning is a core part of my pre-activation identity.",
                    vec!["identity".into()],
                    None,
                )],
            ),
            cognitive_principles: vec!["Prefer evidence over convenient assumptions.".into()],
        }
    }

    #[test]
    fn persona_pack_round_trips_without_becoming_lived_memory() {
        let original = pack();
        let json = original.to_json_pretty().unwrap();
        let decoded = PersonaPack::from_json(&json).unwrap();
        assert_eq!(decoded, original);
        assert_eq!(decoded.identity.canonical().len(), 1);
    }

    #[test]
    fn persona_state_evolves_without_mutating_identity() {
        let original = pack();
        let identity_before = original.identity.clone();
        let mut state = PersonaState::default();
        state.apply_delta_at(
            PersonaStateDelta {
                familiarity: 0.4,
                curiosity: 0.3,
                annoyance: 2.0,
                ..PersonaStateDelta::default()
            },
            DateTime::from_timestamp(100, 0).unwrap(),
        );

        assert_eq!(state.familiarity(), 0.4);
        assert_eq!(state.curiosity(), 0.8);
        assert_eq!(state.annoyance(), 1.0);
        assert_eq!(original.identity, identity_before);
    }
}
