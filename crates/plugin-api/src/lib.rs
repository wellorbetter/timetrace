//! Canonical, transport-neutral contracts shared by TimeTrace plugin components.
//!
//! This crate intentionally performs no I/O and has no dependency on Flutter,
//! TimeTrace core storage, a plugin runtime, or a process transport.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod capability;
pub mod contribution;
pub mod declarative;
pub mod diagnostics;
pub mod error;
pub mod lifecycle;
pub mod manifest;
pub mod marketplace;
pub mod model;
pub mod query;
pub mod schema;

pub use capability::*;
pub use contribution::*;
pub use declarative::*;
pub use diagnostics::*;
pub use error::*;
pub use lifecycle::*;
pub use manifest::*;
pub use marketplace::*;
pub use model::*;
pub use query::*;
pub use schema::*;
