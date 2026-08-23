//! Host-side catalog and permission enforcement for TimeTrace plugins.
//!
//! This crate is intentionally independent from filesystems, persistence,
//! Flutter, and any dynamic plugin runtime.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod catalog;
pub mod commit;
pub mod diagnostics;
pub mod lifecycle;
pub mod manifest_loader;
pub mod marketplace_install;
pub mod marketplace_registry;
pub mod permission;
pub mod projection;

pub use catalog::*;
pub use commit::*;
pub use diagnostics::*;
pub use lifecycle::*;
pub use manifest_loader::*;
pub use marketplace_install::*;
pub use marketplace_registry::*;
pub use permission::*;
pub use projection::*;
