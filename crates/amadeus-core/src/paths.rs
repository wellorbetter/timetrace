use std::path::PathBuf;

pub const AMADEUS_DIR_NAME: &str = "Amadeus";

/// Platform-native Amadeus data directory, independent from TimeTrace.
pub fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(AMADEUS_DIR_NAME)
}

pub fn memory_database_path() -> PathBuf {
    data_dir().join("amadeus.db")
}

/// Mutable post-activation state only. Canonical identity never lives here.
pub fn runtime_state_path() -> PathBuf {
    data_dir().join("runtime_state.json")
}

/// Optional user-selected persona pack. Loading it is explicit and its contents
/// remain outside normal runtime mutation paths.
pub fn persona_pack_path() -> PathBuf {
    data_dir().join("persona.json")
}

/// Model/provider configuration. Secrets should be supplied by environment or
/// OS credential storage; this JSON is intended for non-secret routing data.
pub fn model_config_path() -> PathBuf {
    data_dir().join("models.json")
}

pub fn ensure_data_dir() -> std::io::Result<PathBuf> {
    let path = data_dir();
    std::fs::create_dir_all(&path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_persistent_paths_are_owned_by_amadeus() {
        for path in [
            memory_database_path(),
            runtime_state_path(),
            persona_pack_path(),
            model_config_path(),
        ] {
            assert!(path.components().any(|part| part.as_os_str() == AMADEUS_DIR_NAME));
        }
        assert_eq!(
            memory_database_path().file_name().and_then(|value| value.to_str()),
            Some("amadeus.db")
        );
    }
}
