//! Bounded loading for untrusted canonical plugin manifests.

use std::str;

use thiserror::Error;
use timetrace_plugin_api::PluginManifest;

/// Maximum encoded size accepted for one untrusted plugin manifest.
pub const MAX_MANIFEST_BYTES: usize = 256 * 1_024;

/// Loads and validates one canonical plugin manifest from untrusted bytes.
///
/// The encoded-size check runs before UTF-8 decoding or JSON deserialization.
/// Returned errors intentionally contain neither the input payload nor a file
/// path; filesystem discovery remains the caller's responsibility.
pub fn load_plugin_manifest(bytes: &[u8]) -> Result<PluginManifest, ManifestLoadError> {
    if bytes.len() > MAX_MANIFEST_BYTES {
        return Err(ManifestLoadError::TooLarge {
            limit: MAX_MANIFEST_BYTES,
        });
    }
    let source = str::from_utf8(bytes).map_err(|_| ManifestLoadError::InvalidUtf8)?;
    let manifest = serde_json::from_str::<PluginManifest>(source)
        .map_err(|_| ManifestLoadError::InvalidJson)?;
    manifest
        .validate_basic()
        .map_err(|_| ManifestLoadError::InvalidManifest)?;
    Ok(manifest)
}

/// Stable, privacy-safe manifest loading failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ManifestLoadError {
    /// The encoded manifest exceeded the pre-deserialization byte cap.
    #[error("plugin manifest exceeds the encoded size limit of {limit} bytes")]
    TooLarge {
        /// Maximum accepted encoded byte count.
        limit: usize,
    },
    /// The bounded input was not valid UTF-8.
    #[error("plugin manifest is not valid UTF-8")]
    InvalidUtf8,
    /// The bounded UTF-8 input was not canonical manifest JSON.
    #[error("plugin manifest JSON is invalid")]
    InvalidJson,
    /// The decoded manifest failed canonical semantic validation.
    #[error("plugin manifest failed canonical validation")]
    InvalidManifest,
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_MANIFEST: &str = r#"{
        "schema_version": 1,
        "id": "sample-plugin",
        "publisher": "timetrace-labs",
        "display_name": "Sample Plugin",
        "version": "1.0.0",
        "host_api": ">=1.0.0, <2.0.0",
        "platforms": ["windows_x64"]
    }"#;

    #[test]
    fn rejects_cap_plus_one_before_utf8_or_json_parsing() {
        let oversized_invalid_input = vec![0xff; MAX_MANIFEST_BYTES + 1];

        assert_eq!(
            load_plugin_manifest(&oversized_invalid_input),
            Err(ManifestLoadError::TooLarge {
                limit: MAX_MANIFEST_BYTES,
            })
        );
    }

    #[test]
    fn rejects_malformed_json_without_echoing_input() {
        let error = load_plugin_manifest(br#"{"schema_version": "private-value"#)
            .expect_err("malformed JSON must fail");

        assert_eq!(error, ManifestLoadError::InvalidJson);
        assert!(!error.to_string().contains("private-value"));
    }

    #[test]
    fn rejects_semantically_invalid_manifest() {
        let invalid = VALID_MANIFEST.replacen("\"schema_version\": 1", "\"schema_version\": 2", 1);

        assert_eq!(
            load_plugin_manifest(invalid.as_bytes()),
            Err(ManifestLoadError::InvalidManifest)
        );
    }

    #[test]
    fn accepts_valid_canonical_manifest() {
        let manifest = load_plugin_manifest(VALID_MANIFEST.as_bytes()).expect("valid manifest");

        assert_eq!(manifest.id.as_str(), "sample-plugin");
        assert_eq!(manifest.schema_version, 1);
    }
}
