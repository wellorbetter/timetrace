//! TimeTrace Flutter bridge — generated bindings live in frb_generated.rs.

mod api;
pub mod frb_generated;

#[cfg(target_os = "windows")]
pub mod icons;

#[cfg(not(target_os = "windows"))]
pub mod icons {
    pub fn extract_icon_rgba(_path: &str) -> Option<(i32, i32, Vec<u8>)> { None }
}

pub use api::*;
