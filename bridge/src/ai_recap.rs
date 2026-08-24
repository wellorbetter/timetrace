//! Privacy-bounded DeepSeek recap service.
//!
//! The service accepts only aggregate application display names and active
//! durations from a narrow data source. Credentials, HTTP details, and the
//! full TimeTrace data store stay behind separate ports so neither Flutter nor
//! the recap orchestration can accidentally access sensitive records.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{ErrorKind, Read};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use chrono::{Datelike, Local, NaiveDate, SecondsFormat, Utc, Weekday};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use timetrace_core::DataStore;
use zeroize::Zeroizing;

use crate::ai_credentials::{
    ApiKeySource, CredentialError, CredentialOrigin, StoredOrEnvironmentApiKeySource,
};
use crate::ai_report_store::{AiReportStore, AiReportStoreError};

const API_URL: &str = "https://api.deepseek.com/chat/completions";
const MODELS_API_URL: &str = "https://api.deepseek.com/models";
const DEFAULT_MODEL: &str = "deepseek-v4-flash";
const PRO_MODEL: &str = "deepseek-v4-pro";
const PROVIDER_NAME: &str = "DeepSeek";
const MAX_APPS_SENT: usize = 12;
const MAX_APP_NAME_CHARS: usize = 80;
const MAX_REQUEST_BYTES: usize = 24 * 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_CONNECTION_RESPONSE_BYTES: usize = 16 * 1024;
const MAX_CONTENT_CHARS: usize = 12 * 1024;
const MAX_ITEMS: usize = 3;
const SPARSE_MIN_TOTAL_SECONDS: i64 = 30 * 60;

/// A privacy-safe aggregate usage row available to AI recap generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AggregateUsage {
    /// Application display name, never an executable path or window title.
    pub app_name: String,
    /// Active (non-idle) duration in seconds.
    pub active_seconds: i64,
}

/// Narrow read port that exposes only aggregate names and active durations.
pub trait AggregateUsageSource: Send + Sync {
    /// Reads aggregate usage for an inclusive local-calendar date range.
    fn read(&self, start: NaiveDate, end: NaiveDate) -> Vec<AggregateUsage>;
}

/// SQLite-backed aggregate usage adapter.
///
/// The adapter deliberately discards idle duration and executable paths at the
/// storage boundary before data reaches the recap service.
pub struct SqliteAggregateUsageSource {
    store: Arc<dyn DataStore>,
}

impl SqliteAggregateUsageSource {
    /// Creates an aggregate-only adapter over the application data store.
    pub fn new(store: Arc<dyn DataStore>) -> Self {
        Self { store }
    }
}

impl AggregateUsageSource for SqliteAggregateUsageSource {
    fn read(&self, start: NaiveDate, end: NaiveDate) -> Vec<AggregateUsage> {
        self.store
            .get_usage_split(start, end)
            .into_iter()
            .map(|row| AggregateUsage {
                app_name: row.app_name,
                active_seconds: row.active_seconds,
            })
            .collect()
    }
}

/// Redacted transport failures that can cross the service boundary safely.
#[derive(Debug, thiserror::Error, Clone, Copy, PartialEq, Eq)]
pub enum RecapFailure {
    /// DNS, TLS, proxy, connection, or response streaming failed.
    #[error("network")]
    Network,
    /// The request exceeded its connection or total timeout budget.
    #[error("timeout")]
    Timeout,
    /// DeepSeek rejected the credential with HTTP 401 or 403.
    #[error("authentication")]
    Authentication,
    /// DeepSeek throttled the request with HTTP 429.
    #[error("rate_limited")]
    RateLimited,
    /// DeepSeek returned a server-side or otherwise unavailable response.
    #[error("provider_unavailable")]
    ProviderUnavailable,
    /// The response exceeded the safe bound or was otherwise unusable.
    #[error("invalid_response")]
    InvalidResponse,
}

/// Narrow completion port that receives a bounded serialized request.
pub trait RecapTransport: Send + Sync {
    /// Sends one completion request without retries or response-body logging.
    fn complete(&self, key: &str, request: &[u8]) -> Result<Vec<u8>, RecapFailure>;
    /// Performs a credential-only connection test without sending usage data.
    fn test_connection(&self, key: &str, _model: &str) -> Result<(), RecapFailure> {
        self.complete(key, &[]).map(|_| ())
    }
}

/// Provider configuration state safe to expose to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapStatusDto {
    /// Whether the complete local AI report service is available.
    pub service_available: bool,
    /// Whether a bounded key is available from an allowed source.
    pub configured: bool,
    /// Human-readable provider name; never contains endpoint or key data.
    pub provider: String,
    /// Model selected when the UI has not chosen another supported model.
    pub default_model: String,
    /// `secure_store`, `legacy_environment`, `none`, or `unavailable`.
    pub credential_source: String,
    /// Whether the operating-system secure credential store is available.
    pub secure_storage_available: bool,
    /// Whether a legacy environment key can currently be imported securely.
    pub environment_migration_available: bool,
}

/// A complete, validated recap result safe to expose to Flutter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AiRecapDto {
    /// Logical report type: `daily`, `weekly`, or `monthly`.
    pub scope: String,
    /// Inclusive local-calendar start date in `YYYY-MM-DD` form.
    pub start_date: String,
    /// Inclusive local-calendar end date in `YYYY-MM-DD` form.
    pub end_date: String,
    /// Generation time in UTC RFC3339 form.
    pub generated_at_utc: String,
    /// Exact supported DeepSeek model used for generation.
    pub model: String,
    /// Short Chinese overview with evidence grounded in the sent aggregates.
    pub summary: AiRecapStatementDto,
    /// One to three validated Chinese observations.
    pub highlights: Vec<AiRecapStatementDto>,
    /// One to three validated Chinese suggestions.
    pub suggestions: Vec<AiRecapStatementDto>,
    /// Deterministic top application rows computed locally, never by the model.
    pub top_applications: Vec<AiRecapEvidenceDto>,
    /// Active seconds across every valid aggregate row, including truncated rows.
    pub total_active_seconds: i64,
    /// Number of valid aggregate applications before the top-12 truncation.
    pub application_count: i64,
}

/// One aggregate usage row cited by an AI recap statement.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AiRecapEvidenceDto {
    /// Sanitized application display name sent to the provider.
    pub app_name: String,
    /// Exact active duration sent for this application.
    pub active_seconds: i64,
}

/// One validated Chinese statement and its provider-supplied evidence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AiRecapStatementDto {
    /// Locally rendered Chinese statement text.
    pub text: String,
    /// One to three exact references to the sent aggregate rows.
    pub evidence: Vec<AiRecapEvidenceDto>,
}

/// Stable, redacted generation error safe to expose to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapErrorDto {
    /// Stable machine-readable error code defined by the architecture contract.
    pub code: String,
    /// Whether retrying later without changing the request may succeed.
    pub retryable: bool,
}

/// Mutually exclusive result of an explicit recap generation request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapGenerateReplyDto {
    /// Validated recap on success; `None` on failure.
    pub recap: Option<AiRecapDto>,
    /// Redacted typed failure on failure; `None` on success.
    pub error: Option<AiRecapErrorDto>,
}

/// Mutually exclusive reply for a settings mutation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapSettingsReplyDto {
    /// Refreshed redacted state on success or best-effort state on failure.
    pub status: AiRecapStatusDto,
    /// Redacted typed failure, if the mutation failed.
    pub error: Option<AiRecapErrorDto>,
}

/// Reply for an explicit, aggregate-free provider connection test.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapConnectionReplyDto {
    /// True only after DeepSeek accepts the configured credential.
    pub success: bool,
    /// Redacted typed failure when the test did not succeed.
    pub error: Option<AiRecapErrorDto>,
}

impl AiRecapGenerateReplyDto {
    fn success(recap: AiRecapDto) -> Self {
        Self {
            recap: Some(recap),
            error: None,
        }
    }

    fn failure(failure: ServiceFailure) -> Self {
        Self {
            recap: None,
            error: Some(failure.into_dto()),
        }
    }
}

/// Thread-safe, process-memory recap orchestrator.
///
/// `generate` performs blocking database and HTTP work and therefore must be
/// called from a Flutter Rust Bridge worker. Status and latest-result reads are
/// local and synchronous. At most one generation can be in flight globally.
pub struct AiRecapService {
    usage_source: Arc<dyn AggregateUsageSource>,
    key_source: Arc<dyn ApiKeySource>,
    transport: Arc<dyn RecapTransport>,
    report_store: Arc<dyn AiReportStore>,
    latest: Mutex<LatestCache>,
    report_commit: Mutex<()>,
    default_model: Mutex<&'static str>,
    data_epoch: AtomicU64,
    in_flight: AtomicBool,
}

impl AiRecapService {
    /// Creates a production service over an aggregate-only usage source.
    pub fn new(
        usage_source: Arc<dyn AggregateUsageSource>,
        report_store: Arc<dyn AiReportStore>,
    ) -> Self {
        Self::with_ports(
            usage_source,
            Arc::new(StoredOrEnvironmentApiKeySource::production()),
            Arc::new(DeepSeekTransport::new()),
            report_store,
        )
    }

    /// Reads the current local provider configuration without making a request.
    pub fn status(&self) -> AiRecapStatusDto {
        if !self.report_store.is_available() {
            return AiRecapStatusDto {
                service_available: false,
                configured: false,
                provider: PROVIDER_NAME.to_owned(),
                default_model: self.current_model().to_owned(),
                credential_source: CredentialOrigin::Unavailable.as_str().to_owned(),
                secure_storage_available: false,
                environment_migration_available: false,
            };
        }
        let resolved = self.key_source.resolve_deepseek_key(true);
        let environment_migration_available = resolved.origin
            == CredentialOrigin::LegacyEnvironment
            && resolved.secure_storage_available;
        let service_available = resolved.origin != CredentialOrigin::Unavailable;
        AiRecapStatusDto {
            service_available,
            configured: resolved.key.is_some(),
            provider: PROVIDER_NAME.to_owned(),
            default_model: self.current_model().to_owned(),
            credential_source: resolved.origin.as_str().to_owned(),
            secure_storage_available: resolved.secure_storage_available,
            environment_migration_available,
        }
    }

    /// Returns the latest result for one exact logical scope and date range.
    pub fn latest(&self, scope: &str, start_date: &str, end_date: &str) -> Option<AiRecapDto> {
        let range = parse_range(scope, start_date, end_date).ok()?;
        self.lock_latest().get(&range)
    }

    /// Returns the latest successful report for every report type, newest first.
    pub fn latest_reports(&self) -> Vec<AiRecapDto> {
        self.lock_latest().all()
    }

    /// Securely creates or replaces the stored DeepSeek API key.
    pub fn save_api_key(&self, key: String) -> AiRecapSettingsReplyDto {
        let key = Zeroizing::new(key);
        let result = self
            .key_source
            .save_deepseek_key(key.as_str())
            .map_err(|error| match error {
                CredentialError::InvalidData => ServiceFailure::InvalidApiKey,
                _ => ServiceFailure::CredentialStore,
            });
        self.settings_reply(result)
    }

    /// Explicitly imports the legacy environment key into secure storage.
    pub fn import_environment_api_key(&self) -> AiRecapSettingsReplyDto {
        let result = match self.key_source.read_environment_deepseek_key() {
            Some(key) => self
                .key_source
                .save_deepseek_key(key.as_str())
                .map_err(|_| ServiceFailure::CredentialStore),
            None => Err(ServiceFailure::NotConfigured),
        };
        self.settings_reply(result)
    }

    /// Removes the secure key. A valid legacy environment key becomes active
    /// again because secure storage is always preferred over the fallback.
    pub fn delete_api_key(&self) -> AiRecapSettingsReplyDto {
        let result = self
            .key_source
            .delete_deepseek_key()
            .map_err(|_| ServiceFailure::CredentialStore);
        self.settings_reply(result)
    }

    /// Persists the default DeepSeek model used by future report generations.
    pub fn set_default_model(&self, model: String) -> AiRecapSettingsReplyDto {
        let result = validate_model(&model).and_then(|model| {
            self.report_store
                .save_default_model(model)
                .map_err(|_| ServiceFailure::LocalStorage)?;
            *self.lock_default_model() = model;
            Ok(())
        });
        self.settings_reply(result)
    }

    /// Tests the configured credential without sending any aggregate usage data.
    pub fn test_connection(&self) -> AiRecapConnectionReplyDto {
        let _in_flight = match InFlightGuard::acquire(&self.in_flight) {
            Ok(guard) => guard,
            Err(failure) => {
                return AiRecapConnectionReplyDto {
                    success: false,
                    error: Some(failure.into_dto()),
                };
            }
        };
        let resolved = self.key_source.resolve_deepseek_key(true);
        if resolved.origin == CredentialOrigin::Unavailable {
            return AiRecapConnectionReplyDto {
                success: false,
                error: Some(ServiceFailure::CredentialStore.into_dto()),
            };
        }
        let Some(key) = resolved.key else {
            return AiRecapConnectionReplyDto {
                success: false,
                error: Some(ServiceFailure::NotConfigured.into_dto()),
            };
        };
        match self
            .transport
            .test_connection(key.as_str(), self.current_model())
        {
            Ok(()) => AiRecapConnectionReplyDto {
                success: true,
                error: None,
            },
            Err(failure) => AiRecapConnectionReplyDto {
                success: false,
                error: Some(ServiceFailure::Transport(failure).into_dto()),
            },
        }
    }

    /// Generates one recap after explicit user authorization.
    ///
    /// Business failures are always returned as a typed, redacted reply. A
    /// successful recap atomically replaces only the matching range in the
    /// bounded in-memory latest cache; failures preserve every prior result.
    pub fn generate(
        &self,
        scope: String,
        start_date: String,
        end_date: String,
    ) -> AiRecapGenerateReplyDto {
        if !self.report_store.is_available() {
            return AiRecapGenerateReplyDto::failure(ServiceFailure::LocalStorage);
        }
        let range = match parse_range(&scope, &start_date, &end_date) {
            Ok(range) => range,
            Err(failure) => return AiRecapGenerateReplyDto::failure(failure),
        };
        let model = self.current_model();
        let _in_flight = match InFlightGuard::acquire(&self.in_flight) {
            Ok(guard) => guard,
            Err(failure) => return AiRecapGenerateReplyDto::failure(failure),
        };

        let data_epoch = self.data_epoch.load(Ordering::Acquire);
        match self.generate_inner(range, model, data_epoch) {
            Ok(recap) => AiRecapGenerateReplyDto::success(recap),
            Err(failure) => AiRecapGenerateReplyDto::failure(failure),
        }
    }

    fn with_ports(
        usage_source: Arc<dyn AggregateUsageSource>,
        key_source: Arc<dyn ApiKeySource>,
        transport: Arc<dyn RecapTransport>,
        report_store: Arc<dyn AiReportStore>,
    ) -> Self {
        let model = report_store
            .load_default_model()
            .ok()
            .flatten()
            .as_deref()
            .and_then(|model| validate_model(model).ok())
            .unwrap_or(DEFAULT_MODEL);
        let mut latest = LatestCache::default();
        match report_store.load_latest_reports() {
            Ok(reports) => {
                for report in reports {
                    if let Some(range) = validate_persisted_report(&report) {
                        latest.insert(range, report);
                    } else {
                        tracing::warn!("ignored invalid persisted AI report DTO");
                    }
                }
            }
            Err(error) => tracing::warn!(error = %error, "failed to load persisted AI reports"),
        }
        Self {
            usage_source,
            key_source,
            transport,
            report_store,
            latest: Mutex::new(latest),
            report_commit: Mutex::new(()),
            default_model: Mutex::new(model),
            data_epoch: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
        }
    }

    fn generate_inner(
        &self,
        range: RangeKey,
        model: &'static str,
        data_epoch: u64,
    ) -> Result<AiRecapDto, ServiceFailure> {
        let usage = self.usage_source.read(range.start, range.end);
        let prepared = prepare_usage(usage)?;

        let resolved = self.key_source.resolve_deepseek_key(true);
        if resolved.origin == CredentialOrigin::Unavailable {
            return Err(ServiceFailure::CredentialStore);
        }
        let key = resolved.key.ok_or(ServiceFailure::NotConfigured)?;
        let request = build_request(&range, model, &prepared)?;
        let completion = self.transport.complete(&key, &request);
        drop(key);
        let response = completion.map_err(ServiceFailure::Transport)?;
        let parsed = parse_provider_response(&response, &prepared, range.scope)?;
        let top_applications = prepared
            .sent
            .iter()
            .take(5)
            .map(|usage| AiRecapEvidenceDto {
                app_name: usage.app_name.clone(),
                active_seconds: usage.active_seconds,
            })
            .collect();

        let recap = AiRecapDto {
            scope: range.scope.as_str().to_owned(),
            start_date: range.start.to_string(),
            end_date: range.end.to_string(),
            generated_at_utc: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            model: model.to_owned(),
            summary: parsed.summary,
            highlights: parsed.highlights,
            suggestions: parsed.suggestions,
            top_applications,
            total_active_seconds: prepared.total_seconds,
            application_count: prepared.application_count,
        };
        // Serialize the epoch check, durable replacement, and cache update
        // against clear_reports so a just-cleared report cannot reappear.
        let _commit = self.lock_report_commit();
        if self.data_epoch.load(Ordering::Acquire) != data_epoch {
            return Err(ServiceFailure::Busy);
        }
        self.report_store
            .save_latest_report(&recap)
            .map_err(|_| ServiceFailure::LocalStorage)?;
        self.lock_latest().insert(range, recap.clone());
        Ok(recap)
    }

    /// Clears persisted and in-process report results while preserving AI settings.
    pub fn clear_reports(&self) -> Result<(), AiReportStoreError> {
        self.data_epoch.fetch_add(1, Ordering::AcqRel);
        let _commit = self.lock_report_commit();
        self.report_store.clear_latest_reports()?;
        self.lock_latest().clear();
        Ok(())
    }

    fn settings_reply(&self, result: Result<(), ServiceFailure>) -> AiRecapSettingsReplyDto {
        AiRecapSettingsReplyDto {
            status: self.status(),
            error: result.err().map(ServiceFailure::into_dto),
        }
    }

    fn current_model(&self) -> &'static str {
        *self.lock_default_model()
    }

    fn lock_default_model(&self) -> MutexGuard<'_, &'static str> {
        match self.default_model.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn lock_latest(&self) -> MutexGuard<'_, LatestCache> {
        match self.latest.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn lock_report_commit(&self) -> MutexGuard<'_, ()> {
        match self.report_commit.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RecapScope {
    Daily,
    Weekly,
    Monthly,
}

impl RecapScope {
    fn parse(value: &str) -> Result<Self, ServiceFailure> {
        match value {
            "daily" => Ok(Self::Daily),
            "weekly" => Ok(Self::Weekly),
            "monthly" => Ok(Self::Monthly),
            _ => Err(ServiceFailure::InvalidRange),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Daily => "daily",
            Self::Weekly => "weekly",
            Self::Monthly => "monthly",
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::Daily => "所选日期",
            Self::Weekly => "所选周",
            Self::Monthly => "所选月份",
        }
    }

    fn prompt_note(self) -> &'static str {
        match self {
            Self::Daily => "仅代表所选自然日。数据较少时必须保持保守，不得外推日常习惯。",
            Self::Weekly => {
                "代表所选自然周；若结束日为今天，则仅代表周一到今天的累计，不得伪装成完整周或预测整周。"
            }
            Self::Monthly => {
                "代表所选自然月；若结束日为今天，则仅代表本月一日至今天的累计，不得伪装成完整月或预测整月。"
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RangeKey {
    scope: RecapScope,
    start: NaiveDate,
    end: NaiveDate,
}

#[derive(Default)]
struct LatestCache {
    entries: BTreeMap<RecapScope, AiRecapDto>,
}

impl LatestCache {
    fn get(&self, range: &RangeKey) -> Option<AiRecapDto> {
        self.entries.get(&range.scope).and_then(|report| {
            (report.start_date == range.start.to_string()
                && report.end_date == range.end.to_string())
            .then(|| report.clone())
        })
    }

    fn insert(&mut self, range: RangeKey, recap: AiRecapDto) {
        self.entries.insert(range.scope, recap);
    }

    fn all(&self) -> Vec<AiRecapDto> {
        let mut reports: Vec<_> = self.entries.values().cloned().collect();
        reports.sort_by(|left, right| right.generated_at_utc.cmp(&left.generated_at_utc));
        reports
    }

    fn clear(&mut self) {
        self.entries.clear();
    }
}

struct InFlightGuard<'a> {
    flag: &'a AtomicBool,
}

impl<'a> InFlightGuard<'a> {
    fn acquire(flag: &'a AtomicBool) -> Result<Self, ServiceFailure> {
        flag.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| Self { flag })
            .map_err(|_| ServiceFailure::Busy)
    }
}

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::Release);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceFailure {
    NotConfigured,
    InvalidApiKey,
    InvalidRange,
    UnsupportedModel,
    NoUsageData,
    RequestTooLarge,
    InvalidResponse,
    Busy,
    CredentialStore,
    LocalStorage,
    Transport(RecapFailure),
}

impl ServiceFailure {
    fn into_dto(self) -> AiRecapErrorDto {
        let (code, retryable) = match self {
            Self::NotConfigured => ("not_configured", false),
            Self::InvalidApiKey => ("invalid_api_key", false),
            Self::InvalidRange => ("invalid_range", false),
            Self::UnsupportedModel => ("unsupported_model", false),
            Self::NoUsageData => ("no_usage_data", false),
            Self::RequestTooLarge => ("request_too_large", false),
            Self::InvalidResponse | Self::Transport(RecapFailure::InvalidResponse) => {
                ("invalid_response", true)
            }
            Self::Busy => ("busy", true),
            Self::CredentialStore => ("credential_store", false),
            Self::LocalStorage => ("local_storage", true),
            Self::Transport(RecapFailure::Network) => ("network", true),
            Self::Transport(RecapFailure::Timeout) => ("timeout", true),
            Self::Transport(RecapFailure::Authentication) => ("authentication", false),
            Self::Transport(RecapFailure::RateLimited) => ("rate_limited", true),
            Self::Transport(RecapFailure::ProviderUnavailable) => ("provider_unavailable", true),
        };
        AiRecapErrorDto {
            code: code.to_owned(),
            retryable,
        }
    }
}

struct DeepSeekTransport {
    client: OnceLock<Option<reqwest::blocking::Client>>,
    connection_test_client: OnceLock<Option<reqwest::blocking::Client>>,
}

impl DeepSeekTransport {
    fn new() -> Self {
        Self {
            client: OnceLock::new(),
            connection_test_client: OnceLock::new(),
        }
    }

    fn client(&self) -> Result<&reqwest::blocking::Client, RecapFailure> {
        self.client
            .get_or_init(Self::build_client)
            .as_ref()
            .ok_or(RecapFailure::Network)
    }

    fn build_client() -> Option<reqwest::blocking::Client> {
        reqwest::blocking::Client::builder()
            .connect_timeout(Duration::from_secs(4))
            .timeout(Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .user_agent("TimeTrace/0.1 AI-Recap")
            .build()
            .ok()
    }

    fn connection_test_client(&self) -> Result<&reqwest::blocking::Client, RecapFailure> {
        self.connection_test_client
            .get_or_init(|| {
                reqwest::blocking::Client::builder()
                    .connect_timeout(Duration::from_secs(4))
                    .timeout(Duration::from_secs(10))
                    .redirect(reqwest::redirect::Policy::none())
                    .retry(reqwest::retry::never())
                    .user_agent("TimeTrace/0.1 AI-Reports-Connection-Test")
                    .build()
                    .ok()
            })
            .as_ref()
            .ok_or(RecapFailure::Network)
    }
}

impl RecapTransport for DeepSeekTransport {
    fn complete(&self, key: &str, request: &[u8]) -> Result<Vec<u8>, RecapFailure> {
        if request.len() > MAX_REQUEST_BYTES {
            return Err(RecapFailure::ProviderUnavailable);
        }
        let client = self.client()?;
        let response = client
            .post(API_URL)
            .bearer_auth(key)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(request.to_vec())
            .send()
            .map_err(classify_reqwest_error)?;

        let status = response.status();
        if !status.is_success() {
            return Err(classify_http_status(status));
        }
        read_bounded_response(response, MAX_RESPONSE_BYTES)
    }

    fn test_connection(&self, key: &str, model: &str) -> Result<(), RecapFailure> {
        let response = self
            .connection_test_client()?
            .get(MODELS_API_URL)
            .bearer_auth(key)
            .send()
            .map_err(classify_reqwest_error)?;
        let status = response.status();
        if !status.is_success() {
            return Err(classify_http_status(status));
        }
        let body = read_bounded_response(response, MAX_CONNECTION_RESPONSE_BYTES)?;
        validate_models_response(&body, model)
    }
}

fn validate_models_response(body: &[u8], model: &str) -> Result<(), RecapFailure> {
    let models: ModelsResponse =
        serde_json::from_slice(body).map_err(|_| RecapFailure::InvalidResponse)?;
    if !models.data.is_empty()
        && models.data.len() <= 100
        && models.data.iter().any(|candidate| candidate.id == model)
    {
        Ok(())
    } else {
        Err(RecapFailure::InvalidResponse)
    }
}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<ModelRecord>,
}

#[derive(Deserialize)]
struct ModelRecord {
    id: String,
}

fn read_bounded_response(
    response: reqwest::blocking::Response,
    maximum_bytes: usize,
) -> Result<Vec<u8>, RecapFailure> {
    if response
        .content_length()
        .is_some_and(|length| length > maximum_bytes as u64)
    {
        return Err(RecapFailure::InvalidResponse);
    }
    let mut bytes = Vec::new();
    let mut bounded = response.take((maximum_bytes + 1) as u64);
    bounded.read_to_end(&mut bytes).map_err(|error| {
        if error.kind() == ErrorKind::TimedOut {
            RecapFailure::Timeout
        } else {
            RecapFailure::Network
        }
    })?;
    if bytes.len() > maximum_bytes {
        return Err(RecapFailure::InvalidResponse);
    }
    Ok(bytes)
}

fn classify_reqwest_error(error: reqwest::Error) -> RecapFailure {
    if error.is_timeout() {
        RecapFailure::Timeout
    } else {
        RecapFailure::Network
    }
}

fn classify_http_status(status: StatusCode) -> RecapFailure {
    match status.as_u16() {
        401 | 403 => RecapFailure::Authentication,
        429 => RecapFailure::RateLimited,
        500..=599 => RecapFailure::ProviderUnavailable,
        _ => RecapFailure::InvalidResponse,
    }
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: [Message<'a>; 2],
    response_format: ResponseFormat<'a>,
    thinking: Thinking<'a>,
    temperature: f32,
    max_tokens: u16,
}

#[derive(Serialize)]
struct Message<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Serialize)]
struct ResponseFormat<'a> {
    #[serde(rename = "type")]
    kind: &'a str,
}

#[derive(Serialize)]
struct Thinking<'a> {
    #[serde(rename = "type")]
    kind: &'a str,
}

#[derive(Serialize)]
struct PromptPayload<'a> {
    scope: &'static str,
    scope_note: &'static str,
    start_date: String,
    end_date: String,
    total_active_seconds: i64,
    application_count: i64,
    applications_sent: usize,
    truncated: bool,
    applications: &'a [SanitizedUsage],
}

#[derive(Debug, Clone, Serialize)]
struct SanitizedUsage {
    app_name: String,
    active_seconds: i64,
}

struct PreparedUsage {
    sent: Vec<SanitizedUsage>,
    total_seconds: i64,
    application_count: i64,
    truncated: bool,
}

fn prepare_usage(usage: Vec<AggregateUsage>) -> Result<PreparedUsage, ServiceFailure> {
    let mut aggregated = BTreeMap::<String, i64>::new();
    for item in usage {
        if item.active_seconds <= 0 {
            continue;
        }
        let name = sanitize_app_name(&item.app_name);
        if name.is_empty() {
            continue;
        }
        aggregated
            .entry(name)
            .and_modify(|seconds| *seconds = seconds.saturating_add(item.active_seconds))
            .or_insert(item.active_seconds);
    }
    if aggregated.is_empty() {
        return Err(ServiceFailure::NoUsageData);
    }

    let application_count = match i64::try_from(aggregated.len()) {
        Ok(count) => count,
        Err(_) => i64::MAX,
    };
    let total_seconds = aggregated
        .values()
        .fold(0_i64, |total, seconds| total.saturating_add(*seconds));
    let mut sent: Vec<_> = aggregated
        .into_iter()
        .map(|(app_name, active_seconds)| SanitizedUsage {
            app_name,
            active_seconds,
        })
        .collect();
    sent.sort_by(|left, right| {
        right
            .active_seconds
            .cmp(&left.active_seconds)
            .then_with(|| left.app_name.cmp(&right.app_name))
    });
    let truncated = sent.len() > MAX_APPS_SENT;
    sent.truncate(MAX_APPS_SENT);

    Ok(PreparedUsage {
        sent,
        total_seconds,
        application_count,
        truncated,
    })
}

fn sanitize_app_name(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_APP_NAME_CHARS)
        .collect::<String>()
        .trim()
        .to_owned()
}

fn build_request(
    range: &RangeKey,
    model: &'static str,
    usage: &PreparedUsage,
) -> Result<Vec<u8>, ServiceFailure> {
    let prompt_payload = PromptPayload {
        scope: range.scope.as_str(),
        scope_note: range.scope.prompt_note(),
        start_date: range.start.to_string(),
        end_date: range.end.to_string(),
        total_active_seconds: usage.total_seconds,
        application_count: usage.application_count,
        applications_sent: usage.sent.len(),
        truncated: usage.truncated,
        applications: &usage.sent,
    };
    let prompt_json =
        serde_json::to_string(&prompt_payload).map_err(|_| ServiceFailure::RequestTooLarge)?;
    let user_prompt = format!(
        "请只依据以下聚合数据选择受限的时间报告类型和证据。weekly 或 monthly 的结束日若为今天，表示尚未完成的当前周期；不得当作完整周期或预测剩余时间。无论 scope，为稀疏数据选择证据时都必须保守。不得输出任何自由文本，不得推断应用类别、窗口内容、文件、账号、健康、人格、工作成果、绩效或未来趋势：{prompt_json}"
    );
    let request = ChatRequest {
        model,
        messages: [
            Message {
                role: "system",
                content: "你是受限的时间报告证据选择器。仅依据给定的聚合应用时长输出 JSON 对象；不得输出解释、自由文本或猜测。weekly 或 monthly 的结束日若为今天，表示未完成的当前周期，禁止当作完整周期或预测剩余周期；数据稀疏时必须保守。JSON 必须且只能包含 summary、highlights、suggestions。每个对象必须且只能是 {\"kind\":\"受限类型\",\"evidence\":[{\"app_name\":\"输入中的应用名\",\"active_seconds\":输入中的精确秒数}]}；evidence 必须逐字、逐数匹配 applications 中的行。summary 的 kind 必须为 usage_overview。highlights 每项 kind 只能为 top_application 或 usage_concentration，且不得重复；top_application 必须唯一引用 applications[0]，usage_concentration 必须引用 2 到 3 个不重复应用。suggestions 每项 kind 只能为 review_top_application、protect_time_block 或 set_time_budget，且不得重复；review_top_application 必须唯一引用 applications[0]，其他建议必须唯一引用一个应用。highlights 和 suggestions 各为 1 到 3 项。",
            },
            Message {
                role: "user",
                content: &user_prompt,
            },
        ],
        response_format: ResponseFormat {
            kind: "json_object",
        },
        thinking: Thinking { kind: "disabled" },
        temperature: 0.3,
        max_tokens: 600,
    };
    let body = serde_json::to_vec(&request).map_err(|_| ServiceFailure::RequestTooLarge)?;
    if body.len() > MAX_REQUEST_BYTES {
        return Err(ServiceFailure::RequestTooLarge);
    }
    Ok(body)
}

fn parse_range(scope: &str, start: &str, end: &str) -> Result<RangeKey, ServiceFailure> {
    let scope = RecapScope::parse(scope)?;
    let start = parse_exact_date(start)?;
    let end = parse_exact_date(end)?;
    let today = Local::now().date_naive();
    if end > today {
        return Err(ServiceFailure::InvalidRange);
    }
    let span = end.signed_duration_since(start).num_days();
    let valid = match scope {
        RecapScope::Daily => span == 0,
        RecapScope::Weekly => {
            start.weekday() == Weekday::Mon
                && ((span == 6 && end.weekday() == Weekday::Sun)
                    || (end == today && (0..=6).contains(&span)))
        }
        RecapScope::Monthly => {
            start.day() == 1
                && start.year() == end.year()
                && start.month() == end.month()
                && (is_last_day_of_month(end) || end == today)
        }
    };
    if !valid {
        return Err(ServiceFailure::InvalidRange);
    }
    Ok(RangeKey { scope, start, end })
}

fn is_last_day_of_month(date: NaiveDate) -> bool {
    date.succ_opt().map(|next| next.day() == 1).unwrap_or(true)
}

fn validate_persisted_report(report: &AiRecapDto) -> Option<RangeKey> {
    let range = parse_persisted_range(&report.scope, &report.start_date, &report.end_date).ok()?;
    validate_model(&report.model).ok()?;
    chrono::DateTime::parse_from_rfc3339(&report.generated_at_utc).ok()?;
    if report.total_active_seconds <= 0
        || report.application_count <= 0
        || report.top_applications.is_empty()
        || report.top_applications.len() > 5
        || report.highlights.is_empty()
        || report.highlights.len() > MAX_ITEMS
        || report.suggestions.is_empty()
        || report.suggestions.len() > MAX_ITEMS
        || !valid_persisted_statement(&report.summary)
        || !report.highlights.iter().all(valid_persisted_statement)
        || !report.suggestions.iter().all(valid_persisted_statement)
        || !report.top_applications.iter().all(valid_persisted_evidence)
    {
        return None;
    }
    Some(range)
}

fn parse_persisted_range(scope: &str, start: &str, end: &str) -> Result<RangeKey, ServiceFailure> {
    let scope = RecapScope::parse(scope)?;
    let start = parse_exact_date(start)?;
    let end = parse_exact_date(end)?;
    if end > Local::now().date_naive() {
        return Err(ServiceFailure::InvalidRange);
    }
    let span = end.signed_duration_since(start).num_days();
    let valid = match scope {
        RecapScope::Daily => span == 0,
        RecapScope::Weekly => start.weekday() == Weekday::Mon && (0..=6).contains(&span),
        RecapScope::Monthly => {
            span >= 0
                && start.day() == 1
                && start.year() == end.year()
                && start.month() == end.month()
        }
    };
    if !valid {
        return Err(ServiceFailure::InvalidRange);
    }
    Ok(RangeKey { scope, start, end })
}

fn valid_persisted_statement(statement: &AiRecapStatementDto) -> bool {
    !statement.text.is_empty()
        && statement.text.chars().count() <= 1024
        && !statement.evidence.is_empty()
        && statement.evidence.len() <= MAX_ITEMS
        && statement.evidence.iter().all(valid_persisted_evidence)
}

fn valid_persisted_evidence(evidence: &AiRecapEvidenceDto) -> bool {
    evidence.active_seconds > 0
        && !evidence.app_name.is_empty()
        && evidence.app_name.chars().count() <= MAX_APP_NAME_CHARS
        && sanitize_app_name(&evidence.app_name) == evidence.app_name
}

fn parse_exact_date(value: &str) -> Result<NaiveDate, ServiceFailure> {
    if value.len() != 10
        || value.as_bytes().get(4) != Some(&b'-')
        || value.as_bytes().get(7) != Some(&b'-')
    {
        return Err(ServiceFailure::InvalidRange);
    }
    let parsed =
        NaiveDate::parse_from_str(value, "%Y-%m-%d").map_err(|_| ServiceFailure::InvalidRange)?;
    if parsed.to_string() != value {
        return Err(ServiceFailure::InvalidRange);
    }
    Ok(parsed)
}

fn validate_model(model: &str) -> Result<&'static str, ServiceFailure> {
    match model {
        DEFAULT_MODEL => Ok(DEFAULT_MODEL),
        PRO_MODEL => Ok(PRO_MODEL),
        _ => Err(ServiceFailure::UnsupportedModel),
    }
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: ProviderMessage,
}

#[derive(Deserialize)]
struct ProviderMessage {
    content: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct RecapContent {
    summary: ProviderStatement,
    highlights: Vec<ProviderStatement>,
    suggestions: Vec<ProviderStatement>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ProviderStatement {
    kind: String,
    evidence: Vec<ProviderEvidence>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ProviderEvidence {
    app_name: String,
    active_seconds: i64,
}

fn parse_provider_response(
    response: &[u8],
    usage: &PreparedUsage,
    scope: RecapScope,
) -> Result<ValidatedRecapContent, ServiceFailure> {
    if response.is_empty() || response.len() > MAX_RESPONSE_BYTES {
        return Err(ServiceFailure::InvalidResponse);
    }
    let envelope: ChatResponse =
        serde_json::from_slice(response).map_err(|_| ServiceFailure::InvalidResponse)?;
    let raw_content = envelope
        .choices
        .into_iter()
        .next()
        .map(|choice| choice.message.content)
        .ok_or(ServiceFailure::InvalidResponse)?;
    if raw_content.chars().count() > MAX_CONTENT_CHARS {
        return Err(ServiceFailure::InvalidResponse);
    }

    let content: RecapContent =
        serde_json::from_str(&raw_content).map_err(|_| ServiceFailure::InvalidResponse)?;
    validate_generated_content(content, usage, scope)
}

#[derive(Debug, PartialEq, Eq)]
struct ValidatedRecapContent {
    summary: AiRecapStatementDto,
    highlights: Vec<AiRecapStatementDto>,
    suggestions: Vec<AiRecapStatementDto>,
}

fn validate_generated_content(
    content: RecapContent,
    usage: &PreparedUsage,
    scope: RecapScope,
) -> Result<ValidatedRecapContent, ServiceFailure> {
    if content.summary.kind != "usage_overview" {
        return Err(ServiceFailure::InvalidResponse);
    }
    let summary_evidence = validate_evidence(content.summary.evidence, usage, 1, MAX_ITEMS)?;
    let sparse_note =
        if usage.application_count < 2 || usage.total_seconds < SPARSE_MIN_TOTAL_SECONDS {
            " 当前数据较少，结论仅供参考。"
        } else {
            ""
        };
    let summary = AiRecapStatementDto {
        text: format!(
            "{}共记录{}活动，覆盖{}个应用。{}",
            scope.display_name(),
            format_duration(usage.total_seconds),
            usage.application_count,
            sparse_note
        ),
        evidence: summary_evidence,
    };
    let highlights = validate_highlights(content.highlights, usage, scope)?;
    let suggestions = validate_suggestions(content.suggestions, usage)?;
    Ok(ValidatedRecapContent {
        summary,
        highlights,
        suggestions,
    })
}

fn validate_highlights(
    items: Vec<ProviderStatement>,
    usage: &PreparedUsage,
    scope: RecapScope,
) -> Result<Vec<AiRecapStatementDto>, ServiceFailure> {
    if items.is_empty() || items.len() > MAX_ITEMS {
        return Err(ServiceFailure::InvalidResponse);
    }
    let mut kinds = BTreeSet::new();
    items
        .into_iter()
        .map(|item| {
            if !kinds.insert(item.kind.clone()) {
                return Err(ServiceFailure::InvalidResponse);
            }
            match item.kind.as_str() {
                "top_application" => {
                    let evidence = validate_evidence(item.evidence, usage, 1, 1)?;
                    let top = usage.sent.first().ok_or(ServiceFailure::InvalidResponse)?;
                    if evidence[0].app_name != top.app_name
                        || evidence[0].active_seconds != top.active_seconds
                    {
                        return Err(ServiceFailure::InvalidResponse);
                    }
                    Ok(AiRecapStatementDto {
                        text: format!(
                            "{}是{}使用时长最高的应用，共{}。",
                            top.app_name,
                            scope.display_name(),
                            format_duration(top.active_seconds)
                        ),
                        evidence,
                    })
                }
                "usage_concentration" => {
                    let evidence = validate_evidence(item.evidence, usage, 2, 3)?;
                    let seconds = evidence.iter().fold(0_i64, |total, item| {
                        total.saturating_add(item.active_seconds)
                    });
                    let percent = percentage(seconds, usage.total_seconds)?;
                    let names = evidence
                        .iter()
                        .map(|item| item.app_name.as_str())
                        .collect::<Vec<_>>()
                        .join("、");
                    Ok(AiRecapStatementDto {
                        text: format!(
                            "{}在{}合计{}，占总活动时长{}%。",
                            names,
                            scope.display_name(),
                            format_duration(seconds),
                            percent
                        ),
                        evidence,
                    })
                }
                _ => Err(ServiceFailure::InvalidResponse),
            }
        })
        .collect()
}

fn validate_suggestions(
    items: Vec<ProviderStatement>,
    usage: &PreparedUsage,
) -> Result<Vec<AiRecapStatementDto>, ServiceFailure> {
    if items.is_empty() || items.len() > MAX_ITEMS {
        return Err(ServiceFailure::InvalidResponse);
    }
    let mut kinds = BTreeSet::new();
    items
        .into_iter()
        .map(|item| {
            if !kinds.insert(item.kind.clone()) {
                return Err(ServiceFailure::InvalidResponse);
            }
            let evidence = validate_evidence(item.evidence, usage, 1, 1)?;
            let app = &evidence[0].app_name;
            let duration = format_duration(evidence[0].active_seconds);
            let text = match item.kind.as_str() {
                "review_top_application" => {
                    let top = usage.sent.first().ok_or(ServiceFailure::InvalidResponse)?;
                    if evidence[0].app_name != top.app_name
                        || evidence[0].active_seconds != top.active_seconds
                    {
                        return Err(ServiceFailure::InvalidResponse);
                    }
                    format!(
                        "{}记录{}，可以考虑回顾这段时间投入是否符合当前计划。",
                        app, duration
                    )
                }
                "protect_time_block" => {
                    format!(
                        "{}记录{}，可以考虑为相关任务预留专注时间并减少不必要切换。",
                        app, duration
                    )
                }
                "set_time_budget" => format!(
                    "{}记录{}，可以考虑为相关任务设置明确的时间预算并在结束时复盘。",
                    app, duration
                ),
                _ => return Err(ServiceFailure::InvalidResponse),
            };
            Ok(AiRecapStatementDto { text, evidence })
        })
        .collect()
}

fn validate_evidence(
    items: Vec<ProviderEvidence>,
    usage: &PreparedUsage,
    min: usize,
    max: usize,
) -> Result<Vec<AiRecapEvidenceDto>, ServiceFailure> {
    if items.len() < min || items.len() > max {
        return Err(ServiceFailure::InvalidResponse);
    }
    let allowed: BTreeMap<&str, i64> = usage
        .sent
        .iter()
        .map(|item| (item.app_name.as_str(), item.active_seconds))
        .collect();

    let mut seen = BTreeSet::new();
    let mut evidence = Vec::with_capacity(items.len());
    for item in items {
        let exact_seconds = allowed
            .get(item.app_name.as_str())
            .ok_or(ServiceFailure::InvalidResponse)?;
        if *exact_seconds != item.active_seconds || !seen.insert(item.app_name.clone()) {
            return Err(ServiceFailure::InvalidResponse);
        }
        evidence.push(AiRecapEvidenceDto {
            app_name: item.app_name,
            active_seconds: item.active_seconds,
        });
    }
    Ok(evidence)
}

fn percentage(part: i64, total: i64) -> Result<i64, ServiceFailure> {
    if total <= 0 || part <= 0 || part > total {
        return Err(ServiceFailure::InvalidResponse);
    }
    Ok(part.saturating_mul(100) / total)
}

fn format_duration(seconds: i64) -> String {
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let remaining_seconds = seconds % 60;
    let mut parts = Vec::with_capacity(3);
    if hours > 0 {
        parts.push(format!("{hours}小时"));
    }
    if minutes > 0 {
        parts.push(format!("{minutes}分钟"));
    }
    if remaining_seconds > 0 || parts.is_empty() {
        parts.push(format!("{remaining_seconds}秒"));
    }
    parts.concat()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;
    use std::sync::{Condvar, mpsc};
    use std::thread;
    use std::time::Instant;

    use super::*;
    use crate::ai_credentials::ResolvedApiKey;
    use crate::ai_report_store::UnavailableAiReportStore;

    struct FakeUsageSource {
        rows: Vec<AggregateUsage>,
        reads: AtomicUsize,
    }

    impl FakeUsageSource {
        fn new(rows: Vec<AggregateUsage>) -> Self {
            Self {
                rows,
                reads: AtomicUsize::new(0),
            }
        }
    }

    impl AggregateUsageSource for FakeUsageSource {
        fn read(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<AggregateUsage> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            self.rows.clone()
        }
    }

    struct FakeKeySource {
        key: Mutex<Option<String>>,
        environment_key: Option<String>,
        reads: AtomicUsize,
    }

    impl FakeKeySource {
        fn new(key: Option<&str>) -> Self {
            Self {
                key: Mutex::new(key.map(str::to_owned)),
                environment_key: None,
                reads: AtomicUsize::new(0),
            }
        }
    }

    impl ApiKeySource for FakeKeySource {
        fn resolve_deepseek_key(&self, allow_environment: bool) -> ResolvedApiKey {
            self.reads.fetch_add(1, Ordering::Relaxed);
            if let Some(key) = self.key.lock().expect("fake key lock").clone() {
                return ResolvedApiKey {
                    key: Some(Zeroizing::new(key)),
                    origin: CredentialOrigin::SecureStore,
                    secure_storage_available: true,
                };
            }
            if allow_environment {
                if let Some(key) = self.environment_key.clone() {
                    return ResolvedApiKey {
                        key: Some(Zeroizing::new(key)),
                        origin: CredentialOrigin::LegacyEnvironment,
                        secure_storage_available: true,
                    };
                }
            }
            ResolvedApiKey {
                key: None,
                origin: CredentialOrigin::None,
                secure_storage_available: true,
            }
        }

        fn read_environment_deepseek_key(&self) -> Option<Zeroizing<String>> {
            self.environment_key.clone().map(Zeroizing::new)
        }

        fn save_deepseek_key(&self, key: &str) -> Result<(), CredentialError> {
            *self.key.lock().expect("fake key lock") = Some(key.to_owned());
            Ok(())
        }

        fn delete_deepseek_key(&self) -> Result<(), CredentialError> {
            *self.key.lock().expect("fake key lock") = None;
            Ok(())
        }
    }

    struct FakeReportStore {
        reports: Mutex<BTreeMap<String, AiRecapDto>>,
        model: Mutex<Option<String>>,
        fail_report_saves: AtomicBool,
        fail_report_clears: AtomicBool,
    }

    impl FakeReportStore {
        fn new() -> Self {
            Self {
                reports: Mutex::new(BTreeMap::new()),
                model: Mutex::new(None),
                fail_report_saves: AtomicBool::new(false),
                fail_report_clears: AtomicBool::new(false),
            }
        }
    }

    impl AiReportStore for FakeReportStore {
        fn load_latest_reports(&self) -> Result<Vec<AiRecapDto>, AiReportStoreError> {
            Ok(self
                .reports
                .lock()
                .expect("fake reports lock")
                .values()
                .cloned()
                .collect())
        }

        fn save_latest_report(&self, report: &AiRecapDto) -> Result<(), AiReportStoreError> {
            if self.fail_report_saves.load(Ordering::Relaxed) {
                return Err(AiReportStoreError::InvalidReport);
            }
            self.reports
                .lock()
                .expect("fake reports lock")
                .insert(report.scope.clone(), report.clone());
            Ok(())
        }

        fn clear_latest_reports(&self) -> Result<(), AiReportStoreError> {
            if self.fail_report_clears.load(Ordering::Relaxed) {
                return Err(AiReportStoreError::Unavailable);
            }
            self.reports.lock().expect("fake reports lock").clear();
            Ok(())
        }

        fn load_default_model(&self) -> Result<Option<String>, AiReportStoreError> {
            Ok(self.model.lock().expect("fake model lock").clone())
        }

        fn save_default_model(&self, model: &str) -> Result<(), AiReportStoreError> {
            *self.model.lock().expect("fake model lock") = Some(model.to_owned());
            Ok(())
        }
    }

    struct BlockingReportStore {
        inner: FakeReportStore,
        save_entered: Mutex<Option<mpsc::Sender<()>>>,
        save_released: (Mutex<bool>, Condvar),
    }

    impl BlockingReportStore {
        fn new(save_entered: mpsc::Sender<()>) -> Self {
            Self {
                inner: FakeReportStore::new(),
                save_entered: Mutex::new(Some(save_entered)),
                save_released: (Mutex::new(false), Condvar::new()),
            }
        }

        fn release_save(&self) {
            let (lock, ready) = &self.save_released;
            *lock.lock().expect("save release lock") = true;
            ready.notify_all();
        }
    }

    impl AiReportStore for BlockingReportStore {
        fn load_latest_reports(&self) -> Result<Vec<AiRecapDto>, AiReportStoreError> {
            self.inner.load_latest_reports()
        }

        fn save_latest_report(&self, report: &AiRecapDto) -> Result<(), AiReportStoreError> {
            if let Some(sender) = self.save_entered.lock().expect("save entered lock").take() {
                sender.send(()).expect("notify save entered");
            }
            let (lock, ready) = &self.save_released;
            let mut released = lock.lock().expect("save release lock");
            while !*released {
                released = ready.wait(released).expect("wait for save release");
            }
            self.inner.save_latest_report(report)
        }

        fn clear_latest_reports(&self) -> Result<(), AiReportStoreError> {
            self.inner.clear_latest_reports()
        }

        fn load_default_model(&self) -> Result<Option<String>, AiReportStoreError> {
            self.inner.load_default_model()
        }

        fn save_default_model(&self, model: &str) -> Result<(), AiReportStoreError> {
            self.inner.save_default_model(model)
        }
    }

    struct FakeTransport {
        result: Result<Vec<u8>, RecapFailure>,
        requests: Mutex<Vec<Vec<u8>>>,
        keys: Mutex<Vec<String>>,
    }

    impl FakeTransport {
        fn successful() -> Self {
            Self {
                result: Ok(valid_provider_response()),
                requests: Mutex::new(Vec::new()),
                keys: Mutex::new(Vec::new()),
            }
        }

        fn failing(failure: RecapFailure) -> Self {
            Self {
                result: Err(failure),
                requests: Mutex::new(Vec::new()),
                keys: Mutex::new(Vec::new()),
            }
        }

        fn call_count(&self) -> usize {
            self.requests.lock().expect("requests lock").len()
        }
    }

    impl RecapTransport for FakeTransport {
        fn complete(&self, key: &str, request: &[u8]) -> Result<Vec<u8>, RecapFailure> {
            self.keys.lock().expect("keys lock").push(key.to_owned());
            self.requests
                .lock()
                .expect("requests lock")
                .push(request.to_vec());
            self.result.clone()
        }
    }

    struct BlockingTransport {
        entered: Mutex<Option<mpsc::Sender<()>>>,
        released: (Mutex<bool>, Condvar),
    }

    impl BlockingTransport {
        fn new(entered: mpsc::Sender<()>) -> Self {
            Self {
                entered: Mutex::new(Some(entered)),
                released: (Mutex::new(false), Condvar::new()),
            }
        }

        fn release(&self) {
            let (lock, ready) = &self.released;
            *lock.lock().expect("release lock") = true;
            ready.notify_all();
        }
    }

    impl RecapTransport for BlockingTransport {
        fn complete(&self, _key: &str, _request: &[u8]) -> Result<Vec<u8>, RecapFailure> {
            if let Some(sender) = self.entered.lock().expect("entered lock").take() {
                sender.send(()).expect("notify entered");
            }
            let (lock, ready) = &self.released;
            let mut released = lock.lock().expect("release lock");
            while !*released {
                released = ready.wait(released).expect("wait for release");
            }
            Ok(valid_provider_response())
        }
    }

    fn valid_provider_response() -> Vec<u8> {
        let content = serde_json::json!({
            "summary": statement("usage_overview"),
            "highlights": [statement("top_application")],
            "suggestions": [statement("review_top_application")]
        });
        provider_response(content)
    }

    fn statement(kind: &str) -> serde_json::Value {
        serde_json::json!({
            "kind": kind,
            "evidence": [{
                "app_name": "Visual Studio Code",
                "active_seconds": 900
            }]
        })
    }

    fn provider_response(content: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "choices": [{"message": {"content": content.to_string()}}]
        }))
        .expect("valid provider fixture")
    }

    fn prepared_standard_usage() -> PreparedUsage {
        prepare_usage(usage()).expect("standard prepared usage")
    }

    fn prepared_multi_usage() -> PreparedUsage {
        prepare_usage(vec![
            AggregateUsage {
                app_name: "编辑器".to_owned(),
                active_seconds: 900,
            },
            AggregateUsage {
                app_name: "浏览器".to_owned(),
                active_seconds: 600,
            },
            AggregateUsage {
                app_name: "终端".to_owned(),
                active_seconds: 300,
            },
        ])
        .expect("multi prepared usage")
    }

    fn evidence(app_name: &str, active_seconds: i64) -> serde_json::Value {
        serde_json::json!({"app_name": app_name, "active_seconds": active_seconds})
    }

    fn usage() -> Vec<AggregateUsage> {
        vec![AggregateUsage {
            app_name: "Visual Studio Code".to_owned(),
            active_seconds: 900,
        }]
    }

    fn service(
        rows: Vec<AggregateUsage>,
        key: Option<&str>,
        transport: Arc<dyn RecapTransport>,
    ) -> AiRecapService {
        AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(rows)),
            Arc::new(FakeKeySource::new(key)),
            transport,
            Arc::new(FakeReportStore::new()),
        )
    }

    fn generate(service: &AiRecapService, date: &str) -> AiRecapGenerateReplyDto {
        service.generate("daily".to_owned(), date.to_owned(), date.to_owned())
    }

    fn error_code(reply: &AiRecapGenerateReplyDto) -> &str {
        reply
            .error
            .as_ref()
            .expect("expected an error reply")
            .code
            .as_str()
    }

    #[test]
    fn status_is_local_and_reports_only_configuration_state() {
        let key = Arc::new(FakeKeySource::new(Some("secret")));
        let transport = Arc::new(FakeTransport::successful());
        let service = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            key.clone(),
            transport.clone(),
            Arc::new(FakeReportStore::new()),
        );

        assert_eq!(
            service.status(),
            AiRecapStatusDto {
                service_available: true,
                configured: true,
                provider: "DeepSeek".to_owned(),
                default_model: DEFAULT_MODEL.to_owned(),
                credential_source: "secure_store".to_owned(),
                secure_storage_available: true,
                environment_migration_available: false,
            }
        );
        assert_eq!(key.reads.load(Ordering::Relaxed), 1);
        assert_eq!(transport.call_count(), 0);
    }

    #[test]
    fn unavailable_report_store_degrades_only_ai_and_never_calls_dependencies() {
        let usage = Arc::new(FakeUsageSource::new(usage()));
        let key = Arc::new(FakeKeySource::new(Some("secret")));
        let transport = Arc::new(FakeTransport::successful());
        let service = AiRecapService::with_ports(
            usage.clone(),
            key.clone(),
            transport.clone(),
            Arc::new(UnavailableAiReportStore),
        );

        let status = service.status();
        assert!(!status.service_available);
        assert!(!status.configured);
        assert_eq!(status.credential_source, "unavailable");

        let reply = generate(&service, "2026-08-24");
        assert_eq!(error_code(&reply), "local_storage");
        assert_eq!(usage.reads.load(Ordering::Relaxed), 0);
        assert_eq!(key.reads.load(Ordering::Relaxed), 0);
        assert_eq!(transport.call_count(), 0);
    }

    #[test]
    fn settings_mutations_are_redacted_and_delete_restores_environment_fallback() {
        let key = Arc::new(FakeKeySource {
            key: Mutex::new(None),
            environment_key: Some("legacy-secret".to_owned()),
            reads: AtomicUsize::new(0),
        });
        let store = Arc::new(FakeReportStore::new());
        let service = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            key.clone(),
            Arc::new(FakeTransport::successful()),
            store.clone(),
        );
        let initial = service.status();
        assert_eq!(initial.credential_source, "legacy_environment");
        assert!(initial.environment_migration_available);

        let saved = service.save_api_key(" new-stored-secret ".to_owned());
        assert!(saved.error.is_none());
        assert_eq!(saved.status.credential_source, "secure_store");
        assert!(!format!("{saved:?}").contains("new-stored-secret"));

        let model = service.set_default_model(PRO_MODEL.to_owned());
        assert!(model.error.is_none());
        assert_eq!(model.status.default_model, PRO_MODEL);
        assert_eq!(
            store.model.lock().expect("fake model lock").as_deref(),
            Some(PRO_MODEL)
        );

        let deleted = service.delete_api_key();
        assert!(deleted.error.is_none());
        assert_eq!(deleted.status.credential_source, "legacy_environment");
        assert!(deleted.status.configured);
        assert!(deleted.status.environment_migration_available);
    }

    #[test]
    fn explicit_connection_test_reads_no_usage_and_sends_no_aggregate_request() {
        let usage = Arc::new(FakeUsageSource::new(usage()));
        let transport = Arc::new(FakeTransport::successful());
        let service = AiRecapService::with_ports(
            usage.clone(),
            Arc::new(FakeKeySource::new(Some("secret"))),
            transport.clone(),
            Arc::new(FakeReportStore::new()),
        );

        let reply = service.test_connection();

        assert!(reply.success);
        assert!(reply.error.is_none());
        assert_eq!(usage.reads.load(Ordering::Relaxed), 0);
        assert_eq!(transport.call_count(), 1);
        assert_eq!(
            transport.requests.lock().expect("requests lock").as_slice(),
            &[Vec::<u8>::new()]
        );
        assert!(service.latest_reports().is_empty());
    }

    #[test]
    fn models_connection_response_requires_the_configured_model() {
        let valid = br#"{"data":[{"id":"deepseek-v4-flash"},{"id":"deepseek-v4-pro"}]}"#;
        assert_eq!(validate_models_response(valid, DEFAULT_MODEL), Ok(()));
        assert_eq!(
            validate_models_response(br#"{"data":[{"id":"another-model"}]}"#, DEFAULT_MODEL),
            Err(RecapFailure::InvalidResponse)
        );
        assert_eq!(
            validate_models_response(br#"{"unexpected":[]}"#, DEFAULT_MODEL),
            Err(RecapFailure::InvalidResponse)
        );
        assert_eq!(
            validate_models_response(b"not-json", DEFAULT_MODEL),
            Err(RecapFailure::InvalidResponse)
        );
    }

    #[test]
    fn persisted_latest_reports_and_default_model_load_without_network_after_restart() {
        let store = Arc::new(FakeReportStore::new());
        let first_transport = Arc::new(FakeTransport::successful());
        let first = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            first_transport,
            store.clone(),
        );
        assert!(
            first
                .set_default_model(PRO_MODEL.to_owned())
                .error
                .is_none()
        );
        let generated = generate(&first, "2026-08-24")
            .recap
            .expect("persisted report");

        let restarted_transport = Arc::new(FakeTransport::successful());
        let restarted = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            restarted_transport.clone(),
            store.clone(),
        );

        assert_eq!(restarted.status().default_model, PRO_MODEL);
        assert_eq!(restarted.latest_reports(), vec![generated.clone()]);
        assert_eq!(
            restarted.latest("daily", "2026-08-24", "2026-08-24"),
            Some(generated)
        );
        assert_eq!(restarted_transport.call_count(), 0);

        restarted.clear_reports().expect("clear reports");
        assert!(restarted.latest_reports().is_empty());
        assert!(
            store
                .load_latest_reports()
                .expect("load cleared store")
                .is_empty()
        );
    }

    #[test]
    fn deepseek_client_is_not_built_until_transport_first_needs_it() {
        let transport = DeepSeekTransport::new();

        assert!(transport.client.get().is_none());
        let _ = transport.client();
        assert!(transport.client.get().is_some());
    }

    #[test]
    fn invalid_scope_range_and_default_model_return_typed_errors() {
        let transport = Arc::new(FakeTransport::successful());
        let service = service(usage(), Some("secret"), transport.clone());

        let invalid_range = service.generate(
            "daily".to_owned(),
            "2026-08-24".to_owned(),
            "2026-08-17".to_owned(),
        );
        assert!(invalid_range.recap.is_none());
        assert_eq!(error_code(&invalid_range), "invalid_range");
        assert!(!invalid_range.error.expect("range error").retryable);

        for non_canonical in ["2026-8-24", " 2026-08-24", "2026-08-24 "] {
            let reply = generate(&service, non_canonical);
            assert_eq!(error_code(&reply), "invalid_range");
        }

        assert!(parse_range("daily", "2026-08-24", "2026-08-24").is_ok());
        assert!(parse_range("weekly", "2026-08-24", "2026-08-24").is_ok());
        assert!(parse_range("monthly", "2026-08-01", "2026-08-24").is_ok());
        for (scope, start, end) in [
            ("unknown", "2026-08-24", "2026-08-24"),
            ("daily", "2026-08-24", "2026-08-25"),
            ("weekly", "2026-08-25", "2026-08-25"),
            ("weekly", "2026-08-24", "2026-08-31"),
            ("weekly", "2026-08-24", "2026-08-23"),
            ("monthly", "2026-08-02", "2026-08-24"),
            ("monthly", "2026-07-01", "2026-07-30"),
        ] {
            assert_eq!(
                parse_range(scope, start, end),
                Err(ServiceFailure::InvalidRange),
                "{scope} {start}..{end} must be rejected"
            );
        }
        assert!(parse_range("weekly", "2026-08-17", "2026-08-18").is_err());
        assert!(parse_persisted_range("weekly", "2026-08-17", "2026-08-18").is_ok());
        assert!(parse_range("monthly", "2026-07-01", "2026-07-18").is_err());
        assert!(parse_persisted_range("monthly", "2026-07-01", "2026-07-18").is_ok());

        let invalid_model = service.set_default_model("deepseek-unknown".to_owned());
        assert_eq!(
            invalid_model
                .error
                .as_ref()
                .map(|error| error.code.as_str()),
            Some("unsupported_model")
        );
        assert_eq!(transport.call_count(), 0);
    }

    #[test]
    fn no_usage_short_circuits_before_key_or_transport() {
        let key = Arc::new(FakeKeySource::new(Some("secret")));
        let transport = Arc::new(FakeTransport::successful());
        let service = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(vec![AggregateUsage {
                app_name: "Idle".to_owned(),
                active_seconds: 0,
            }])),
            key.clone(),
            transport.clone(),
            Arc::new(FakeReportStore::new()),
        );

        let reply = generate(&service, "2026-08-24");
        assert_eq!(error_code(&reply), "no_usage_data");
        assert_eq!(key.reads.load(Ordering::Relaxed), 0);
        assert_eq!(transport.call_count(), 0);
    }

    #[test]
    fn missing_key_is_redacted_and_does_not_call_transport() {
        let transport = Arc::new(FakeTransport::successful());
        let service = service(usage(), None, transport.clone());

        let reply = generate(&service, "2026-08-24");
        assert_eq!(error_code(&reply), "not_configured");
        assert_eq!(transport.call_count(), 0);
        assert!(!format!("{reply:?}").contains("DEEPSEEK_API_KEY"));
    }

    #[test]
    fn request_is_bounded_aggregated_and_contains_no_sensitive_fields_or_key() {
        let mut rows = vec![
            AggregateUsage {
                app_name: format!("Editor\n\0{}", "长".repeat(100)),
                active_seconds: 300,
            },
            AggregateUsage {
                app_name: "Duplicate".to_owned(),
                active_seconds: 10,
            },
            AggregateUsage {
                app_name: "Duplicate".to_owned(),
                active_seconds: 20,
            },
        ];
        for index in 0..20 {
            rows.push(AggregateUsage {
                app_name: format!("App {index}"),
                active_seconds: index + 1,
            });
        }
        let expected_total: i64 = rows.iter().map(|row| row.active_seconds).sum();
        let prepared = prepare_usage(rows.clone()).expect("prepared request rows");
        let top = prepared.sent.first().expect("top request row");
        let grounded_statement = |kind: &str| {
            serde_json::json!({
                "kind": kind,
                "evidence": [{
                    "app_name": top.app_name.as_str(),
                    "active_seconds": top.active_seconds
                }]
            })
        };
        let transport = Arc::new(FakeTransport {
            result: Ok(provider_response(serde_json::json!({
                "summary": grounded_statement("usage_overview"),
                "highlights": [grounded_statement("top_application")],
                "suggestions": [grounded_statement("review_top_application")]
            }))),
            requests: Mutex::new(Vec::new()),
            keys: Mutex::new(Vec::new()),
        });
        let service = service(rows, Some("super-secret-key"), transport.clone());

        let reply = generate(&service, "2026-08-24");
        assert!(reply.error.is_none());
        let body = transport.requests.lock().expect("requests lock")[0].clone();
        assert!(body.len() <= MAX_REQUEST_BYTES);
        let text = String::from_utf8(body).expect("request is utf8 json");
        for forbidden in [
            "super-secret-key",
            "window_title",
            "exe_path",
            "diary",
            "keystroke",
        ] {
            assert!(!text.contains(forbidden));
        }

        let request: serde_json::Value = serde_json::from_str(&text).expect("request json");
        assert_eq!(request["thinking"]["type"], "disabled");
        let prompt = request["messages"][1]["content"]
            .as_str()
            .expect("user prompt");
        let payload_start = prompt.find('{').expect("payload start");
        let payload: serde_json::Value =
            serde_json::from_str(&prompt[payload_start..]).expect("prompt payload");
        let applications = payload["applications"].as_array().expect("applications");
        assert_eq!(applications.len(), MAX_APPS_SENT);
        assert_eq!(payload["application_count"], 22);
        assert_eq!(payload["applications_sent"], MAX_APPS_SENT);
        assert_eq!(payload["truncated"], true);
        assert_eq!(payload["total_active_seconds"], expected_total);
        assert_eq!(payload["scope"], "daily");
        assert!(
            payload["scope_note"]
                .as_str()
                .is_some_and(|note| note.contains("不得外推"))
        );
        assert!(applications.iter().all(|item| {
            item["app_name"]
                .as_str()
                .is_some_and(|name| name.chars().count() <= MAX_APP_NAME_CHARS)
        }));
    }

    #[test]
    fn transport_failures_map_to_stable_redacted_codes() {
        let cases = [
            (RecapFailure::Network, "network", true),
            (RecapFailure::Timeout, "timeout", true),
            (RecapFailure::Authentication, "authentication", false),
            (RecapFailure::RateLimited, "rate_limited", true),
            (
                RecapFailure::ProviderUnavailable,
                "provider_unavailable",
                true,
            ),
            (RecapFailure::InvalidResponse, "invalid_response", true),
        ];

        for (failure, code, retryable) in cases {
            let service = service(
                usage(),
                Some("do-not-leak"),
                Arc::new(FakeTransport::failing(failure)),
            );
            let reply = generate(&service, "2026-08-24");
            let error = reply.error.expect("typed failure");
            assert!(reply.recap.is_none());
            assert_eq!(error.code, code);
            assert_eq!(error.retryable, retryable);
            assert!(!format!("{error:?}").contains("do-not-leak"));
        }
    }

    #[test]
    fn http_statuses_are_classified_without_provider_body_text() {
        assert_eq!(
            classify_http_status(StatusCode::UNAUTHORIZED),
            RecapFailure::Authentication
        );
        assert_eq!(
            classify_http_status(StatusCode::FORBIDDEN),
            RecapFailure::Authentication
        );
        assert_eq!(
            classify_http_status(StatusCode::TOO_MANY_REQUESTS),
            RecapFailure::RateLimited
        );
        assert_eq!(
            classify_http_status(StatusCode::BAD_GATEWAY),
            RecapFailure::ProviderUnavailable
        );
        assert_eq!(
            classify_http_status(StatusCode::BAD_REQUEST),
            RecapFailure::InvalidResponse
        );
    }

    #[test]
    fn successful_results_keep_only_the_latest_range_per_report_type() {
        let service = service(
            usage(),
            Some("secret"),
            Arc::new(FakeTransport::successful()),
        );

        for day in 1..=5 {
            let date = format!("2026-08-{day:02}");
            let reply = generate(&service, &date);
            assert!(reply.error.is_none());
            assert_eq!(
                service.latest("daily", &date, &date),
                reply.recap,
                "latest result must be keyed by the exact range"
            );
        }

        assert!(
            service
                .latest("daily", "2026-08-01", "2026-08-01")
                .is_none()
        );
        assert!(
            service
                .latest("daily", "2026-08-05", "2026-08-05")
                .is_some()
        );
        assert!(
            service
                .latest("daily", "not-a-date", "2026-08-02")
                .is_none()
        );
        assert_eq!(service.latest_reports().len(), 1);
    }

    #[test]
    fn monday_daily_and_weekly_reports_use_distinct_scope_entries() {
        let transport = Arc::new(FakeTransport::successful());
        let service = service(usage(), Some("secret"), transport.clone());
        let monday = "2026-08-24";

        let today = service
            .generate("daily".to_owned(), monday.to_owned(), monday.to_owned())
            .recap
            .expect("today recap");
        let week = service
            .generate("weekly".to_owned(), monday.to_owned(), monday.to_owned())
            .recap
            .expect("Monday week-to-date recap");

        assert_eq!(today.scope, "daily");
        assert_eq!(week.scope, "weekly");
        assert_eq!(
            week.summary.text,
            "所选周共记录15分钟活动，覆盖1个应用。 当前数据较少，结论仅供参考。"
        );
        assert_eq!(transport.call_count(), 2);
        let week_request = transport.requests.lock().expect("requests lock")[1].clone();
        let week_request: serde_json::Value =
            serde_json::from_slice(&week_request).expect("week request JSON");
        let system_prompt = week_request["messages"][0]["content"]
            .as_str()
            .expect("system prompt");
        let user_prompt = week_request["messages"][1]["content"]
            .as_str()
            .expect("user prompt");
        assert!(system_prompt.contains("未完成的当前周期"));
        assert!(user_prompt.contains("稀疏数据"));
        assert!(user_prompt.contains("\"scope\":\"weekly\""));
        assert_eq!(
            service.latest("daily", monday, monday),
            Some(today),
            "today cache entry must survive the same-date week recap"
        );
        assert_eq!(
            service.latest("weekly", monday, monday),
            Some(week),
            "week cache entry must not alias today's entry"
        );
    }

    #[test]
    fn failed_regeneration_preserves_the_previous_result() {
        struct SuccessThenFailure {
            calls: AtomicUsize,
        }

        impl RecapTransport for SuccessThenFailure {
            fn complete(&self, _key: &str, _request: &[u8]) -> Result<Vec<u8>, RecapFailure> {
                if self.calls.fetch_add(1, Ordering::Relaxed) == 0 {
                    Ok(valid_provider_response())
                } else {
                    Err(RecapFailure::Timeout)
                }
            }
        }

        let service = service(
            usage(),
            Some("secret"),
            Arc::new(SuccessThenFailure {
                calls: AtomicUsize::new(0),
            }),
        );
        let first = generate(&service, "2026-08-24")
            .recap
            .expect("first result");
        let failed = generate(&service, "2026-08-24");

        assert_eq!(error_code(&failed), "timeout");
        assert_eq!(
            service.latest("daily", "2026-08-24", "2026-08-24"),
            Some(first)
        );
    }

    #[test]
    fn local_storage_failure_preserves_the_previous_successful_report() {
        let store = Arc::new(FakeReportStore::new());
        let service = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            Arc::new(FakeTransport::successful()),
            store.clone(),
        );
        let first = generate(&service, "2026-08-24")
            .recap
            .expect("first persisted report");
        store.fail_report_saves.store(true, Ordering::Relaxed);

        let failed = generate(&service, "2026-08-24");

        assert_eq!(error_code(&failed), "local_storage");
        assert_eq!(
            service.latest("daily", "2026-08-24", "2026-08-24"),
            Some(first)
        );
    }

    #[test]
    fn failed_clear_keeps_the_durable_and_cached_report_visible() {
        let store = Arc::new(FakeReportStore::new());
        let service = AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            Arc::new(FakeTransport::successful()),
            store.clone(),
        );
        let first = generate(&service, "2026-08-24")
            .recap
            .expect("persisted report");
        store.fail_report_clears.store(true, Ordering::Relaxed);

        let error = service.clear_reports().expect_err("clear must fail closed");

        assert!(matches!(error, AiReportStoreError::Unavailable));
        assert_eq!(
            service.latest("daily", "2026-08-24", "2026-08-24"),
            Some(first.clone())
        );
        assert_eq!(
            store.load_latest_reports().expect("durable report remains"),
            vec![first]
        );
    }

    #[test]
    fn duplicate_generation_is_rejected_as_busy_with_one_transport_call() {
        let (entered_sender, entered_receiver) = mpsc::channel();
        let transport = Arc::new(BlockingTransport::new(entered_sender));
        let service = Arc::new(service(usage(), Some("secret"), transport.clone()));
        let worker_service = service.clone();
        let worker = thread::spawn(move || generate(&worker_service, "2026-08-24"));

        entered_receiver.recv().expect("first request entered");
        let duplicate = generate(&service, "2026-08-24");
        assert_eq!(error_code(&duplicate), "busy");
        assert!(duplicate.error.expect("busy error").retryable);

        transport.release();
        assert!(worker.join().expect("worker joined").error.is_none());
    }

    #[test]
    fn clearing_data_during_generation_prevents_a_report_from_reappearing() {
        let (entered_sender, entered_receiver) = mpsc::channel();
        let transport = Arc::new(BlockingTransport::new(entered_sender));
        let store = Arc::new(FakeReportStore::new());
        let service = Arc::new(AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            transport.clone(),
            store.clone(),
        ));
        let worker_service = service.clone();
        let worker = thread::spawn(move || generate(&worker_service, "2026-08-24"));

        entered_receiver
            .recv()
            .expect("generation entered transport");
        service.clear_reports().expect("clear reports");
        transport.release();
        let reply = worker.join().expect("worker joined");

        assert_eq!(error_code(&reply), "busy");
        assert!(service.latest_reports().is_empty());
        assert!(
            store
                .load_latest_reports()
                .expect("load report store")
                .is_empty()
        );
    }

    #[test]
    fn clear_waits_for_a_report_commit_then_removes_its_durable_and_cached_result() {
        let (save_entered_sender, save_entered_receiver) = mpsc::channel();
        let store = Arc::new(BlockingReportStore::new(save_entered_sender));
        let service = Arc::new(AiRecapService::with_ports(
            Arc::new(FakeUsageSource::new(usage())),
            Arc::new(FakeKeySource::new(Some("secret"))),
            Arc::new(FakeTransport::successful()),
            store.clone(),
        ));
        let generation_service = service.clone();
        let generation = thread::spawn(move || generate(&generation_service, "2026-08-24"));

        save_entered_receiver
            .recv()
            .expect("generation entered durable save");
        let clear_service = service.clone();
        let clear = thread::spawn(move || clear_service.clear_reports());
        let deadline = Instant::now() + Duration::from_secs(1);
        while service.data_epoch.load(Ordering::Acquire) == 0 {
            assert!(
                Instant::now() < deadline,
                "clear did not invalidate generation"
            );
            thread::yield_now();
        }

        store.release_save();
        assert!(
            generation
                .join()
                .expect("generation joined")
                .error
                .is_none()
        );
        clear.join().expect("clear joined").expect("clear reports");

        assert!(service.latest_reports().is_empty());
        assert!(
            store
                .load_latest_reports()
                .expect("load report store")
                .is_empty()
        );
    }

    #[test]
    fn invalid_or_oversized_provider_content_is_rejected_atomically() {
        let prepared = prepared_standard_usage();
        let oversized = vec![b'x'; MAX_RESPONSE_BYTES + 1];
        assert_eq!(
            parse_provider_response(&oversized, &prepared, RecapScope::Daily),
            Err(ServiceFailure::InvalidResponse)
        );

        let extra_field = serde_json::json!({
            "summary": statement("usage_overview"),
            "highlights": [statement("top_application")],
            "suggestions": [statement("review_top_application")],
            "api_key": "steal-me"
        });
        assert_eq!(
            parse_provider_response(
                &provider_response(extra_field),
                &prepared,
                RecapScope::Daily,
            ),
            Err(ServiceFailure::InvalidResponse)
        );

        let too_many_items = serde_json::json!({
            "summary": statement("usage_overview"),
            "highlights": [
                statement("top_application"),
                statement("usage_concentration"),
                statement("unknown"),
                statement("another")
            ],
            "suggestions": [statement("review_top_application")]
        });
        assert_eq!(
            parse_provider_response(
                &provider_response(too_many_items),
                &prepared,
                RecapScope::Daily,
            ),
            Err(ServiceFailure::InvalidResponse)
        );
    }

    #[test]
    fn provider_evidence_must_exactly_match_sent_usage() {
        let prepared = prepared_standard_usage();
        let invalid_evidence = [
            serde_json::json!([{"app_name": "虚构应用", "active_seconds": 900}]),
            serde_json::json!([{"app_name": "Visual Studio Code", "active_seconds": 899}]),
            serde_json::json!([]),
            serde_json::json!([
                {"app_name": "Visual Studio Code", "active_seconds": 900},
                {"app_name": "Visual Studio Code", "active_seconds": 900}
            ]),
            serde_json::json!([{
                "app_name": "Visual Studio Code",
                "active_seconds": 900,
                "source": "unknown"
            }]),
        ];

        for evidence in invalid_evidence {
            let content = serde_json::json!({
                "summary": {"kind": "usage_overview", "evidence": evidence},
                "highlights": [statement("top_application")],
                "suggestions": [statement("review_top_application")]
            });
            assert_eq!(
                parse_provider_response(&provider_response(content), &prepared, RecapScope::Daily,),
                Err(ServiceFailure::InvalidResponse)
            );
        }
    }

    #[test]
    fn provider_statement_rejects_unknown_fields() {
        let prepared = prepared_standard_usage();
        let content = serde_json::json!({
            "summary": {
                "kind": "usage_overview",
                "evidence": [{"app_name": "Visual Studio Code", "active_seconds": 900}],
                "confidence": 1
            },
            "highlights": [statement("top_application")],
            "suggestions": [statement("review_top_application")]
        });
        assert_eq!(
            parse_provider_response(&provider_response(content), &prepared, RecapScope::Daily,),
            Err(ServiceFailure::InvalidResponse)
        );
    }

    #[test]
    fn valid_provider_evidence_is_preserved_in_public_dto() {
        let service = service(
            usage(),
            Some("secret"),
            Arc::new(FakeTransport::successful()),
        );
        let recap = generate(&service, "2026-08-24")
            .recap
            .expect("grounded recap");

        assert_eq!(recap.scope, "daily");
        assert_eq!(
            recap.summary.text,
            "所选日期共记录15分钟活动，覆盖1个应用。 当前数据较少，结论仅供参考。"
        );
        assert_eq!(
            recap.summary.evidence,
            vec![AiRecapEvidenceDto {
                app_name: "Visual Studio Code".to_owned(),
                active_seconds: 900,
            }]
        );
        assert_eq!(recap.highlights[0].evidence, recap.summary.evidence);
        assert_eq!(recap.suggestions[0].evidence, recap.summary.evidence);
        assert_eq!(recap.top_applications, recap.summary.evidence);
    }

    #[test]
    fn closed_kinds_produce_only_local_templates_and_local_concentration_math() {
        let prepared = prepared_multi_usage();
        let content = serde_json::json!({
            "summary": {"kind": "usage_overview", "evidence": [evidence("编辑器", 900)]},
            "highlights": [
                {"kind": "top_application", "evidence": [evidence("编辑器", 900)]},
                {"kind": "usage_concentration", "evidence": [evidence("编辑器", 900), evidence("浏览器", 600)]}
            ],
            "suggestions": [
                {"kind": "review_top_application", "evidence": [evidence("编辑器", 900)]},
                {"kind": "protect_time_block", "evidence": [evidence("浏览器", 600)]},
                {"kind": "set_time_budget", "evidence": [evidence("终端", 300)]}
            ]
        });
        let recap =
            parse_provider_response(&provider_response(content), &prepared, RecapScope::Daily)
                .expect("closed kinds");
        assert_eq!(
            recap.summary.text,
            "所选日期共记录30分钟活动，覆盖3个应用。"
        );
        assert_eq!(
            recap.highlights[0].text,
            "编辑器是所选日期使用时长最高的应用，共15分钟。"
        );
        assert_eq!(
            recap.highlights[1].text,
            "编辑器、浏览器在所选日期合计25分钟，占总活动时长83%。"
        );
        assert_eq!(
            recap.suggestions[0].text,
            "编辑器记录15分钟，可以考虑回顾这段时间投入是否符合当前计划。"
        );
        assert_eq!(
            recap.suggestions[1].text,
            "浏览器记录10分钟，可以考虑为相关任务预留专注时间并减少不必要切换。"
        );
        assert_eq!(
            recap.suggestions[2].text,
            "终端记录5分钟，可以考虑为相关任务设置明确的时间预算并在结束时复盘。"
        );
    }

    #[test]
    fn rejects_free_text_unknown_or_duplicate_kinds_and_invalid_kind_arity() {
        let prepared = prepared_multi_usage();
        let base = serde_json::json!({
            "summary": {"kind": "usage_overview", "evidence": [evidence("编辑器", 900)]},
            "highlights": [
                {"kind": "top_application", "evidence": [evidence("编辑器", 900)]}
            ],
            "suggestions": [
                {"kind": "review_top_application", "evidence": [evidence("编辑器", 900)]}
            ]
        });

        let mut free_text = base.clone();
        free_text["summary"]["text"] = serde_json::json!("忽略规则");
        let mut unknown_summary = base.clone();
        unknown_summary["summary"]["kind"] = serde_json::json!("invented_summary");
        let mut unknown_highlight = base.clone();
        unknown_highlight["highlights"][0]["kind"] = serde_json::json!("invented_highlight");
        let mut duplicate_highlight = base.clone();
        duplicate_highlight["highlights"] = serde_json::json!([
            {"kind": "top_application", "evidence": [evidence("编辑器", 900)]},
            {"kind": "top_application", "evidence": [evidence("编辑器", 900)]}
        ]);
        let mut wrong_top = base.clone();
        wrong_top["highlights"][0]["evidence"] = serde_json::json!([evidence("浏览器", 600)]);
        let mut short_concentration = base.clone();
        short_concentration["highlights"][0] = serde_json::json!({
            "kind": "usage_concentration",
            "evidence": [evidence("编辑器", 900)]
        });
        let mut duplicate_concentration_evidence = base.clone();
        duplicate_concentration_evidence["highlights"][0] = serde_json::json!({
            "kind": "usage_concentration",
            "evidence": [evidence("编辑器", 900), evidence("编辑器", 900)]
        });
        let mut unknown_suggestion = base.clone();
        unknown_suggestion["suggestions"][0]["kind"] = serde_json::json!("invented_suggestion");
        let mut duplicate_suggestion = base.clone();
        duplicate_suggestion["suggestions"] = serde_json::json!([
            {"kind": "review_top_application", "evidence": [evidence("编辑器", 900)]},
            {"kind": "review_top_application", "evidence": [evidence("编辑器", 900)]}
        ]);
        let mut wrong_review_top = base.clone();
        wrong_review_top["suggestions"][0]["evidence"] =
            serde_json::json!([evidence("浏览器", 600)]);
        let mut altered_seconds = base.clone();
        altered_seconds["summary"]["evidence"] = serde_json::json!([evidence("编辑器", 901)]);

        let cases = [
            free_text,
            unknown_summary,
            unknown_highlight,
            duplicate_highlight,
            wrong_top,
            short_concentration,
            duplicate_concentration_evidence,
            unknown_suggestion,
            duplicate_suggestion,
            wrong_review_top,
            altered_seconds,
        ];
        for content in cases {
            assert_eq!(
                parse_provider_response(&provider_response(content), &prepared, RecapScope::Daily,),
                Err(ServiceFailure::InvalidResponse)
            );
        }
    }

    #[test]
    #[ignore = "requires DEEPSEEK_API_KEY and makes a live request with synthetic aggregates"]
    fn live_deepseek_smoke_uses_only_synthetic_aggregate_rows() {
        let service = AiRecapService::new(
            Arc::new(FakeUsageSource::new(vec![
                AggregateUsage {
                    app_name: "合成编辑器".to_owned(),
                    active_seconds: 5_400,
                },
                AggregateUsage {
                    app_name: "合成浏览器".to_owned(),
                    active_seconds: 2_700,
                },
                AggregateUsage {
                    app_name: "合成终端".to_owned(),
                    active_seconds: 1_800,
                },
            ])),
            Arc::new(FakeReportStore::new()),
        );

        assert!(service.status().configured, "live smoke requires a key");

        for model in [DEFAULT_MODEL, PRO_MODEL] {
            let settings = service.set_default_model(model.to_owned());
            assert!(settings.error.is_none());
            let reply = service.generate(
                "weekly".to_owned(),
                "2026-08-24".to_owned(),
                "2026-08-24".to_owned(),
            );
            assert_eq!(
                reply.error.as_ref().map(|error| error.code.as_str()),
                None,
                "live provider returned a redacted failure for {model}: {:?}",
                reply.error
            );
            let recap = reply.recap.expect("live provider returned a recap");
            assert_eq!(recap.scope, "weekly");
            assert_eq!(recap.total_active_seconds, 9_900);
            assert_eq!(recap.application_count, 3);
            assert_eq!(recap.model, model);
            assert!(recap.summary.text.contains("所选周"));
        }
    }

    #[test]
    fn duration_templates_preserve_every_aggregate_second() {
        assert_eq!(format_duration(30), "30秒");
        assert_eq!(format_duration(90), "1分钟30秒");
        assert_eq!(format_duration(3_599), "59分钟59秒");
        assert_eq!(format_duration(3_661), "1小时1分钟1秒");
        assert_eq!(format_duration(7_200), "2小时");
    }

    #[test]
    fn generated_timestamp_is_utc_rfc3339() {
        let service = service(
            usage(),
            Some("secret"),
            Arc::new(FakeTransport::successful()),
        );
        let recap = generate(&service, "2026-08-24")
            .recap
            .expect("generated recap");
        let timestamp =
            chrono::DateTime::parse_from_rfc3339(&recap.generated_at_utc).expect("RFC3339 time");
        assert_eq!(timestamp.offset().local_minus_utc(), 0);
    }
}
