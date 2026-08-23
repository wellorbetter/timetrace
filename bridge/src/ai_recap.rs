//! Privacy-bounded DeepSeek recap service.
//!
//! The service accepts only aggregate application display names and active
//! durations from a narrow data source. Credentials, HTTP details, and the
//! full TimeTrace data store stay behind separate ports so neither Flutter nor
//! the recap orchestration can accidentally access sensitive records.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{ErrorKind, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use chrono::{Datelike, NaiveDate, SecondsFormat, Utc, Weekday};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use timetrace_core::DataStore;

const API_URL: &str = "https://api.deepseek.com/chat/completions";
const DEFAULT_MODEL: &str = "deepseek-v4-flash";
const PRO_MODEL: &str = "deepseek-v4-pro";
const PROVIDER_NAME: &str = "DeepSeek";
const MAX_LATEST_RESULTS: usize = 4;
const MAX_APPS_SENT: usize = 12;
const MAX_APP_NAME_CHARS: usize = 80;
const MAX_KEY_BYTES: usize = 4096;
const MAX_REQUEST_BYTES: usize = 24 * 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
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

/// Narrow credential port used once for every explicit generation request.
pub trait ApiKeySource: Send + Sync {
    /// Returns the current DeepSeek key, or `None` when it is not safely usable.
    fn read_deepseek_key(&self) -> Option<String>;
}

/// Process-environment implementation of [`ApiKeySource`].
pub struct EnvironmentApiKeySource;

impl ApiKeySource for EnvironmentApiKeySource {
    fn read_deepseek_key(&self) -> Option<String> {
        std::env::var("DEEPSEEK_API_KEY")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty() && value.len() <= MAX_KEY_BYTES)
    }
}

/// Redacted transport failures that can cross the service boundary safely.
#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
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
}

/// Provider configuration state safe to expose to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapStatusDto {
    /// Whether a non-empty, bounded `DEEPSEEK_API_KEY` is available.
    pub configured: bool,
    /// Human-readable provider name; never contains endpoint or key data.
    pub provider: String,
    /// Model selected when the UI has not chosen another supported model.
    pub default_model: String,
}

/// A complete, validated recap result safe to expose to Flutter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapDto {
    /// Logical period selected by the user: `today` or `week_to_date`.
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
    /// Active seconds across every valid aggregate row, including truncated rows.
    pub total_active_seconds: i64,
    /// Number of valid aggregate applications before the top-12 truncation.
    pub application_count: i64,
}

/// One aggregate usage row cited by an AI recap statement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiRecapEvidenceDto {
    /// Sanitized application display name sent to the provider.
    pub app_name: String,
    /// Exact active duration sent for this application.
    pub active_seconds: i64,
}

/// One validated Chinese statement and its provider-supplied evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
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
    latest: Mutex<LatestCache>,
    in_flight: AtomicBool,
}

impl AiRecapService {
    /// Creates a production service over an aggregate-only usage source.
    pub fn new(usage_source: Arc<dyn AggregateUsageSource>) -> Self {
        Self::with_ports(
            usage_source,
            Arc::new(EnvironmentApiKeySource),
            Arc::new(DeepSeekTransport::new()),
        )
    }

    /// Reads the current local provider configuration without making a request.
    pub fn status(&self) -> AiRecapStatusDto {
        AiRecapStatusDto {
            configured: self.key_source.read_deepseek_key().is_some(),
            provider: PROVIDER_NAME.to_owned(),
            default_model: DEFAULT_MODEL.to_owned(),
        }
    }

    /// Returns the latest result for one exact logical scope and date range.
    pub fn latest(&self, scope: &str, start_date: &str, end_date: &str) -> Option<AiRecapDto> {
        let range = parse_range(scope, start_date, end_date).ok()?;
        self.lock_latest().get(&range)
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
        model: String,
    ) -> AiRecapGenerateReplyDto {
        let range = match parse_range(&scope, &start_date, &end_date) {
            Ok(range) => range,
            Err(failure) => return AiRecapGenerateReplyDto::failure(failure),
        };
        let model = match validate_model(&model) {
            Ok(model) => model,
            Err(failure) => return AiRecapGenerateReplyDto::failure(failure),
        };
        let _in_flight = match InFlightGuard::acquire(&self.in_flight) {
            Ok(guard) => guard,
            Err(failure) => return AiRecapGenerateReplyDto::failure(failure),
        };

        match self.generate_inner(range, model) {
            Ok(recap) => AiRecapGenerateReplyDto::success(recap),
            Err(failure) => AiRecapGenerateReplyDto::failure(failure),
        }
    }

    fn with_ports(
        usage_source: Arc<dyn AggregateUsageSource>,
        key_source: Arc<dyn ApiKeySource>,
        transport: Arc<dyn RecapTransport>,
    ) -> Self {
        Self {
            usage_source,
            key_source,
            transport,
            latest: Mutex::new(LatestCache::default()),
            in_flight: AtomicBool::new(false),
        }
    }

    fn generate_inner(
        &self,
        range: RangeKey,
        model: &'static str,
    ) -> Result<AiRecapDto, ServiceFailure> {
        let usage = self.usage_source.read(range.start, range.end);
        let prepared = prepare_usage(usage)?;

        let key = self
            .key_source
            .read_deepseek_key()
            .ok_or(ServiceFailure::NotConfigured)?;
        let request = build_request(&range, model, &prepared)?;
        let completion = self.transport.complete(&key, &request);
        drop(key);
        let response = completion.map_err(ServiceFailure::Transport)?;
        let parsed = parse_provider_response(&response, &prepared, range.scope)?;

        let recap = AiRecapDto {
            scope: range.scope.as_str().to_owned(),
            start_date: range.start.to_string(),
            end_date: range.end.to_string(),
            generated_at_utc: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            model: model.to_owned(),
            summary: parsed.summary,
            highlights: parsed.highlights,
            suggestions: parsed.suggestions,
            total_active_seconds: prepared.total_seconds,
            application_count: prepared.application_count,
        };
        self.lock_latest().insert(range, recap.clone());
        Ok(recap)
    }

    fn lock_latest(&self) -> MutexGuard<'_, LatestCache> {
        match self.latest.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum RecapScope {
    Today,
    WeekToDate,
}

impl RecapScope {
    fn parse(value: &str) -> Result<Self, ServiceFailure> {
        match value {
            "today" => Ok(Self::Today),
            "week_to_date" => Ok(Self::WeekToDate),
            _ => Err(ServiceFailure::InvalidRange),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Today => "today",
            Self::WeekToDate => "week_to_date",
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::Today => "今日",
            Self::WeekToDate => "本周截至今日",
        }
    }

    fn prompt_note(self) -> &'static str {
        match self {
            Self::Today => "仅代表所选当日。数据较少时必须保持保守，不得外推日常习惯。",
            Self::WeekToDate => {
                "仅代表从周一到所选今日的周内累计，并非完整自然周。数据较少时必须保持保守，不得外推整周趋势。"
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
    entries: BTreeMap<RangeKey, AiRecapDto>,
    order: VecDeque<RangeKey>,
}

impl LatestCache {
    fn get(&self, range: &RangeKey) -> Option<AiRecapDto> {
        self.entries.get(range).cloned()
    }

    fn insert(&mut self, range: RangeKey, recap: AiRecapDto) {
        self.order.retain(|existing| *existing != range);
        self.entries.insert(range, recap);
        self.order.push_back(range);

        while self.order.len() > MAX_LATEST_RESULTS {
            if let Some(expired) = self.order.pop_front() {
                self.entries.remove(&expired);
            }
        }
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
    InvalidRange,
    UnsupportedModel,
    NoUsageData,
    RequestTooLarge,
    InvalidResponse,
    Busy,
    Transport(RecapFailure),
}

impl ServiceFailure {
    fn into_dto(self) -> AiRecapErrorDto {
        let (code, retryable) = match self {
            Self::NotConfigured => ("not_configured", false),
            Self::InvalidRange => ("invalid_range", false),
            Self::UnsupportedModel => ("unsupported_model", false),
            Self::NoUsageData => ("no_usage_data", false),
            Self::RequestTooLarge => ("request_too_large", false),
            Self::InvalidResponse | Self::Transport(RecapFailure::InvalidResponse) => {
                ("invalid_response", true)
            }
            Self::Busy => ("busy", true),
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
}

impl DeepSeekTransport {
    fn new() -> Self {
        Self {
            client: OnceLock::new(),
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
        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
        {
            return Err(RecapFailure::InvalidResponse);
        }

        let mut bytes = Vec::new();
        let mut bounded = response.take((MAX_RESPONSE_BYTES + 1) as u64);
        bounded.read_to_end(&mut bytes).map_err(|error| {
            if error.kind() == ErrorKind::TimedOut {
                RecapFailure::Timeout
            } else {
                RecapFailure::Network
            }
        })?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(RecapFailure::InvalidResponse);
        }
        Ok(bytes)
    }
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
        "请只依据以下聚合数据选择受限的回顾类型和证据。scope=week_to_date 时，它明确表示周一到今日的未完整自然周；无论 scope，为稀疏数据选择证据时都必须保守。不得输出任何自由文本，不得推断应用类别、窗口内容、文件、账号、健康、人格、绩效或未来趋势：{prompt_json}"
    );
    let request = ChatRequest {
        model,
        messages: [
            Message {
                role: "system",
                content: "你是受限的时间回顾证据选择器。仅依据给定的聚合应用时长输出 JSON 对象；不得输出解释、自由文本或猜测。scope=week_to_date 表示周一到今日的未完整自然周，禁止当作完整周或预测整周；数据稀疏时必须保守。JSON 必须且只能包含 summary、highlights、suggestions。每个对象必须且只能是 {\"kind\":\"受限类型\",\"evidence\":[{\"app_name\":\"输入中的应用名\",\"active_seconds\":输入中的精确秒数}]}；evidence 必须逐字、逐数匹配 applications 中的行。summary 的 kind 必须为 usage_overview。highlights 每项 kind 只能为 top_application 或 usage_concentration，且不得重复；top_application 必须唯一引用 applications[0]，usage_concentration 必须引用 2 到 3 个不重复应用。suggestions 每项 kind 只能为 review_top_application、protect_time_block 或 set_time_budget，且不得重复；review_top_application 必须唯一引用 applications[0]，其他建议必须唯一引用一个应用。highlights 和 suggestions 各为 1 到 3 项。",
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
    let span = end.signed_duration_since(start).num_days();
    let valid = match scope {
        RecapScope::Today => span == 0,
        RecapScope::WeekToDate => start.weekday() == Weekday::Mon && (0..=6).contains(&span),
    };
    if !valid {
        return Err(ServiceFailure::InvalidRange);
    }
    Ok(RangeKey { scope, start, end })
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
                        "{}记录{}，建议回顾这段时间投入是否符合当前计划。",
                        app, duration
                    )
                }
                "protect_time_block" => {
                    format!(
                        "{}记录{}，建议为相关任务预留专注时间并减少不必要切换。",
                        app, duration
                    )
                }
                "set_time_budget" => format!(
                    "{}记录{}，建议为相关任务设置明确的时间预算并在结束时复盘。",
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
    use std::sync::{mpsc, Condvar};
    use std::thread;

    use super::*;

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
        key: Option<String>,
        reads: AtomicUsize,
    }

    impl FakeKeySource {
        fn new(key: Option<&str>) -> Self {
            Self {
                key: key.map(str::to_owned),
                reads: AtomicUsize::new(0),
            }
        }
    }

    impl ApiKeySource for FakeKeySource {
        fn read_deepseek_key(&self) -> Option<String> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            self.key.clone()
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
        )
    }

    fn generate(service: &AiRecapService, date: &str) -> AiRecapGenerateReplyDto {
        service.generate(
            "today".to_owned(),
            date.to_owned(),
            date.to_owned(),
            DEFAULT_MODEL.to_owned(),
        )
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
        );

        assert_eq!(
            service.status(),
            AiRecapStatusDto {
                configured: true,
                provider: "DeepSeek".to_owned(),
                default_model: DEFAULT_MODEL.to_owned(),
            }
        );
        assert_eq!(key.reads.load(Ordering::Relaxed), 1);
        assert_eq!(transport.call_count(), 0);
    }

    #[test]
    fn deepseek_client_is_not_built_until_transport_first_needs_it() {
        let transport = DeepSeekTransport::new();

        assert!(transport.client.get().is_none());
        let _ = transport.client();
        assert!(transport.client.get().is_some());
    }

    #[test]
    fn invalid_scope_range_and_model_return_mutually_exclusive_typed_errors() {
        let transport = Arc::new(FakeTransport::successful());
        let service = service(usage(), Some("secret"), transport.clone());

        let invalid_range = service.generate(
            "today".to_owned(),
            "2026-08-24".to_owned(),
            "2026-08-17".to_owned(),
            DEFAULT_MODEL.to_owned(),
        );
        assert!(invalid_range.recap.is_none());
        assert_eq!(error_code(&invalid_range), "invalid_range");
        assert!(!invalid_range.error.expect("range error").retryable);

        for non_canonical in ["2026-8-24", " 2026-08-24", "2026-08-24 "] {
            let reply = generate(&service, non_canonical);
            assert_eq!(error_code(&reply), "invalid_range");
        }

        assert!(parse_range("today", "2026-08-24", "2026-08-24").is_ok());
        assert!(parse_range("week_to_date", "2026-08-24", "2026-08-24").is_ok());
        for (scope, start, end) in [
            ("unknown", "2026-08-24", "2026-08-24"),
            ("today", "2026-08-24", "2026-08-25"),
            ("week_to_date", "2026-08-25", "2026-08-25"),
            ("week_to_date", "2026-08-24", "2026-08-31"),
            ("week_to_date", "2026-08-24", "2026-08-23"),
        ] {
            assert_eq!(
                parse_range(scope, start, end),
                Err(ServiceFailure::InvalidRange),
                "{scope} {start}..{end} must be rejected"
            );
        }

        let invalid_model = service.generate(
            "today".to_owned(),
            "2026-08-24".to_owned(),
            "2026-08-24".to_owned(),
            "deepseek-unknown".to_owned(),
        );
        assert_eq!(error_code(&invalid_model), "unsupported_model");
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
        assert_eq!(payload["scope"], "today");
        assert!(payload["scope_note"]
            .as_str()
            .is_some_and(|note| note.contains("不得外推")));
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
    fn successful_results_are_keyed_by_range_and_cache_is_bounded() {
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
                service.latest("today", &date, &date),
                reply.recap,
                "latest result must be keyed by the exact range"
            );
        }

        assert!(service
            .latest("today", "2026-08-01", "2026-08-01")
            .is_none());
        assert!(service
            .latest("today", "2026-08-02", "2026-08-02")
            .is_some());
        assert!(service
            .latest("today", "not-a-date", "2026-08-02")
            .is_none());
    }

    #[test]
    fn monday_today_and_week_to_date_use_distinct_cache_entries() {
        let transport = Arc::new(FakeTransport::successful());
        let service = service(usage(), Some("secret"), transport.clone());
        let monday = "2026-08-24";

        let today = service
            .generate(
                "today".to_owned(),
                monday.to_owned(),
                monday.to_owned(),
                DEFAULT_MODEL.to_owned(),
            )
            .recap
            .expect("today recap");
        let week = service
            .generate(
                "week_to_date".to_owned(),
                monday.to_owned(),
                monday.to_owned(),
                DEFAULT_MODEL.to_owned(),
            )
            .recap
            .expect("Monday week-to-date recap");

        assert_eq!(today.scope, "today");
        assert_eq!(week.scope, "week_to_date");
        assert_eq!(
            week.summary.text,
            "本周截至今日共记录15分钟活动，覆盖1个应用。 当前数据较少，结论仅供参考。"
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
        assert!(system_prompt.contains("未完整自然周"));
        assert!(user_prompt.contains("稀疏数据"));
        assert!(user_prompt.contains("\"scope\":\"week_to_date\""));
        assert_eq!(
            service.latest("today", monday, monday),
            Some(today),
            "today cache entry must survive the same-date week recap"
        );
        assert_eq!(
            service.latest("week_to_date", monday, monday),
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
            service.latest("today", "2026-08-24", "2026-08-24"),
            Some(first)
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
    fn invalid_or_oversized_provider_content_is_rejected_atomically() {
        let prepared = prepared_standard_usage();
        let oversized = vec![b'x'; MAX_RESPONSE_BYTES + 1];
        assert_eq!(
            parse_provider_response(&oversized, &prepared, RecapScope::Today),
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
                RecapScope::Today,
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
                RecapScope::Today,
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
                parse_provider_response(&provider_response(content), &prepared, RecapScope::Today,),
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
            parse_provider_response(&provider_response(content), &prepared, RecapScope::Today,),
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

        assert_eq!(recap.scope, "today");
        assert_eq!(
            recap.summary.text,
            "今日共记录15分钟活动，覆盖1个应用。 当前数据较少，结论仅供参考。"
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
            parse_provider_response(&provider_response(content), &prepared, RecapScope::Today)
                .expect("closed kinds");
        assert_eq!(recap.summary.text, "今日共记录30分钟活动，覆盖3个应用。");
        assert_eq!(
            recap.highlights[0].text,
            "编辑器是今日使用时长最高的应用，共15分钟。"
        );
        assert_eq!(
            recap.highlights[1].text,
            "编辑器、浏览器在今日合计25分钟，占总活动时长83%。"
        );
        assert_eq!(
            recap.suggestions[0].text,
            "编辑器记录15分钟，建议回顾这段时间投入是否符合当前计划。"
        );
        assert_eq!(
            recap.suggestions[1].text,
            "浏览器记录10分钟，建议为相关任务预留专注时间并减少不必要切换。"
        );
        assert_eq!(
            recap.suggestions[2].text,
            "终端记录5分钟，建议为相关任务设置明确的时间预算并在结束时复盘。"
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
                parse_provider_response(&provider_response(content), &prepared, RecapScope::Today,),
                Err(ServiceFailure::InvalidResponse)
            );
        }
    }

    #[test]
    #[ignore = "requires DEEPSEEK_API_KEY and makes a live request with synthetic aggregates"]
    fn live_deepseek_smoke_uses_only_synthetic_aggregate_rows() {
        let service = AiRecapService::new(Arc::new(FakeUsageSource::new(vec![
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
        ])));

        assert!(service.status().configured, "live smoke requires a key");

        for model in [DEFAULT_MODEL, PRO_MODEL] {
            let reply = service.generate(
                "week_to_date".to_owned(),
                "2026-08-24".to_owned(),
                "2026-08-24".to_owned(),
                model.to_owned(),
            );
            assert_eq!(
                reply.error.as_ref().map(|error| error.code.as_str()),
                None,
                "live provider returned a redacted failure for {model}: {:?}",
                reply.error
            );
            let recap = reply.recap.expect("live provider returned a recap");
            assert_eq!(recap.scope, "week_to_date");
            assert_eq!(recap.total_active_seconds, 9_900);
            assert_eq!(recap.application_count, 3);
            assert_eq!(recap.model, model);
            assert!(recap.summary.text.contains("本周截至今日"));
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
