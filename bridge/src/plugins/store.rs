//! Bounded atomic persistence for host-owned plugin lifecycle preferences.

use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use timetrace_plugin_api::{DesiredPluginState, PluginId};
use timetrace_plugin_host::{LifecycleStateStore, LifecycleStoreError, PersistedLifecycleState};

const FILE_SCHEMA_VERSION: u32 = 1;
const MAX_STATE_FILE_BYTES: u64 = 64 * 1024;
const MAX_PERSISTED_PLUGINS: usize = 256;
const LEGACY_BUNDLED_PLUGIN_ID: &str = "private-flight";
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedFile {
    schema_version: u32,
    plugins: BTreeMap<String, PersistedPlugin>,
}

impl Default for PersistedFile {
    fn default() -> Self {
        Self {
            schema_version: FILE_SCHEMA_VERSION,
            plugins: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedPlugin {
    desired_state: DesiredPluginState,
    consecutive_start_failures: u32,
}

/// File-backed lifecycle preference store with bounded reads and atomic writes.
pub(super) struct FileLifecycleStateStore {
    path: PathBuf,
    state: Mutex<PersistedFile>,
    lock_file: Option<File>,
}

impl FileLifecycleStateStore {
    /// Creates a store and parses its bounded state file exactly once.
    pub(super) fn new(path: PathBuf) -> Self {
        let needs_legacy_import = !path.exists();
        let lock_file = acquire_lock(&path);
        let state = match lock_file.as_ref().map(|_| read_file(&path)) {
            Some(Ok(state)) if needs_legacy_import => read_legacy_state(&path).unwrap_or(state),
            Some(Ok(state)) => state,
            None | Some(Err(_)) => {
                tracing::warn!(
                    event = "plugin_state_load_failed",
                    error_code = "plugin_state_unavailable",
                    status = "defaulted_disabled"
                );
                PersistedFile::default()
            }
        };
        let store = Self {
            path,
            state: Mutex::new(state.clone()),
            lock_file,
        };
        if needs_legacy_import && !state.plugins.is_empty() {
            // Best-effort one-time migration. Failure leaves the imported
            // in-memory value active and retries from the legacy file at the
            // next launch without weakening fail-closed parsing.
            let _ = store.write_unlocked(&state);
        }
        store
    }

    fn write_unlocked(&self, state: &PersistedFile) -> Result<(), LifecycleStoreError> {
        if self.lock_file.is_none() {
            return Err(LifecycleStoreError::Unavailable);
        }
        let bytes = serde_json::to_vec(state).map_err(|_| LifecycleStoreError::Unavailable)?;
        if bytes.len() as u64 > MAX_STATE_FILE_BYTES {
            return Err(LifecycleStoreError::Unavailable);
        }
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = parent.join(format!(
            ".plugin-state.{}.{}.tmp",
            std::process::id(),
            sequence
        ));
        let write_result = (|| {
            let mut temp = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&temp_path)
                .map_err(|_| LifecycleStoreError::Unavailable)?;
            temp.write_all(&bytes)
                .and_then(|()| temp.sync_all())
                .map_err(|_| LifecycleStoreError::Unavailable)?;
            atomic_replace(&temp_path, &self.path)
        })();
        if write_result.is_err() {
            let _ = std::fs::remove_file(&temp_path);
        }
        write_result
    }
}

fn acquire_lock(state_path: &Path) -> Option<File> {
    let parent = state_path.parent().unwrap_or_else(|| Path::new("."));
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(parent.join(".plugin-state.lock"))
        .ok()?;
    FileExt::try_lock_exclusive(&file).ok()?;
    Some(file)
}

impl LifecycleStateStore for FileLifecycleStateStore {
    fn load(
        &self,
        plugin_id: &PluginId,
    ) -> Result<Option<PersistedLifecycleState>, LifecycleStoreError> {
        let state = self
            .state
            .lock()
            .map_err(|_| LifecycleStoreError::Unavailable)?;
        Ok(state.plugins.get(plugin_id.as_str()).map(|state| {
            PersistedLifecycleState::new(state.desired_state, state.consecutive_start_failures)
        }))
    }

    fn save(
        &self,
        plugin_id: &PluginId,
        state: PersistedLifecycleState,
    ) -> Result<(), LifecycleStoreError> {
        let mut current = self
            .state
            .lock()
            .map_err(|_| LifecycleStoreError::Unavailable)?;
        let mut file = current.clone();
        if !file.plugins.contains_key(plugin_id.as_str())
            && file.plugins.len() >= MAX_PERSISTED_PLUGINS
        {
            return Err(LifecycleStoreError::Unavailable);
        }
        file.plugins.insert(
            plugin_id.to_string(),
            PersistedPlugin {
                desired_state: state.desired_state(),
                consecutive_start_failures: state.consecutive_start_failures(),
            },
        );
        self.write_unlocked(&file)?;
        *current = file;
        Ok(())
    }
}

fn read_file(path: &Path) -> Result<PersistedFile, LifecycleStoreError> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(PersistedFile::default());
        }
        Err(_) => return Err(LifecycleStoreError::Unavailable),
    };
    let mut bytes = Vec::new();
    file.take(MAX_STATE_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| LifecycleStoreError::Unavailable)?;
    if bytes.len() as u64 > MAX_STATE_FILE_BYTES {
        return Err(LifecycleStoreError::Unavailable);
    }
    let state: PersistedFile =
        serde_json::from_slice(&bytes).map_err(|_| LifecycleStoreError::Unavailable)?;
    if state.schema_version != FILE_SCHEMA_VERSION
        || state.plugins.len() > MAX_PERSISTED_PLUGINS
        || state
            .plugins
            .keys()
            .any(|plugin_id| PluginId::new(plugin_id.clone()).is_err())
    {
        return Err(LifecycleStoreError::Unavailable);
    }
    Ok(state)
}

fn read_legacy_state(state_path: &Path) -> Option<PersistedFile> {
    let parent = state_path.parent().unwrap_or_else(|| Path::new("."));
    let file = File::open(parent.join("ui_config.json")).ok()?;
    let mut bytes = Vec::new();
    file.take(MAX_STATE_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_STATE_FILE_BYTES {
        return None;
    }
    let root = serde_json::from_slice::<serde_json::Value>(&bytes).ok()?;
    let enabled = root
        .get("pluginEnabled")?
        .get(LEGACY_BUNDLED_PLUGIN_ID)?
        .as_bool()?;
    let mut state = PersistedFile::default();
    state.plugins.insert(
        LEGACY_BUNDLED_PLUGIN_ID.to_owned(),
        PersistedPlugin {
            desired_state: if enabled {
                DesiredPluginState::Enabled
            } else {
                DesiredPluginState::Disabled
            },
            consecutive_start_failures: 0,
        },
    );
    Some(state)
}

#[cfg(windows)]
fn atomic_replace(temp_path: &Path, target_path: &Path) -> Result<(), LifecycleStoreError> {
    use std::os::windows::ffi::OsStrExt;

    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let temp = temp_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let target = target_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both buffers are valid, immutable, NUL-terminated UTF-16 paths
    // for the duration of the Win32 call. The flags request atomic replacement
    // of an existing target and synchronous metadata flush before returning.
    let replaced = unsafe {
        MoveFileExW(
            temp.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if replaced == 0 {
        return Err(LifecycleStoreError::Unavailable);
    }
    Ok(())
}

#[cfg(not(windows))]
fn atomic_replace(temp_path: &Path, target_path: &Path) -> Result<(), LifecycleStoreError> {
    std::fs::rename(temp_path, target_path).map_err(|_| LifecycleStoreError::Unavailable)
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn consecutive_saves_atomically_replace_the_same_target() {
        let temp = TempDir::new().expect("temp dir");
        let path = temp.path().join("plugin-state.json");
        let store = FileLifecycleStateStore::new(path.clone());
        let plugin_id = PluginId::new("private-flight").expect("plugin id");
        store
            .save(
                &plugin_id,
                PersistedLifecycleState::new(DesiredPluginState::Enabled, 1),
            )
            .expect("first save");
        store
            .save(
                &plugin_id,
                PersistedLifecycleState::new(DesiredPluginState::Disabled, 2),
            )
            .expect("replacement save");
        drop(store);

        let rebuilt = FileLifecycleStateStore::new(path);
        let state = rebuilt
            .load(&plugin_id)
            .expect("load")
            .expect("persisted plugin");
        assert_eq!(state.desired_state(), DesiredPluginState::Disabled);
        assert_eq!(state.consecutive_start_failures(), 2);
    }

    #[test]
    fn a_second_store_cannot_overwrite_state_while_the_owner_is_alive() {
        let temp = TempDir::new().expect("temp dir");
        let path = temp.path().join("plugin-state.json");
        let owner = FileLifecycleStateStore::new(path.clone());
        let contender = FileLifecycleStateStore::new(path);
        let plugin_id = PluginId::new("private-flight").expect("plugin id");

        assert!(owner.lock_file.is_some());
        assert!(contender.lock_file.is_none());
        assert_eq!(
            contender.save(
                &plugin_id,
                PersistedLifecycleState::new(DesiredPluginState::Enabled, 0),
            ),
            Err(LifecycleStoreError::Unavailable)
        );
    }

    #[test]
    fn legacy_flutter_preference_is_imported_once_into_canonical_state() {
        let temp = TempDir::new().expect("temp dir");
        let path = temp.path().join("plugin-state.json");
        std::fs::write(
            temp.path().join("ui_config.json"),
            br#"{"version":1,"pluginEnabled":{"private-flight":true}}"#,
        )
        .expect("write legacy preference");
        let plugin_id = PluginId::new(LEGACY_BUNDLED_PLUGIN_ID).expect("plugin id");

        let store = FileLifecycleStateStore::new(path.clone());
        let imported = store
            .load(&plugin_id)
            .expect("load")
            .expect("imported state");
        assert_eq!(imported.desired_state(), DesiredPluginState::Enabled);
        assert!(path.exists());
        drop(store);

        std::fs::write(
            temp.path().join("ui_config.json"),
            br#"{"pluginEnabled":{"private-flight":false}}"#,
        )
        .expect("change legacy preference");
        let rebuilt = FileLifecycleStateStore::new(path);
        assert_eq!(
            rebuilt
                .load(&plugin_id)
                .expect("load canonical")
                .expect("canonical state")
                .desired_state(),
            DesiredPluginState::Enabled
        );
    }
}
