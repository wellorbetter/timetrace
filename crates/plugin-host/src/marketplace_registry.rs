//! Crash-safe, non-executing registry for installed Marketplace packages.
//!
//! The registry deliberately records only an immutable package reference and
//! activation policy facts.  It never opens, verifies, or executes the archive:
//! a future activation boundary must re-verify the recorded archive each time.

use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
};

use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use timetrace_plugin_api::{
    ContributionDescriptor, DeclarativeV1Document, DesiredPluginState, MarketplaceReleaseSummary,
    PluginId, PluginManifest, PublisherId, RendererRef,
};

use crate::{
    MarketplaceArchiveVerifier, MarketplaceInstalledPackage, validate_marketplace_archive_members,
};

const SNAPSHOT_NAME: &str = ".marketplace-registry-v1.json";
const JOURNAL_NAME: &str = ".marketplace-registry-v1.journal";
const NEXT_SNAPSHOT_NAME: &str = ".marketplace-registry-v1.next";
const REGISTRY_SCHEMA_VERSION: u32 = 1;
const MAX_RECORDS: usize = 1_024;
const MAX_REGISTRY_BYTES: usize = 512 * 1_024;

/// Closed host policy state applied independently of the user's desired state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceInstalledPolicyState {
    /// The release may be considered by a future activation verifier.
    Allowed,
    /// Host or administrator policy blocks activation.
    Blocked,
    /// A signed remote policy observation is too old to authorize activation.
    PolicyExpired,
    /// The immutable marketplace release was revoked.
    Revoked,
}

impl MarketplaceInstalledPolicyState {
    /// Returns whether a future activation boundary may consider this record.
    #[must_use]
    pub const fn permits_activation(self) -> bool {
        matches!(self, Self::Allowed)
    }
}

/// One immutable, locally installed Marketplace package reference.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MarketplaceInstalledRecord {
    /// Stable plugin identity, unique in this registry.
    pub plugin_id: PluginId,
    /// Publisher bound to the reviewed release.
    pub publisher_id: PublisherId,
    /// Immutable marketplace release UUID.
    pub release_id: String,
    /// User-selected installed version.
    pub selected_version: Version,
    /// Lowercase SHA-256 of the exact installed archive.
    pub package_digest: String,
    /// Archive location relative to the registry root; never an arbitrary path.
    pub archive_rel_path: PathBuf,
    /// Persisted user preference, not sufficient to activate by itself.
    pub desired_state: DesiredPluginState,
    /// Independent host/marketplace activation policy.
    pub policy_state: MarketplaceInstalledPolicyState,
    /// Local receipt time (Unix milliseconds) of the signed catalog policy
    /// observation which produced `policy_state`.  Missing is intentionally
    /// treated as stale so registries written by older hosts fail closed.
    #[serde(default)]
    pub policy_refreshed_at_ms: Option<u64>,
}

impl MarketplaceInstalledRecord {
    /// Creates a registry record from an already verified, atomically installed release.
    pub fn from_installed_release(
        storage_root: &Path,
        release: &MarketplaceReleaseSummary,
        installed: &MarketplaceInstalledPackage,
        desired_state: DesiredPluginState,
        policy_state: MarketplaceInstalledPolicyState,
    ) -> Result<Self, MarketplaceRegistryError> {
        if installed.release_id != release.release_id {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        let relative = installed
            .archive_path
            .strip_prefix(storage_root)
            .map_err(|_| MarketplaceRegistryError::InvalidRecord)?
            .to_owned();
        let record = Self {
            plugin_id: release.identity.plugin_id.clone(),
            publisher_id: release.identity.publisher_id.clone(),
            release_id: release.release_id.clone(),
            selected_version: release.version.clone(),
            package_digest: release.package_digest.clone(),
            archive_rel_path: relative,
            desired_state,
            policy_state,
            policy_refreshed_at_ms: None,
        };
        record.validate()?;
        Ok(record)
    }

    /// Joins the validated relative path to the registry root.
    pub fn archive_path(&self, storage_root: &Path) -> Result<PathBuf, MarketplaceRegistryError> {
        self.validate()?;
        Ok(storage_root.join(&self.archive_rel_path))
    }

    /// Returns whether user preference and policy together permit consideration.
    #[must_use]
    pub fn activation_requested_and_permitted(&self) -> bool {
        self.desired_state == DesiredPluginState::Enabled && self.policy_state.permits_activation()
    }

    fn validate(&self) -> Result<(), MarketplaceRegistryError> {
        self.plugin_id
            .validate()
            .map_err(|_| MarketplaceRegistryError::InvalidRecord)?;
        self.publisher_id
            .validate()
            .map_err(|_| MarketplaceRegistryError::InvalidRecord)?;
        if !is_uuid(&self.release_id)
            || !is_sha256(&self.package_digest)
            || self.selected_version.to_string().len() > 128
            || !safe_relative_archive_path(self)
        {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        Ok(())
    }
}

/// Prepared registry replacement.  A restart may commit this replacement during recovery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedMarketplaceRegistryChange {
    snapshot: RegistrySnapshot,
}

/// Crash-safe registry rooted beside the installed archives.
#[derive(Debug, Clone)]
pub struct MarketplaceInstalledRegistry {
    root: PathBuf,
}

impl MarketplaceInstalledRegistry {
    /// Opens a registry rooted in the same host-owned directory as package archives.
    pub fn open(root: PathBuf) -> Result<Self, MarketplaceRegistryError> {
        fs::create_dir_all(&root).map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
        let registry = Self { root };
        registry.recover()?;
        Ok(registry)
    }

    /// Returns the host-owned root containing the snapshot and immutable archives.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Completes an interrupted prepared replacement.  The durable journal wins.
    pub fn recover(&self) -> Result<(), MarketplaceRegistryError> {
        let journal = self.journal_path();
        if !journal.exists() {
            return Ok(());
        }
        let prepared: RegistryJournal = read_json(&journal)?;
        prepared.validate()?;
        // A missing snapshot with a durable journal is the deliberate Windows
        // crash window: the old snapshot was removed before `.next` could be
        // renamed.  The journal is the only durable authority in that window.
        if !self.snapshot_path().exists() {
            return self.replace_snapshot_from_journal(&journal);
        }
        let current = self.read_snapshot_without_recovery()?;
        match current.revision.cmp(&prepared.base_revision) {
            std::cmp::Ordering::Equal => {
                ensure_no_downgrade(&current, &prepared.snapshot)?;
            }
            std::cmp::Ordering::Greater => {
                let outcome = ensure_no_downgrade(&current, &prepared.snapshot);
                // A newer committed snapshot has won the CAS race.  This local,
                // fully validated journal is stale and must not keep blocking use.
                fs::remove_file(&journal)
                    .map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
                return outcome.and(Err(MarketplaceRegistryError::PreparedChangeMismatch));
            }
            std::cmp::Ordering::Less => {
                return Err(MarketplaceRegistryError::PreparedChangeMismatch);
            }
        }
        self.replace_snapshot_from_journal(&journal)
    }

    /// Loads all records after first recovering any prepared replacement.
    pub fn load(&self) -> Result<Vec<MarketplaceInstalledRecord>, MarketplaceRegistryError> {
        self.recover()?;
        let snapshot_path = self.snapshot_path();
        if !snapshot_path.exists() {
            return Ok(Vec::new());
        }
        let snapshot: RegistrySnapshot = read_json(&snapshot_path)?;
        snapshot.validate()?;
        Ok(snapshot.records.into_values().collect())
    }

    /// Prepares insertion or replacement for exactly one plugin record.
    ///
    /// A prepared journal is durable and will be completed by [`Self::recover`]
    /// after a process crash; callers should invoke [`Self::commit`] promptly.
    pub fn prepare_install(
        &self,
        record: MarketplaceInstalledRecord,
    ) -> Result<PreparedMarketplaceRegistryChange, MarketplaceRegistryError> {
        record.validate()?;
        let mut snapshot = self.snapshot()?;
        ensure_candidate_not_downgrade(&snapshot, &record)?;
        let base_revision = snapshot.revision;
        snapshot.revision = snapshot
            .revision
            .checked_add(1)
            .ok_or(MarketplaceRegistryError::StorageUnavailable)?;
        snapshot
            .records
            .insert(record.plugin_id.to_string(), record);
        snapshot.validate()?;
        self.write_journal(base_revision, &snapshot)?;
        Ok(PreparedMarketplaceRegistryChange { snapshot })
    }

    /// Atomically completes a previously prepared replacement.
    pub fn commit(
        &self,
        prepared: PreparedMarketplaceRegistryChange,
    ) -> Result<(), MarketplaceRegistryError> {
        prepared.snapshot.validate()?;
        let journal_path = self.journal_path();
        if !journal_path.exists() {
            let current = self.read_snapshot_without_recovery()?;
            ensure_no_downgrade(&current, &prepared.snapshot)?;
            return Err(MarketplaceRegistryError::PreparedChangeMismatch);
        }
        let journal: RegistryJournal = read_json(&journal_path)?;
        journal.validate()?;
        if journal.snapshot != prepared.snapshot {
            let current = self.read_snapshot_without_recovery()?;
            ensure_no_downgrade(&current, &prepared.snapshot)?;
            return Err(MarketplaceRegistryError::PreparedChangeMismatch);
        }
        let current = self.read_snapshot_without_recovery()?;
        if current.revision != journal.base_revision {
            ensure_no_downgrade(&current, &journal.snapshot)?;
            return Err(MarketplaceRegistryError::PreparedChangeMismatch);
        }
        self.replace_snapshot_from_journal(&journal_path)
    }

    /// Persists the user's desired state without weakening a blocking policy state.
    pub fn set_desired_state(
        &self,
        plugin_id: &PluginId,
        desired_state: DesiredPluginState,
    ) -> Result<(), MarketplaceRegistryError> {
        self.change(plugin_id, |record| record.desired_state = desired_state)
    }

    /// Persists the closed host policy state independently of user preference.
    pub fn set_policy_state(
        &self,
        plugin_id: &PluginId,
        policy_state: MarketplaceInstalledPolicyState,
    ) -> Result<(), MarketplaceRegistryError> {
        self.change(plugin_id, |record| record.policy_state = policy_state)
    }

    /// Atomically projects one complete, root-signed catalog observation.
    /// Records absent from the observation must be supplied as
    /// `PolicyExpired` by the caller; this avoids carrying forward an old
    /// authorization after pagination, revocation, or a failed refresh.
    pub fn apply_policy_observation(
        &self,
        states: &[(PluginId, MarketplaceInstalledPolicyState)],
        observed_at_ms: u64,
    ) -> Result<(), MarketplaceRegistryError> {
        let mut snapshot = self.snapshot()?;
        for (plugin_id, state) in states {
            let record = snapshot
                .records
                .get_mut(plugin_id.as_str())
                .ok_or(MarketplaceRegistryError::NotInstalled)?;
            record.policy_state = *state;
            record.policy_refreshed_at_ms = Some(observed_at_ms);
        }
        let base_revision = snapshot.revision;
        snapshot.revision = snapshot
            .revision
            .checked_add(1)
            .ok_or(MarketplaceRegistryError::StorageUnavailable)?;
        snapshot.validate()?;
        self.write_journal(base_revision, &snapshot)?;
        self.replace_snapshot_from_journal(&self.journal_path())
    }

    fn change(
        &self,
        plugin_id: &PluginId,
        change: impl FnOnce(&mut MarketplaceInstalledRecord),
    ) -> Result<(), MarketplaceRegistryError> {
        let mut snapshot = self.snapshot()?;
        let record = snapshot
            .records
            .get_mut(plugin_id.as_str())
            .ok_or(MarketplaceRegistryError::NotInstalled)?;
        change(record);
        let base_revision = snapshot.revision;
        snapshot.revision = snapshot
            .revision
            .checked_add(1)
            .ok_or(MarketplaceRegistryError::StorageUnavailable)?;
        snapshot.validate()?;
        self.write_journal(base_revision, &snapshot)?;
        self.replace_snapshot_from_journal(&self.journal_path())
    }

    fn snapshot(&self) -> Result<RegistrySnapshot, MarketplaceRegistryError> {
        self.recover()?;
        self.read_snapshot_without_recovery()
    }

    fn read_snapshot_without_recovery(&self) -> Result<RegistrySnapshot, MarketplaceRegistryError> {
        let path = self.snapshot_path();
        if path.exists() {
            let snapshot: RegistrySnapshot = read_json(&path)?;
            snapshot.validate()?;
            Ok(snapshot)
        } else {
            Ok(RegistrySnapshot::empty())
        }
    }

    fn write_journal(
        &self,
        base_revision: u64,
        snapshot: &RegistrySnapshot,
    ) -> Result<(), MarketplaceRegistryError> {
        let journal = self.journal_path();
        if journal.exists() {
            return Err(MarketplaceRegistryError::StorageUnavailable);
        }
        let value = RegistryJournal {
            schema_version: REGISTRY_SCHEMA_VERSION,
            base_revision,
            snapshot: snapshot.clone(),
        };
        let bytes =
            serde_json::to_vec(&value).map_err(|_| MarketplaceRegistryError::InvalidRecord)?;
        if bytes.len() > MAX_REGISTRY_BYTES {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(journal)
            .map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| MarketplaceRegistryError::StorageUnavailable)
    }

    fn replace_snapshot_from_journal(
        &self,
        journal: &Path,
    ) -> Result<(), MarketplaceRegistryError> {
        let prepared: RegistryJournal = read_json(journal)?;
        prepared.validate()?;
        let bytes = serde_json::to_vec(&prepared.snapshot)
            .map_err(|_| MarketplaceRegistryError::InvalidRecord)?;
        if bytes.len() > MAX_REGISTRY_BYTES {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        let next = self.next_snapshot_path();
        match fs::remove_file(&next) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return Err(MarketplaceRegistryError::StorageUnavailable),
        }
        let mut next_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&next)
            .map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
        next_file
            .write_all(&bytes)
            .and_then(|()| next_file.sync_all())
            .map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
        let snapshot = self.snapshot_path();
        // Windows does not replace an existing destination with rename.  Deleting
        // it is safe because the fsynced journal contains the complete next state;
        // any interruption leaves that journal for `recover` to replay.
        match fs::remove_file(&snapshot) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return Err(MarketplaceRegistryError::StorageUnavailable),
        }
        fs::rename(&next, snapshot).map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
        fs::remove_file(journal).map_err(|_| MarketplaceRegistryError::StorageUnavailable)
    }

    fn snapshot_path(&self) -> PathBuf {
        self.root.join(SNAPSHOT_NAME)
    }
    fn journal_path(&self) -> PathBuf {
        self.root.join(JOURNAL_NAME)
    }
    fn next_snapshot_path(&self) -> PathBuf {
        self.root.join(NEXT_SNAPSHOT_NAME)
    }
}

/// Re-verifies every activation-eligible record and returns only canonical
/// Marketplace manifests. This deliberately does not execute archive content.
///
/// The caller must reject the whole dynamic batch if this returns an error;
/// publishing a partial marketplace catalog could otherwise hide a collision or
/// a tampered installed package.
pub fn verified_marketplace_manifests<V: MarketplaceArchiveVerifier + ?Sized>(
    registry: &MarketplaceInstalledRegistry,
    verifier: &V,
) -> Result<Vec<PluginManifest>, MarketplaceActivationError> {
    let records = registry
        .load()
        .map_err(|_| MarketplaceActivationError::RegistryUnavailable)?;
    let mut manifests = Vec::new();
    for record in records {
        if !record.policy_state.permits_activation() {
            continue;
        }
        let path = record
            .archive_path(registry.root())
            .map_err(|_| MarketplaceActivationError::InvalidRecord)?;
        let digest = digest_file(&path)?;
        if digest != record.package_digest {
            return Err(MarketplaceActivationError::DigestMismatch);
        }
        let archive = verifier
            .verify_archive(&path)
            .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
        let manifest = archive.manifest;
        validate_marketplace_archive_members(&path, &manifest)
            .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
        if manifest.id != record.plugin_id
            || manifest.publisher != record.publisher_id
            || manifest.version != record.selected_version
        {
            return Err(MarketplaceActivationError::IdentityMismatch);
        }
        manifests.push(manifest);
    }
    Ok(manifests)
}

/// Loads only fixed-path, already signed declarative resources after verifying
/// each installed archive again. No caller-controlled archive path or resource
/// name is accepted.
pub fn verified_marketplace_declarative_documents<V: MarketplaceArchiveVerifier + ?Sized>(
    registry: &MarketplaceInstalledRegistry,
    verifier: &V,
) -> Result<
    BTreeMap<PluginId, BTreeMap<timetrace_plugin_api::ContributionId, DeclarativeV1Document>>,
    MarketplaceActivationError,
> {
    let records = registry
        .load()
        .map_err(|_| MarketplaceActivationError::RegistryUnavailable)?;
    let mut documents = BTreeMap::new();
    for record in records {
        if !record.policy_state.permits_activation() {
            continue;
        }
        let path = record
            .archive_path(registry.root())
            .map_err(|_| MarketplaceActivationError::InvalidRecord)?;
        if digest_file(&path)? != record.package_digest {
            return Err(MarketplaceActivationError::DigestMismatch);
        }
        let manifest = verifier
            .verify_archive(&path)
            .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?
            .manifest;
        validate_marketplace_archive_members(&path, &manifest)
            .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
        if manifest.id != record.plugin_id
            || manifest.publisher != record.publisher_id
            || manifest.version != record.selected_version
        {
            return Err(MarketplaceActivationError::IdentityMismatch);
        }
        // P2 is an entitlement for a renderer compiled into the host; it has
        // no declarative archive resources to parse or project here.
        if manifest
            .validate_marketplace_first_party_bundled_v1_profile()
            .is_ok()
        {
            continue;
        }
        let mut zip = zip::ZipArchive::new(
            fs::File::open(&path).map_err(|_| MarketplaceActivationError::ArchiveInvalid)?,
        )
        .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
        let mut plugin_documents = BTreeMap::new();
        for contribution in &manifest.contributions {
            let (id, declarative) = match contribution {
                ContributionDescriptor::Page(page) => (
                    &page.metadata.id,
                    matches!(page.renderer, RendererRef::DeclarativeV1),
                ),
                ContributionDescriptor::DashboardCard(card) => (
                    &card.metadata.id,
                    matches!(card.renderer, RendererRef::DeclarativeV1),
                ),
                _ => continue,
            };
            if !declarative {
                continue;
            }
            let resource = DeclarativeV1Document::resource_path(id);
            let mut entry = zip
                .by_name(&resource)
                .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
            let mut bytes = Vec::new();
            std::io::Read::by_ref(&mut entry)
                .take((timetrace_plugin_api::MAX_DECLARATIVE_V1_DOCUMENT_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
            let document = DeclarativeV1Document::parse_for_contribution(&bytes, id)
                .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
            if plugin_documents.insert(id.clone(), document).is_some() {
                return Err(MarketplaceActivationError::ArchiveInvalid);
            }
        }
        documents.insert(record.plugin_id, plugin_documents);
    }
    Ok(documents)
}

fn digest_file(path: &Path) -> Result<String, MarketplaceActivationError> {
    let mut file = fs::File::open(path).map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 32 * 1024];
    loop {
        let read = std::io::Read::read(&mut file, &mut buffer)
            .map_err(|_| MarketplaceActivationError::ArchiveInvalid)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

/// Stable failure for the non-executing Marketplace activation boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum MarketplaceActivationError {
    /// The crash-safe registry could not be loaded or recovered.
    #[error("marketplace registry is unavailable")]
    RegistryUnavailable,
    /// An installed registry record violated its path or identity invariants.
    #[error("marketplace registry record is invalid")]
    InvalidRecord,
    /// The exact immutable archive bytes no longer match the recorded digest.
    #[error("marketplace archive digest mismatch")]
    DigestMismatch,
    /// The archive no longer passes the package verifier.
    #[error("marketplace archive is invalid")]
    ArchiveInvalid,
    /// The re-verified manifest differs from the immutable registry identity.
    #[error("marketplace archive identity mismatch")]
    IdentityMismatch,
}

/// Stable, privacy-safe installed-registry errors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum MarketplaceRegistryError {
    /// A record, snapshot, or journal violated the strict v1 format.
    #[error("marketplace installed registry is invalid")]
    InvalidRecord,
    /// Local filesystem state could not be read, synced, renamed, or recovered.
    #[error("marketplace installed registry storage is unavailable")]
    StorageUnavailable,
    /// The requested plugin has no installed record.
    #[error("marketplace plugin is not installed")]
    NotInstalled,
    /// A different transaction replaced the prepared journal.
    #[error("marketplace prepared registry change does not match journal")]
    PreparedChangeMismatch,
    /// A lower version attempted to replace an installed higher version.
    #[error("marketplace version downgrade is blocked")]
    DowngradeBlocked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistryJournal {
    schema_version: u32,
    base_revision: u64,
    snapshot: RegistrySnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistrySnapshot {
    schema_version: u32,
    #[serde(default)]
    revision: u64,
    records: BTreeMap<String, MarketplaceInstalledRecord>,
}

impl RegistrySnapshot {
    fn empty() -> Self {
        Self {
            schema_version: REGISTRY_SCHEMA_VERSION,
            revision: 0,
            records: BTreeMap::new(),
        }
    }
    fn validate(&self) -> Result<(), MarketplaceRegistryError> {
        if self.schema_version != REGISTRY_SCHEMA_VERSION || self.records.len() > MAX_RECORDS {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        for (key, record) in &self.records {
            record.validate()?;
            if key != record.plugin_id.as_str() {
                return Err(MarketplaceRegistryError::InvalidRecord);
            }
        }
        Ok(())
    }
}

impl RegistryJournal {
    fn validate(&self) -> Result<(), MarketplaceRegistryError> {
        if self.schema_version != REGISTRY_SCHEMA_VERSION
            || self.snapshot.revision != self.base_revision.saturating_add(1)
        {
            return Err(MarketplaceRegistryError::InvalidRecord);
        }
        self.snapshot.validate()
    }
}

fn ensure_candidate_not_downgrade(
    current: &RegistrySnapshot,
    candidate: &MarketplaceInstalledRecord,
) -> Result<(), MarketplaceRegistryError> {
    if current
        .records
        .get(candidate.plugin_id.as_str())
        .is_some_and(|installed| candidate.selected_version < installed.selected_version)
    {
        return Err(MarketplaceRegistryError::DowngradeBlocked);
    }
    Ok(())
}

fn ensure_no_downgrade(
    current: &RegistrySnapshot,
    next: &RegistrySnapshot,
) -> Result<(), MarketplaceRegistryError> {
    for (plugin_id, next_record) in &next.records {
        if let Some(current_record) = current.records.get(plugin_id)
            && next_record.selected_version < current_record.selected_version
        {
            return Err(MarketplaceRegistryError::DowngradeBlocked);
        }
    }
    Ok(())
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, MarketplaceRegistryError> {
    let bytes = fs::read(path).map_err(|_| MarketplaceRegistryError::StorageUnavailable)?;
    if bytes.len() > MAX_REGISTRY_BYTES {
        return Err(MarketplaceRegistryError::InvalidRecord);
    }
    serde_json::from_slice(&bytes).map_err(|_| MarketplaceRegistryError::InvalidRecord)
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            matches!(index, 8 | 13 | 18 | 23)
                .then_some(byte == b'-')
                .unwrap_or_else(|| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        })
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn safe_relative_archive_path(record: &MarketplaceInstalledRecord) -> bool {
    let path = &record.archive_rel_path;
    if path.as_os_str().len() > 512
        || !path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
    {
        return false;
    }
    let expected = PathBuf::from("packages")
        .join(record.plugin_id.as_str())
        .join(record.selected_version.to_string())
        .join(format!("{}.ttx", record.package_digest));
    path == &expected
}

#[cfg(test)]
mod tests {
    use super::*;
    use semver::Version;
    use tempfile::tempdir;

    fn record(version: &str, digest: char) -> MarketplaceInstalledRecord {
        MarketplaceInstalledRecord {
            plugin_id: PluginId::new("sample-plugin").unwrap(),
            publisher_id: PublisherId::new("timetrace-labs").unwrap(),
            release_id: "123e4567-e89b-12d3-a456-426614174000".to_owned(),
            selected_version: Version::parse(version).unwrap(),
            package_digest: digest.to_string().repeat(64),
            archive_rel_path: PathBuf::from(format!(
                "packages/sample-plugin/{version}/{}.ttx",
                digest.to_string().repeat(64)
            )),
            desired_state: DesiredPluginState::Enabled,
            policy_state: MarketplaceInstalledPolicyState::Allowed,
            policy_refreshed_at_ms: Some(1),
        }
    }

    #[test]
    fn prepared_install_is_recovered_after_crash_before_commit() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let prepared = registry.prepare_install(record("1.0.0", 'a')).unwrap();
        assert!(temp.path().join(JOURNAL_NAME).exists());
        drop(prepared);
        let reopened = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        assert_eq!(reopened.load().unwrap(), vec![record("1.0.0", 'a')]);
        assert!(!temp.path().join(JOURNAL_NAME).exists());
    }

    #[test]
    fn journal_recovers_after_windows_delete_before_rename() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let first = registry.prepare_install(record("1.0.0", 'a')).unwrap();
        registry.commit(first).unwrap();
        let _second = registry.prepare_install(record("2.0.0", 'b')).unwrap();
        fs::remove_file(temp.path().join(SNAPSHOT_NAME)).unwrap();
        let reopened = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        assert_eq!(reopened.load().unwrap(), vec![record("2.0.0", 'b')]);
    }

    #[test]
    fn same_version_different_digest_is_an_explicit_record_replacement() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let first = registry.prepare_install(record("1.0.0", 'a')).unwrap();
        registry.commit(first).unwrap();
        let second = registry.prepare_install(record("1.0.0", 'b')).unwrap();
        registry.commit(second).unwrap();
        assert_eq!(registry.load().unwrap(), vec![record("1.0.0", 'b')]);
    }

    #[test]
    fn lower_version_is_blocked_after_a_higher_version_commits() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let higher = registry.prepare_install(record("2.0.0", 'b')).unwrap();
        registry.commit(higher).unwrap();
        assert_eq!(
            registry.prepare_install(record("1.0.0", 'a')),
            Err(MarketplaceRegistryError::DowngradeBlocked)
        );
        assert_eq!(registry.load().unwrap(), vec![record("2.0.0", 'b')]);
    }

    #[test]
    fn concurrent_empty_registry_interleaving_converges_on_higher_version() {
        let temp = tempdir().unwrap();
        let first = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let second = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let pending_higher = first.prepare_install(record("2.0.0", 'b')).unwrap();
        // The second handle observes and recovers the durable first journal
        // before it considers its lower candidate.
        assert_eq!(
            second.prepare_install(record("1.0.0", 'a')),
            Err(MarketplaceRegistryError::DowngradeBlocked)
        );
        // The original caller's pre-crash prepared handle cannot overwrite the
        // recovered version either; the higher record remains authoritative.
        assert_eq!(
            first.commit(pending_higher),
            Err(MarketplaceRegistryError::PreparedChangeMismatch)
        );
        assert_eq!(second.load().unwrap(), vec![record("2.0.0", 'b')]);
    }

    #[test]
    fn policy_block_remains_effective_when_user_enables_plugin() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let mut item = record("1.0.0", 'a');
        item.desired_state = DesiredPluginState::Disabled;
        item.policy_state = MarketplaceInstalledPolicyState::Blocked;
        let prepared = registry.prepare_install(item).unwrap();
        registry.commit(prepared).unwrap();
        registry
            .set_desired_state(
                &PluginId::new("sample-plugin").unwrap(),
                DesiredPluginState::Enabled,
            )
            .unwrap();
        let loaded = registry.load().unwrap().pop().unwrap();
        assert_eq!(loaded.desired_state, DesiredPluginState::Enabled);
        assert_eq!(
            loaded.policy_state,
            MarketplaceInstalledPolicyState::Blocked
        );
        assert!(!loaded.activation_requested_and_permitted());
    }

    #[test]
    fn rejects_escape_paths_bad_digest_and_unknown_persistence_fields() {
        let temp = tempdir().unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let mut escape = record("1.0.0", 'a');
        escape.archive_rel_path = PathBuf::from("../outside.ttx");
        assert_eq!(
            registry.prepare_install(escape),
            Err(MarketplaceRegistryError::InvalidRecord)
        );
        let mut uppercase = record("1.0.0", 'a');
        uppercase.package_digest = "A".repeat(64);
        assert_eq!(
            registry.prepare_install(uppercase),
            Err(MarketplaceRegistryError::InvalidRecord)
        );
        fs::write(
            temp.path().join(SNAPSHOT_NAME),
            br#"{"schema_version":1,"records":{},"extra":true}"#,
        )
        .unwrap();
        assert_eq!(
            registry.load(),
            Err(MarketplaceRegistryError::InvalidRecord)
        );
    }
}
