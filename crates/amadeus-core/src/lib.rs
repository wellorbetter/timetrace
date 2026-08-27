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

pub mod identity;
pub mod memory;
pub mod perception;

pub use identity::{CanonicalMemory, IdentityMemory};
pub use memory::{
    ActivitySpan, ComputerEpisode, EpisodeBuilder, LivedMemory, LivedMemoryKind,
    LivedMemorySource, LivedMemoryStore, MemoryCore, MemoryError, SqliteLivedMemoryStore,
};
pub use perception::{ComputerActivity, PerceptionEvent};
