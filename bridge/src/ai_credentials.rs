//! DeepSeek credential storage with an operating-system-backed primary store.
//!
//! Production builds use Windows Credential Manager. The process environment
//! is a read-only compatibility fallback and is never copied automatically.

use zeroize::Zeroizing;

/// Production Credential Manager target for the DeepSeek API key.
pub const DEEPSEEK_CREDENTIAL_TARGET: &str = "com.wellorbetter.TimeTrace.DeepSeek.ApiKey";
/// Read-only compatibility environment variable.
pub const DEEPSEEK_ENVIRONMENT_VARIABLE: &str = "DEEPSEEK_API_KEY";
/// Maximum accepted UTF-8 API-key size for a Windows generic credential blob.
pub const MAX_API_KEY_BYTES: usize = 2560;

/// Safe credential origin exposed to settings without revealing key material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialOrigin {
    /// A key is stored in the operating-system credential vault.
    SecureStore,
    /// No stored key exists and the compatibility environment variable is used.
    LegacyEnvironment,
    /// No usable key is configured.
    None,
    /// The secure store failed and no allowed compatibility key was available.
    Unavailable,
}

impl CredentialOrigin {
    /// Stable string representation used by the Flutter bridge.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SecureStore => "secure_store",
            Self::LegacyEnvironment => "legacy_environment",
            Self::None => "none",
            Self::Unavailable => "unavailable",
        }
    }
}

/// A resolved key that zeroes its allocation when dropped.
pub struct ResolvedApiKey {
    /// Secret key material, if configured.
    pub key: Option<Zeroizing<String>>,
    /// Non-secret origin metadata.
    pub origin: CredentialOrigin,
    /// Whether secure credential operations were available during resolution.
    pub secure_storage_available: bool,
}

/// Redacted operating-system credential-store failure.
#[derive(Debug, thiserror::Error, Clone, Copy, PartialEq, Eq)]
pub enum CredentialError {
    /// The secure credential service is not available on this platform.
    #[error("secure credential storage is unavailable")]
    Unavailable,
    /// The stored blob is empty, too large, or not valid UTF-8.
    #[error("stored credential is invalid")]
    InvalidData,
    /// The operating system rejected the operation.
    #[error("credential operation failed")]
    Os(u32),
}

/// Narrow writable credential-store port.
pub trait SecureCredentialStore: Send + Sync {
    /// Reads a stored key into zeroizing memory.
    fn read(&self) -> Result<Option<Zeroizing<String>>, CredentialError>;
    /// Creates or atomically replaces the stored key.
    fn write(&self, key: &str) -> Result<(), CredentialError>;
    /// Deletes the stored key. Deleting a missing key succeeds.
    fn delete(&self) -> Result<(), CredentialError>;
}

/// Credential source used by the recap service.
pub trait ApiKeySource: Send + Sync {
    /// Resolves a stored key first, then the read-only environment fallback.
    fn resolve_deepseek_key(&self, allow_environment: bool) -> ResolvedApiKey;
    /// Reads only the legacy environment value for an explicit import action.
    fn read_environment_deepseek_key(&self) -> Option<Zeroizing<String>>;
    /// Creates or replaces the secure stored key.
    fn save_deepseek_key(&self, key: &str) -> Result<(), CredentialError>;
    /// Removes only the secure stored key; the environment remains untouched.
    fn delete_deepseek_key(&self) -> Result<(), CredentialError>;
}

/// Stored-first credential source with an environment compatibility fallback.
pub struct StoredOrEnvironmentApiKeySource {
    store: Box<dyn SecureCredentialStore>,
    environment_variable: String,
}

impl StoredOrEnvironmentApiKeySource {
    /// Creates the production source backed by Windows Credential Manager.
    pub fn production() -> Self {
        Self::new(
            Box::new(PlatformCredentialStore::new(
                DEEPSEEK_CREDENTIAL_TARGET.to_owned(),
            )),
            DEEPSEEK_ENVIRONMENT_VARIABLE.to_owned(),
        )
    }

    /// Creates a source over explicit ports, primarily for deterministic tests.
    pub fn new(store: Box<dyn SecureCredentialStore>, environment_variable: String) -> Self {
        Self {
            store,
            environment_variable,
        }
    }

    fn read_environment(&self) -> Option<Zeroizing<String>> {
        let raw = Zeroizing::new(std::env::var(&self.environment_variable).ok()?);
        normalize_key(raw.as_str())
    }
}

impl ApiKeySource for StoredOrEnvironmentApiKeySource {
    fn resolve_deepseek_key(&self, allow_environment: bool) -> ResolvedApiKey {
        match self.store.read() {
            Ok(Some(key)) => ResolvedApiKey {
                key: Some(key),
                origin: CredentialOrigin::SecureStore,
                secure_storage_available: true,
            },
            Ok(None) if allow_environment => match self.read_environment() {
                Some(key) => ResolvedApiKey {
                    key: Some(key),
                    origin: CredentialOrigin::LegacyEnvironment,
                    secure_storage_available: true,
                },
                None => ResolvedApiKey {
                    key: None,
                    origin: CredentialOrigin::None,
                    secure_storage_available: true,
                },
            },
            Ok(None) => ResolvedApiKey {
                key: None,
                origin: CredentialOrigin::None,
                secure_storage_available: true,
            },
            Err(_) if allow_environment => {
                tracing::warn!("secure DeepSeek credential read failed");
                match self.read_environment() {
                    Some(key) => ResolvedApiKey {
                        key: Some(key),
                        origin: CredentialOrigin::LegacyEnvironment,
                        secure_storage_available: false,
                    },
                    None => ResolvedApiKey {
                        key: None,
                        origin: CredentialOrigin::Unavailable,
                        secure_storage_available: false,
                    },
                }
            }
            Err(_) => {
                tracing::warn!("secure DeepSeek credential read failed");
                ResolvedApiKey {
                    key: None,
                    origin: CredentialOrigin::Unavailable,
                    secure_storage_available: false,
                }
            }
        }
    }

    fn read_environment_deepseek_key(&self) -> Option<Zeroizing<String>> {
        self.read_environment()
    }

    fn save_deepseek_key(&self, key: &str) -> Result<(), CredentialError> {
        let normalized = normalize_key(key).ok_or(CredentialError::InvalidData)?;
        self.store.write(normalized.as_str())
    }

    fn delete_deepseek_key(&self) -> Result<(), CredentialError> {
        self.store.delete()
    }
}

fn normalize_key(value: &str) -> Option<Zeroizing<String>> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_API_KEY_BYTES {
        return None;
    }
    Some(Zeroizing::new(trimmed.to_owned()))
}

/// Operating-system secure credential store.
pub struct PlatformCredentialStore {
    target: String,
    operation_lock: std::sync::Mutex<()>,
}

impl PlatformCredentialStore {
    /// Creates a store for one fixed credential target.
    pub fn new(target: String) -> Self {
        Self {
            target,
            operation_lock: std::sync::Mutex::new(()),
        }
    }
}

#[cfg(windows)]
impl SecureCredentialStore for PlatformCredentialStore {
    fn read(&self) -> Result<Option<Zeroizing<String>>, CredentialError> {
        let _guard = self
            .operation_lock
            .lock()
            .map_err(|_| CredentialError::Unavailable)?;
        windows_credentials::read(&self.target)
    }

    fn write(&self, key: &str) -> Result<(), CredentialError> {
        let _guard = self
            .operation_lock
            .lock()
            .map_err(|_| CredentialError::Unavailable)?;
        windows_credentials::write(&self.target, key)
    }

    fn delete(&self) -> Result<(), CredentialError> {
        let _guard = self
            .operation_lock
            .lock()
            .map_err(|_| CredentialError::Unavailable)?;
        windows_credentials::delete(&self.target)
    }
}

#[cfg(not(windows))]
impl SecureCredentialStore for PlatformCredentialStore {
    fn read(&self) -> Result<Option<Zeroizing<String>>, CredentialError> {
        let _ = &self.target;
        Err(CredentialError::Unavailable)
    }

    fn write(&self, _key: &str) -> Result<(), CredentialError> {
        Err(CredentialError::Unavailable)
    }

    fn delete(&self) -> Result<(), CredentialError> {
        Err(CredentialError::Unavailable)
    }
}

#[cfg(windows)]
mod windows_credentials {
    use std::ffi::c_void;
    use std::ptr;
    use std::slice;

    use windows_sys::Win32::Foundation::{ERROR_NOT_FOUND, GetLastError};
    use windows_sys::Win32::Security::Credentials::{
        CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree,
        CredReadW, CredWriteW,
    };
    use zeroize::Zeroizing;

    use super::{CredentialError, MAX_API_KEY_BYTES, normalize_key};

    struct CredentialGuard(*mut CREDENTIALW);

    impl Drop for CredentialGuard {
        fn drop(&mut self) {
            // SAFETY: CredReadW allocated this writable CREDENTIALW and the
            // guard uniquely owns it until CredFree. Windows guarantees the
            // advertised blob is part of that allocation, so overwrite the
            // secret bytes before releasing the native buffer.
            unsafe {
                let credential = &mut *self.0;
                if !credential.CredentialBlob.is_null() && credential.CredentialBlobSize > 0 {
                    ptr::write_bytes(
                        credential.CredentialBlob,
                        0,
                        credential.CredentialBlobSize as usize,
                    );
                }
                CredFree(self.0.cast::<c_void>());
            }
        }
    }

    pub(super) fn read(target: &str) -> Result<Option<Zeroizing<String>>, CredentialError> {
        let target = wide(target)?;
        let mut raw = ptr::null_mut::<CREDENTIALW>();
        // SAFETY: target is NUL-terminated and `raw` is a valid out pointer.
        let succeeded = unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut raw) };
        if succeeded == 0 {
            // SAFETY: GetLastError has no preconditions immediately after failure.
            let code = unsafe { GetLastError() };
            return if code == ERROR_NOT_FOUND {
                Ok(None)
            } else {
                Err(CredentialError::Os(code))
            };
        }
        if raw.is_null() {
            return Err(CredentialError::InvalidData);
        }
        let credential = CredentialGuard(raw);
        // SAFETY: the guarded CREDENTIALW remains alive and owns a blob of the
        // advertised size until CredFree runs at the end of this function.
        let record = unsafe { &*credential.0 };
        let size =
            usize::try_from(record.CredentialBlobSize).map_err(|_| CredentialError::InvalidData)?;
        if size == 0 || size > MAX_API_KEY_BYTES || record.CredentialBlob.is_null() {
            return Err(CredentialError::InvalidData);
        }
        // SAFETY: CredReadW guarantees CredentialBlobSize readable bytes.
        let copied = Zeroizing::new(unsafe {
            slice::from_raw_parts(record.CredentialBlob.cast_const(), size).to_vec()
        });
        let decoded =
            std::str::from_utf8(copied.as_slice()).map_err(|_| CredentialError::InvalidData)?;
        normalize_key(decoded)
            .ok_or(CredentialError::InvalidData)
            .map(Some)
    }

    pub(super) fn write(target: &str, key: &str) -> Result<(), CredentialError> {
        let mut target = wide(target)?;
        let mut username = wide("TimeTrace")?;
        let mut blob = Zeroizing::new(key.as_bytes().to_vec());
        let blob_size = u32::try_from(blob.len()).map_err(|_| CredentialError::InvalidData)?;
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            CredentialBlobSize: blob_size,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: username.as_mut_ptr(),
            ..CREDENTIALW::default()
        };
        // SAFETY: every pointer in credential refers to a live buffer for the
        // duration of the call; Windows copies the data before returning.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            // SAFETY: GetLastError has no preconditions immediately after failure.
            return Err(CredentialError::Os(unsafe { GetLastError() }));
        }
        Ok(())
    }

    pub(super) fn delete(target: &str) -> Result<(), CredentialError> {
        let target = wide(target)?;
        // SAFETY: target is a live NUL-terminated UTF-16 buffer.
        if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0 {
            // SAFETY: GetLastError has no preconditions immediately after failure.
            let code = unsafe { GetLastError() };
            if code != ERROR_NOT_FOUND {
                return Err(CredentialError::Os(code));
            }
        }
        Ok(())
    }

    fn wide(value: &str) -> Result<Vec<u16>, CredentialError> {
        if value.is_empty() || value.contains('\0') {
            return Err(CredentialError::InvalidData);
        }
        Ok(value.encode_utf16().chain(Some(0)).collect())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use zeroize::Zeroizing;

    use super::{
        ApiKeySource, CredentialError, CredentialOrigin, PlatformCredentialStore,
        SecureCredentialStore, StoredOrEnvironmentApiKeySource,
    };

    #[derive(Default)]
    struct MemoryStore {
        key: Arc<Mutex<Option<String>>>,
        fail_reads: bool,
    }

    impl SecureCredentialStore for MemoryStore {
        fn read(&self) -> Result<Option<Zeroizing<String>>, CredentialError> {
            if self.fail_reads {
                return Err(CredentialError::Unavailable);
            }
            Ok(self
                .key
                .lock()
                .expect("memory credential lock")
                .clone()
                .map(Zeroizing::new))
        }

        fn write(&self, key: &str) -> Result<(), CredentialError> {
            *self.key.lock().expect("memory credential lock") = Some(key.to_owned());
            Ok(())
        }

        fn delete(&self) -> Result<(), CredentialError> {
            *self.key.lock().expect("memory credential lock") = None;
            Ok(())
        }
    }

    #[test]
    fn stored_key_wins_and_save_replaces_without_exposing_material() {
        let key = Arc::new(Mutex::new(Some("stored-secret".to_owned())));
        let source = StoredOrEnvironmentApiKeySource::new(
            Box::new(MemoryStore {
                key: key.clone(),
                fail_reads: false,
            }),
            "TIMETRACE_TEST_MISSING_KEY".to_owned(),
        );

        let resolved = source.resolve_deepseek_key(true);
        assert_eq!(resolved.origin, CredentialOrigin::SecureStore);
        assert_eq!(
            resolved.key.as_deref().map(String::as_str),
            Some("stored-secret")
        );

        source
            .save_deepseek_key(" replacement ")
            .expect("replace key");
        assert_eq!(
            key.lock().expect("memory credential lock").as_deref(),
            Some("replacement")
        );
        source.delete_deepseek_key().expect("delete key");
        assert!(key.lock().expect("memory credential lock").is_none());
    }

    #[test]
    fn invalid_keys_are_rejected_before_secure_store_write() {
        let source = StoredOrEnvironmentApiKeySource::new(
            Box::new(MemoryStore::default()),
            "TIMETRACE_TEST_MISSING_KEY".to_owned(),
        );
        assert_eq!(
            source.save_deepseek_key("   "),
            Err(CredentialError::InvalidData)
        );
        assert_eq!(
            source.save_deepseek_key(&"x".repeat(super::MAX_API_KEY_BYTES + 1)),
            Err(CredentialError::InvalidData)
        );
    }

    #[test]
    fn legacy_environment_is_read_only_and_marked_for_explicit_migration() {
        struct EnvironmentCleanup(String);
        impl Drop for EnvironmentCleanup {
            fn drop(&mut self) {
                // SAFETY: this test owns a process-unique variable name.
                unsafe { std::env::remove_var(&self.0) };
            }
        }

        let variable = format!("TIMETRACE_TEST_DEEPSEEK_KEY_{}", std::process::id());
        let _cleanup = EnvironmentCleanup(variable.clone());
        // SAFETY: this test owns a process-unique variable name.
        unsafe { std::env::set_var(&variable, "legacy-synthetic-key") };
        let stored = Arc::new(Mutex::new(None));
        let source = StoredOrEnvironmentApiKeySource::new(
            Box::new(MemoryStore {
                key: stored.clone(),
                fail_reads: false,
            }),
            variable,
        );

        let resolved = source.resolve_deepseek_key(true);

        assert_eq!(resolved.origin, CredentialOrigin::LegacyEnvironment);
        assert!(resolved.secure_storage_available);
        assert_eq!(
            resolved.key.as_deref().map(String::as_str),
            Some("legacy-synthetic-key")
        );
        assert!(stored.lock().expect("memory credential lock").is_none());
        assert_eq!(
            source.resolve_deepseek_key(false).origin,
            CredentialOrigin::None
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_credential_manager_round_trip_replaces_and_deletes() {
        struct CredentialCleanup<'a>(&'a PlatformCredentialStore);
        impl Drop for CredentialCleanup<'_> {
            fn drop(&mut self) {
                let _ = self.0.delete();
            }
        }

        let target = format!(
            "com.wellorbetter.TimeTrace.Test.DeepSeek.ApiKey.{}",
            std::process::id()
        );
        let store = PlatformCredentialStore::new(target);
        let _cleanup = CredentialCleanup(&store);
        store.delete().expect("clear prior synthetic credential");
        assert!(store.read().expect("read missing credential").is_none());

        store
            .write("synthetic-first-key")
            .expect("write synthetic credential");
        assert_eq!(
            store
                .read()
                .expect("read synthetic credential")
                .as_deref()
                .map(String::as_str),
            Some("synthetic-first-key")
        );
        store
            .write("synthetic-replacement-key")
            .expect("replace synthetic credential");
        assert_eq!(
            store
                .read()
                .expect("read replaced credential")
                .as_deref()
                .map(String::as_str),
            Some("synthetic-replacement-key")
        );
        store.delete().expect("delete synthetic credential");
        assert!(store.read().expect("read deleted credential").is_none());
    }
}
