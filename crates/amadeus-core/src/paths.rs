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

pub fn ensure_data_dir() -> std::io::Result<PathBuf> {
    let path = data_dir();
    std::fs::create_dir_all(&path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_database_is_owned_by_amadeus() {
        let path = memory_database_path();
        assert_eq!(path.file_name().and_then(|value| value.to_str()), Some("amadeus.db"));
        assert!(path.components().any(|part| part.as_os_str() == AMADEUS_DIR_NAME));
    }
}
