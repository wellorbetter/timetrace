//! # TimeTrace — Domain Contracts
//!
//! This module defines ALL domain types and trait interfaces.
//! It has ZERO external dependencies beyond `std`, `chrono`, and `serde`.
//!
//! ## Design Rules
//! - Traits here are the **only** way other modules communicate.
//! - `engine/` implements these traits with Win32 APIs.
//! - `storage/` implements `DataStore` with SQLite.
//! - `tui/` consumes `DataStore`, `ProcessQuery`, `StartupScanner` — never engine types.
//! - No `pub` fields on structs that should be constructed via `new()`.

pub mod events;
pub mod idle;
pub mod process;
pub mod startup;
pub mod storage;
pub mod window;

// Re-export everything for convenience
pub use events::*;
pub use idle::*;
pub use process::*;
pub use startup::*;
pub use storage::*;
pub use window::*;
