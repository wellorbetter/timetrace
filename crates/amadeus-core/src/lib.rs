//! Amadeus core runtime primitives.
//!
//! The core deliberately separates two kinds of memory:
//! - [`identity::IdentityMemory`]: canonical memories that explain who the
//!   persona already is before meeting the current user.
//! - [`memory::LivedMemoryStore`]: experiences accumulated after activation,
//!   including computer activity, conversations, relationship changes and
//!   reflections.
//!
//! TimeTrace is not a dependency of this crate. Existing TimeTrace observers
//! can adapt their events into [`perception::PerceptionEvent`] during migration,
//! while Amadeus remains usable with any future native observer.

pub mod evolution;
pub mod identity;
pub mod memory;
pub mod paths;
pub mod perception;
pub mod persona;
pub mod runtime;
pub mod skills;
pub mod trigger;

pub use evolution::{
    EvolutionCandidate, EvolutionDecision, EvolutionDomain, EvolutionPolicy,
    EvolutionRisk, EvolutionStatus,
};
pub use identity::{CanonicalMemory, IdentityMemory};
pub use memory::{
    ActivitySpan, ComputerEpisode, EpisodeBuilder, LivedMemory, LivedMemoryKind,
    LivedMemorySource, LivedMemoryStore, MemoryCore, MemoryError,
    SqliteLivedMemoryStore,
};
pub use paths::{data_dir, ensure_data_dir, memory_database_path, AMADEUS_DIR_NAME};
pub use perception::{ComputerActivity, PerceptionEvent};
pub use persona::{
    PersonaPack, PersonaPackError, PersonaPackMetadata, PersonaState,
    PersonaStateDelta, PERSONA_PACK_SCHEMA_VERSION,
};
pub use runtime::{AmadeusRuntime, RuntimeEffect};
pub use skills::{
    SkillDescriptor, SkillRegistry, SkillRegistryError, SkillRisk, SkillSource,
};
pub use trigger::{
    Trigger, TriggerAction, TriggerCondition, TriggerEngine, TriggeredAction,
};
