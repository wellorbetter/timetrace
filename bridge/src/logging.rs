//! Process-wide structured file logging for the Flutter bridge.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use chrono::{SecondsFormat, Utc};
use fs2::FileExt;
use serde_json::Value;
use timetrace_plugin_api::{
    ContractError, ContributionId, CorrelationId, DiagnosticEvent, DiagnosticField,
    DiagnosticLevel, DiagnosticTarget, DurationMillis, ScalarValue, TimestampMillis,
    validate_safe_token,
};
use timetrace_plugin_host::{CanonicalDiagnosticSink, DiagnosticEmitOutcome};
use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_appender::non_blocking::{ErrorCounter, NonBlocking, NonBlockingBuilder, WorkerGuard};
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::{EnvFilter, Registry};

const LOG_DIRECTORY_NAME: &str = "logs";
const LOG_FILE_PREFIX: &str = "timetrace";
const LOG_FILE_SUFFIX: &str = "jsonl";
const LOG_LOCK_FILE_NAME: &str = ".timetrace-logging.lock";
const LOG_FILTER_ENV: &str = "TIMETRACE_LOG";
const DEFAULT_LOG_FILTER: &str = "warn,timetrace=info,timetrace_core=info,timetrace_bridge=info";
const MAX_LOG_FILES: usize = 6;
const BUFFERED_LINES_LIMIT: usize = 256;
const MAX_TRACING_RECORD_BYTES: usize = 768;
const MAX_CANONICAL_RECORD_BYTES: usize = 4_096;
const MAX_SAFE_TEXT_BYTES: usize = 128;
const MAX_LOG_DIRECTORY_BYTES: u64 = 25 * 1_024 * 1_024;
const STARTUP_LOG_TARGET_BYTES: u64 = 24 * 1_024 * 1_024;
const MAX_LOG_DIRECTORY_ENTRIES: usize = 1_024;

static LOGGING: OnceLock<LoggingState> = OnceLock::new();
static UI_CORRELATION_SEQUENCE: AtomicU64 = AtomicU64::new(1);

enum LoggingState {
    Active(LoggingRuntime),
    Disabled,
}

struct LoggingRuntime {
    _lock_file: File,
    writer: NonBlocking,
    accepting: Arc<AtomicBool>,
    guard: Mutex<Option<WorkerGuard>>,
    queue_dropped: ErrorCounter,
    oversized_dropped: Arc<AtomicU64>,
    budget_dropped: Arc<AtomicU64>,
}

impl LoggingRuntime {
    fn shutdown(&self) {
        self.accepting.store(false, Ordering::Release);
        let guard = match self.guard.lock() {
            Ok(mut guard) => guard.take(),
            Err(poisoned) => poisoned.into_inner().take(),
        };
        let Some(guard) = guard else {
            return;
        };

        // Dropping the guard drains the bounded queue and joins the writer.
        drop(guard);

        let queue_dropped = self.queue_dropped.dropped_lines();
        let oversized_dropped = self.oversized_dropped.load(Ordering::Relaxed);
        let budget_dropped = self.budget_dropped.load(Ordering::Relaxed);
        if queue_dropped > 0 || oversized_dropped > 0 || budget_dropped > 0 {
            eprintln!(
                "TimeTrace logging dropped queue={queue_dropped} oversized={oversized_dropped} budget={budget_dropped} record(s)"
            );
        }
    }
}

/// Initialize the process-wide JSON file subscriber once.
///
/// Initialization failures are reported to stderr and deliberately degrade to
/// disabled file logging so an unavailable log directory never blocks startup.
pub(crate) fn init() {
    let _ = LOGGING.get_or_init(|| match build_runtime() {
        Ok(runtime) => LoggingState::Active(runtime),
        Err(error) => {
            eprintln!("TimeTrace file logging disabled: {error}");
            LoggingState::Disabled
        }
    });
}

/// Flush pending log records and stop the writer once, if it was initialized.
pub(crate) fn shutdown() {
    if let Some(LoggingState::Active(runtime)) = LOGGING.get() {
        runtime.shutdown();
    }
}

/// Emit a bounded UI diagnostic using only canonical tokens and numeric data.
///
/// Invalid input is never echoed to the log. Instead, a stable rejection event
/// is emitted so diagnostics cannot be used to persist paths or free text.
pub(crate) fn emit_ui_diagnostic(
    level: &str,
    event_code: &str,
    error_code: Option<&str>,
    duration_ms: Option<u64>,
) {
    if let Ok(event) = build_ui_diagnostic(level, event_code, error_code, duration_ms) {
        let _ = RustFileDiagnosticSink {}.emit_canonical(event);
    }
}

/// Return the immutable enabled-level bit mask for bridge diagnostics.
///
/// Bits use canonical level order: trace=0, debug=1, info=2, warn=3, error=4.
pub(crate) fn ui_diagnostic_level_mask() -> u8 {
    let emitter = RustFileDiagnosticSink {};
    [
        DiagnosticLevel::Trace,
        DiagnosticLevel::Debug,
        DiagnosticLevel::Info,
        DiagnosticLevel::Warn,
        DiagnosticLevel::Error,
    ]
    .into_iter()
    .enumerate()
    .fold(0_u8, |mask, (index, level)| {
        if emitter.is_enabled(level, DiagnosticTarget::Bridge) {
            mask | (1_u8 << index)
        } else {
            mask
        }
    })
}

#[derive(Debug, Clone, Copy)]
struct RustFileDiagnosticSink {}

impl CanonicalDiagnosticSink for RustFileDiagnosticSink {
    fn is_enabled(&self, level: DiagnosticLevel, target: DiagnosticTarget) -> bool {
        let Some(LoggingState::Active(runtime)) = LOGGING.get() else {
            return false;
        };
        runtime.accepting.load(Ordering::Acquire) && target_level_enabled(level, target)
    }

    fn emit_canonical(&self, event: DiagnosticEvent) -> DiagnosticEmitOutcome {
        let Some(LoggingState::Active(runtime)) = LOGGING.get() else {
            return DiagnosticEmitOutcome::Unavailable;
        };
        if !runtime.accepting.load(Ordering::Acquire) {
            return DiagnosticEmitOutcome::ShuttingDown;
        }
        if !target_level_enabled(event.level, event.target) {
            return DiagnosticEmitOutcome::Filtered;
        }
        let mut writer = runtime.writer.clone();
        emit_canonical_to_writer(&mut writer, runtime.accepting.as_ref(), &event)
    }
}

fn target_level_enabled(level: DiagnosticLevel, target: DiagnosticTarget) -> bool {
    macro_rules! enabled_for_target {
        ($target:literal) => {
            match level {
                DiagnosticLevel::Trace => tracing::enabled!(target: $target, tracing::Level::TRACE),
                DiagnosticLevel::Debug => tracing::enabled!(target: $target, tracing::Level::DEBUG),
                DiagnosticLevel::Info => tracing::enabled!(target: $target, tracing::Level::INFO),
                DiagnosticLevel::Warn => tracing::enabled!(target: $target, tracing::Level::WARN),
                DiagnosticLevel::Error => tracing::enabled!(target: $target, tracing::Level::ERROR),
            }
        };
    }

    match target {
        DiagnosticTarget::Core => enabled_for_target!("timetrace_core"),
        DiagnosticTarget::Bridge => enabled_for_target!("timetrace_bridge"),
        DiagnosticTarget::PluginHost => enabled_for_target!("timetrace_plugin_host"),
        DiagnosticTarget::PluginServices => enabled_for_target!("timetrace_plugin_services"),
        DiagnosticTarget::Plugin => enabled_for_target!("timetrace_plugin"),
    }
}

fn emit_canonical_to_writer<W: Write>(
    writer: &mut W,
    accepting: &AtomicBool,
    event: &DiagnosticEvent,
) -> DiagnosticEmitOutcome {
    if !accepting.load(Ordering::Acquire) {
        return DiagnosticEmitOutcome::ShuttingDown;
    }
    if event.validate_basic().is_err() {
        return DiagnosticEmitOutcome::Rejected;
    }
    let Ok(mut line) = serde_json::to_vec(event) else {
        return DiagnosticEmitOutcome::Rejected;
    };
    if line.len().saturating_add(1) > MAX_CANONICAL_RECORD_BYTES {
        return DiagnosticEmitOutcome::Rejected;
    }
    line.push(b'\n');
    if !accepting.load(Ordering::Acquire) {
        return DiagnosticEmitOutcome::ShuttingDown;
    }
    match writer.write_all(&line) {
        Ok(()) => DiagnosticEmitOutcome::Accepted,
        Err(_) if !accepting.load(Ordering::Acquire) => DiagnosticEmitOutcome::ShuttingDown,
        Err(_) => DiagnosticEmitOutcome::Unavailable,
    }
}

fn build_ui_diagnostic(
    level: &str,
    event_code: &str,
    error_code: Option<&str>,
    duration_ms: Option<u64>,
) -> Result<DiagnosticEvent, ContractError> {
    let parsed_level = match level {
        "trace" => Some(DiagnosticLevel::Trace),
        "debug" => Some(DiagnosticLevel::Debug),
        "info" => Some(DiagnosticLevel::Info),
        "warn" => Some(DiagnosticLevel::Warn),
        "error" => Some(DiagnosticLevel::Error),
        _ => None,
    };
    let invalid_event = ContributionId::new(event_code.to_owned()).is_err();
    let invalid_error =
        error_code.is_some_and(|value| validate_safe_token("ui_error_code", value).is_err());
    let correlation_id = CorrelationId::new(format!(
        "ui-{}",
        UI_CORRELATION_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ))?;

    let (level, event_code, fields) = if parsed_level.is_none() || invalid_event || invalid_error {
        let reason = if parsed_level.is_none() {
            "invalid_level"
        } else if invalid_event {
            "invalid_event_code"
        } else {
            "invalid_error_code"
        };
        let mut fields = BTreeMap::new();
        fields.insert(
            DiagnosticField::ErrorCode,
            ScalarValue::String(reason.to_owned()),
        );
        fields.insert(
            DiagnosticField::Status,
            ScalarValue::String("rejected".to_owned()),
        );
        (
            DiagnosticLevel::Warn,
            "ui.diagnostic.rejected".to_owned(),
            fields,
        )
    } else {
        let mut fields = BTreeMap::new();
        if let Some(error_code) = error_code {
            fields.insert(
                DiagnosticField::ErrorCode,
                ScalarValue::String(error_code.to_owned()),
            );
        }
        (
            parsed_level.unwrap_or(DiagnosticLevel::Warn),
            event_code.to_owned(),
            fields,
        )
    };

    let event = DiagnosticEvent {
        timestamp: TimestampMillis(Utc::now().timestamp_millis()),
        level,
        target: DiagnosticTarget::Bridge,
        event_code,
        plugin_id: None,
        correlation_id,
        duration: duration_ms.map(DurationMillis),
        fields,
    };
    event.validate_basic()?;
    Ok(event)
}

fn build_runtime() -> Result<LoggingRuntime, String> {
    let log_directory = log_directory()?;
    std::fs::create_dir_all(&log_directory).map_err(|error| {
        format!(
            "failed to create log directory {}: {error}",
            log_directory.display()
        )
    })?;

    // Acquire the process-wide ownership boundary before inspecting, deleting,
    // or opening any managed log. A second process degrades to disabled file
    // logging without touching the active process's files.
    let lock_file = acquire_log_lock(&log_directory)?;
    let existing_bytes = cleanup_log_directory(&log_directory)?;
    let process_budget = MAX_LOG_DIRECTORY_BYTES.saturating_sub(existing_bytes);

    let file_appender = RollingFileAppender::builder()
        .rotation(Rotation::DAILY)
        .filename_prefix(LOG_FILE_PREFIX)
        .filename_suffix(LOG_FILE_SUFFIX)
        .max_log_files(MAX_LOG_FILES)
        .build(&log_directory)
        .map_err(|error| format!("failed to create rolling log writer: {error}"))?;

    let budget_dropped = Arc::new(AtomicU64::new(0));
    let budget_writer = BudgetWriter::new(file_appender, process_budget, budget_dropped.clone());
    let (writer, guard) = NonBlockingBuilder::default()
        .buffered_lines_limit(BUFFERED_LINES_LIMIT)
        .lossy(true)
        .thread_name("timetrace-log-writer")
        .finish(budget_writer);
    let queue_dropped = writer.error_counter();
    let oversized_dropped = Arc::new(AtomicU64::new(0));
    let accepting = Arc::new(AtomicBool::new(true));

    let subscriber = Registry::default()
        .with(log_filter())
        .with(SafeJsonLayer::new(
            writer.clone(),
            oversized_dropped.clone(),
            accepting.clone(),
        ));

    if let Err(error) = tracing::subscriber::set_global_default(subscriber) {
        // The worker was already started; dropping its guard prevents a leaked
        // thread when another component installed a global subscriber first.
        drop(guard);
        return Err(format!("failed to install tracing subscriber: {error}"));
    }

    Ok(LoggingRuntime {
        _lock_file: lock_file,
        writer,
        accepting,
        guard: Mutex::new(Some(guard)),
        queue_dropped,
        oversized_dropped,
        budget_dropped,
    })
}

fn acquire_log_lock(directory: &Path) -> Result<File, String> {
    let lock_path = directory.join(LOG_LOCK_FILE_NAME);
    let lock_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|error| format!("failed to open persistent logging lock: {error}"))?;
    FileExt::try_lock_exclusive(&lock_file)
        .map_err(|_| "persistent logging is owned by another process".to_owned())?;
    Ok(lock_file)
}

fn log_filter() -> EnvFilter {
    std::env::var(LOG_FILTER_ENV)
        .ok()
        .and_then(|value| EnvFilter::try_new(value).ok())
        .unwrap_or_else(|| EnvFilter::new(DEFAULT_LOG_FILTER))
}

fn log_directory() -> Result<PathBuf, String> {
    let config_directory = dirs::config_dir()
        .ok_or_else(|| "operating system configuration directory is unavailable".to_owned())?;
    Ok(config_directory.join("TimeTrace").join(LOG_DIRECTORY_NAME))
}

fn cleanup_log_directory(directory: &Path) -> Result<u64, String> {
    let entries = std::fs::read_dir(directory).map_err(|error| {
        format!(
            "failed to inspect log directory {}: {error}",
            directory.display()
        )
    })?;
    let mut files = Vec::new();
    let mut total_bytes = 0_u64;
    let mut scanned_entries = 0_usize;

    for entry in entries {
        scanned_entries = scanned_entries.saturating_add(1);
        if scanned_entries > MAX_LOG_DIRECTORY_ENTRIES {
            return Err("log directory entry limit exceeded".to_owned());
        }
        let entry = entry.map_err(|error| format!("failed to inspect log entry: {error}"))?;
        if !is_managed_log_file_name(&entry.file_name()) {
            continue;
        }
        let metadata = entry
            .metadata()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;
        if !metadata.is_file() {
            continue;
        }
        let size = metadata.len();
        total_bytes = total_bytes.saturating_add(size);
        files.push((
            entry.path(),
            size,
            metadata.modified().unwrap_or(UNIX_EPOCH),
        ));
    }

    files.sort_by(|left, right| left.2.cmp(&right.2).then_with(|| left.0.cmp(&right.0)));
    for (path, size, _) in files {
        if total_bytes <= STARTUP_LOG_TARGET_BYTES {
            break;
        }
        std::fs::remove_file(&path)
            .map_err(|error| format!("failed to remove old log {}: {error}", path.display()))?;
        total_bytes = total_bytes.saturating_sub(size);
    }

    Ok(total_bytes)
}

fn is_managed_log_file_name(name: &std::ffi::OsStr) -> bool {
    let Some(name) = name.to_str() else {
        return false;
    };
    name.starts_with(LOG_FILE_PREFIX) && name.ends_with(".jsonl")
}

struct BudgetWriter<W> {
    inner: W,
    remaining_bytes: u64,
    dropped: Arc<AtomicU64>,
}

impl<W> BudgetWriter<W> {
    fn new(inner: W, remaining_bytes: u64, dropped: Arc<AtomicU64>) -> Self {
        Self {
            inner,
            remaining_bytes,
            dropped,
        }
    }
}

impl<W: Write> Write for BudgetWriter<W> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let buffer_bytes = u64::try_from(buffer.len()).unwrap_or(u64::MAX);
        if buffer.len() > MAX_CANONICAL_RECORD_BYTES || buffer_bytes > self.remaining_bytes {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return Ok(buffer.len());
        }

        let written = self.inner.write(buffer)?;
        self.remaining_bytes = self
            .remaining_bytes
            .saturating_sub(u64::try_from(written).unwrap_or(u64::MAX));
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

struct SafeJsonLayer<W> {
    writer: W,
    oversized_dropped: Arc<AtomicU64>,
    accepting: Arc<AtomicBool>,
}

impl<W> SafeJsonLayer<W> {
    fn new(writer: W, oversized_dropped: Arc<AtomicU64>, accepting: Arc<AtomicBool>) -> Self {
        Self {
            writer,
            oversized_dropped,
            accepting,
        }
    }
}

impl<S, W> Layer<S> for SafeJsonLayer<W>
where
    S: Subscriber + for<'lookup> LookupSpan<'lookup>,
    W: for<'writer> tracing_subscriber::fmt::MakeWriter<'writer> + 'static,
{
    fn on_event(&self, event: &Event<'_>, _context: Context<'_, S>) {
        if !self.accepting.load(Ordering::Acquire) {
            return;
        }
        let mut fields = SafeFieldVisitor::default();
        event.record(&mut fields);

        let metadata = event.metadata();
        let mut record = BTreeMap::new();
        record.insert(
            "timestamp",
            Value::String(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)),
        );
        record.insert("level", Value::String(metadata.level().to_string()));
        record.insert(
            "target",
            Value::String(truncate_utf8(metadata.target(), MAX_SAFE_TEXT_BYTES)),
        );
        record.append(&mut fields.values);

        let Ok(mut line) = serde_json::to_string(&record) else {
            self.oversized_dropped.fetch_add(1, Ordering::Relaxed);
            return;
        };
        if line.len().saturating_add(1) > MAX_TRACING_RECORD_BYTES {
            self.oversized_dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        line.push('\n');

        let mut writer = self.writer.make_writer_for(metadata);
        if writer.write_all(line.as_bytes()).is_err() {
            // The non-blocking writer owns its own error counter. Logging must
            // never retry or block the producer when its destination fails.
        }
    }
}

#[derive(Default)]
struct SafeFieldVisitor {
    values: BTreeMap<&'static str, Value>,
}

impl Visit for SafeFieldVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if is_safe_text_field(field.name()) {
            if let Some(value) = canonical_token(value) {
                self.values
                    .insert(field.name(), Value::String(value.to_owned()));
            }
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        if is_safe_numeric_field(field.name()) {
            self.values.insert(field.name(), Value::from(value));
        }
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        if is_safe_numeric_field(field.name()) {
            self.values.insert(field.name(), Value::from(value));
        }
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        if is_safe_numeric_field(field.name()) {
            if let Some(number) = serde_json::Number::from_f64(value) {
                self.values.insert(field.name(), Value::Number(number));
            }
        }
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        if field.name() == "success" {
            self.values.insert(field.name(), Value::Bool(value));
        }
    }

    fn record_debug(&mut self, _field: &Field, _value: &dyn fmt::Debug) {
        // Debug values commonly contain paths, errors, or user content. They
        // are deliberately excluded even when their field name looks safe.
    }
}

fn is_safe_text_field(name: &str) -> bool {
    matches!(
        name,
        "event" | "error_code" | "status" | "operation" | "plugin_id" | "correlation_id"
    )
}

fn is_safe_numeric_field(name: &str) -> bool {
    matches!(
        name,
        "duration" | "duration_ms" | "rows" | "bytes" | "count" | "generation"
    )
}

fn truncate_utf8(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    value[..end].to_owned()
}

fn canonical_token(value: &str) -> Option<&str> {
    if value.is_empty() || value.len() > MAX_SAFE_TEXT_BYTES {
        return None;
    }

    let mut previous_was_separator = false;
    for (index, byte) in value.bytes().enumerate() {
        let is_separator = matches!(byte, b'-' | b'.' | b'_' | b':');
        let is_token_byte = byte.is_ascii_lowercase() || byte.is_ascii_digit() || is_separator;
        if !is_token_byte || (is_separator && (index == 0 || previous_was_separator)) {
            return None;
        }
        previous_was_separator = is_separator;
    }
    (!previous_was_separator).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Default)]
    struct SharedBuffer(Arc<Mutex<Vec<u8>>>);

    impl Write for SharedBuffer {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            match self.0.lock() {
                Ok(mut bytes) => bytes.write(buffer),
                Err(poisoned) => poisoned.into_inner().write(buffer),
            }
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'writer> tracing_subscriber::fmt::MakeWriter<'writer> for SharedBuffer {
        type Writer = Self;

        fn make_writer(&'writer self) -> Self::Writer {
            self.clone()
        }
    }

    #[test]
    fn structured_logging_excludes_sensitive_and_message_fields() {
        let output = SharedBuffer::default();
        let oversized = Arc::new(AtomicU64::new(0));
        let subscriber = Registry::default().with(SafeJsonLayer::new(
            output.clone(),
            oversized.clone(),
            Arc::new(AtomicBool::new(true)),
        ));

        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(
                event = "collector_tick",
                status = "ok",
                count = 3_u64,
                path = r"C:\Users\secret\time.db",
                error = "private error body",
                correlation_id = "private free text",
                "arbitrary private message"
            );
        });

        let bytes = match output.0.lock() {
            Ok(bytes) => bytes.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        };
        let line = String::from_utf8(bytes).expect("formatter emits UTF-8 JSON");
        let value: Value = serde_json::from_str(&line).expect("formatter emits valid JSON");
        assert_eq!(value["event"], "collector_tick");
        assert_eq!(value["status"], "ok");
        assert_eq!(value["count"], 3);
        assert!(value.get("message").is_none());
        assert!(value.get("path").is_none());
        assert!(value.get("error").is_none());
        assert!(value.get("correlation_id").is_none());
        assert!(!line.contains("secret"));
        assert!(!line.contains("private"));
        assert_eq!(oversized.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn oversized_records_are_dropped_before_persistence() {
        let dropped = Arc::new(AtomicU64::new(0));
        let mut writer = BudgetWriter::new(Vec::new(), MAX_LOG_DIRECTORY_BYTES, dropped.clone());
        let oversized = vec![b'x'; MAX_CANONICAL_RECORD_BYTES + 1];

        assert_eq!(
            writer
                .write(&oversized)
                .expect("drop is reported as written"),
            oversized.len()
        );
        assert!(writer.inner.is_empty());
        assert_eq!(dropped.load(Ordering::Relaxed), 1);

        let budget_dropped = Arc::new(AtomicU64::new(0));
        let mut budget_writer = BudgetWriter::new(Vec::new(), 3, budget_dropped.clone());
        assert_eq!(
            budget_writer
                .write(b"four")
                .expect("over-budget record is reported as written"),
            4
        );
        assert!(budget_writer.inner.is_empty());
        assert_eq!(budget_dropped.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn encoded_records_over_limit_are_dropped_before_queueing() {
        let output = SharedBuffer::default();
        let oversized = Arc::new(AtomicU64::new(0));
        let subscriber = Registry::default().with(SafeJsonLayer::new(
            output.clone(),
            oversized.clone(),
            Arc::new(AtomicBool::new(true)),
        ));
        let maximum_token = "a".repeat(MAX_SAFE_TEXT_BYTES);

        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(
                event = maximum_token.as_str(),
                error_code = maximum_token.as_str(),
                status = maximum_token.as_str(),
                operation = maximum_token.as_str(),
                plugin_id = maximum_token.as_str(),
                correlation_id = maximum_token.as_str()
            );
        });

        let is_empty = match output.0.lock() {
            Ok(bytes) => bytes.is_empty(),
            Err(poisoned) => poisoned.into_inner().is_empty(),
        };
        assert!(is_empty);
        assert_eq!(oversized.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn invalid_ui_diagnostic_tokens_are_never_persisted() {
        let event = build_ui_diagnostic(
            "info",
            r"C:\Users\private\time.db",
            Some("private error body"),
            Some(7),
        )
        .expect("host rejection event is valid");
        let line = serde_json::to_string(&event).expect("serialize rejection event");
        assert_eq!(event.event_code, "ui.diagnostic.rejected");
        assert_eq!(
            event.fields.get(&DiagnosticField::ErrorCode),
            Some(&ScalarValue::String("invalid_event_code".to_owned()))
        );
        assert_eq!(
            event.fields.get(&DiagnosticField::Status),
            Some(&ScalarValue::String("rejected".to_owned()))
        );
        assert!(!line.contains("Users"));
        assert!(!line.contains("private"));
    }

    #[test]
    fn ui_ingress_injects_canonical_attribution_and_unique_correlation() {
        let first = build_ui_diagnostic("error", "ui.operation.failed", Some("io_error"), Some(7))
            .expect("valid UI event");
        let second = build_ui_diagnostic("error", "ui.operation.failed", None, None)
            .expect("valid UI event");

        assert_eq!(first.level, DiagnosticLevel::Error);
        assert_eq!(first.target, DiagnosticTarget::Bridge);
        assert!(first.plugin_id.is_none());
        assert_eq!(first.duration, Some(DurationMillis(7)));
        assert_ne!(first.correlation_id, second.correlation_id);
        assert_eq!(
            first.fields.get(&DiagnosticField::ErrorCode),
            Some(&ScalarValue::String("io_error".to_owned()))
        );
    }

    #[test]
    fn canonical_event_is_written_once_with_complete_wire_fields() {
        let event = build_ui_diagnostic("info", "ui.operation.completed", None, Some(3))
            .expect("valid UI event");
        let accepting = AtomicBool::new(true);
        let mut output = Vec::new();

        assert_eq!(
            emit_canonical_to_writer(&mut output, &accepting, &event),
            DiagnosticEmitOutcome::Accepted
        );
        assert_eq!(output.iter().filter(|byte| **byte == b'\n').count(), 1);
        let value: Value = serde_json::from_slice(&output).expect("canonical JSON line");
        assert_eq!(value["target"], "bridge");
        assert_eq!(value["event_code"], "ui.operation.completed");
        assert!(value.get("timestamp").is_some());
        assert!(value.get("correlation_id").is_some());
        assert!(value.get("plugin_id").is_none());
    }

    #[test]
    fn canonical_line_and_queue_payload_budgets_are_bounded() {
        let mut event = build_ui_diagnostic("error", "ui.operation.failed", None, Some(u64::MAX))
            .expect("valid UI event");
        for (field, value) in [
            (
                DiagnosticField::Operation,
                ScalarValue::String("a".repeat(128)),
            ),
            (
                DiagnosticField::Status,
                ScalarValue::String("b".repeat(128)),
            ),
            (
                DiagnosticField::ErrorCode,
                ScalarValue::String("c".repeat(128)),
            ),
            (
                DiagnosticField::ProviderId,
                ScalarValue::String("d".repeat(128)),
            ),
            (DiagnosticField::State, ScalarValue::String("e".repeat(128))),
            (
                DiagnosticField::ReasonCode,
                ScalarValue::String("f".repeat(128)),
            ),
            (DiagnosticField::Rows, ScalarValue::Unsigned(u64::MAX)),
            (DiagnosticField::Bytes, ScalarValue::Unsigned(u64::MAX)),
            (DiagnosticField::Count, ScalarValue::Unsigned(u64::MAX)),
            (
                DiagnosticField::DroppedEvents,
                ScalarValue::Unsigned(u64::MAX),
            ),
            (DiagnosticField::Attempt, ScalarValue::Unsigned(u64::MAX)),
            (DiagnosticField::Generation, ScalarValue::Unsigned(u64::MAX)),
        ] {
            event
                .insert_field(field, value)
                .expect("bounded canonical field");
        }
        let encoded = serde_json::to_vec(&event).expect("serialize maximum fixture");
        assert!(encoded.len() + 1 <= MAX_CANONICAL_RECORD_BYTES);
        assert!(BUFFERED_LINES_LIMIT * MAX_CANONICAL_RECORD_BYTES <= 1_024 * 1_024);
    }

    #[test]
    fn canonical_filter_respects_static_subscriber_filter() {
        let subscriber = Registry::default().with(EnvFilter::new("warn"));
        tracing::subscriber::with_default(subscriber, || {
            assert!(!target_level_enabled(
                DiagnosticLevel::Info,
                DiagnosticTarget::Bridge
            ));
            assert!(target_level_enabled(
                DiagnosticLevel::Warn,
                DiagnosticTarget::Bridge
            ));
        });
    }

    #[test]
    fn canonical_writer_rejects_events_after_shutdown_begins() {
        let event = build_ui_diagnostic("warn", "ui.operation.degraded", None, None)
            .expect("valid UI event");
        let accepting = AtomicBool::new(false);
        let mut output = Vec::new();
        assert_eq!(
            emit_canonical_to_writer(&mut output, &accepting, &event),
            DiagnosticEmitOutcome::ShuttingDown
        );
        assert!(output.is_empty());
    }

    #[test]
    fn existing_oversized_logs_are_cleaned_to_startup_target() {
        let directory = tempfile::tempdir().expect("temporary log directory");
        let oversized_path = directory.path().join("timetrace.oversized.jsonl");
        let file = File::create(&oversized_path).expect("create oversized log");
        file.set_len(MAX_LOG_DIRECTORY_BYTES + 1)
            .expect("size oversized log");

        let remaining = cleanup_log_directory(directory.path()).expect("clean log directory");

        assert!(remaining <= STARTUP_LOG_TARGET_BYTES);
        assert!(!oversized_path.exists());
    }

    #[test]
    fn log_lock_is_exclusive_until_owner_is_dropped() {
        let directory = tempfile::tempdir().expect("temporary log directory");
        let first = acquire_log_lock(directory.path()).expect("first owner acquires lock");

        let second = acquire_log_lock(directory.path());
        assert_eq!(
            second.expect_err("second owner must be rejected"),
            "persistent logging is owned by another process"
        );

        drop(first);
        let third = acquire_log_lock(directory.path());
        assert!(third.is_ok());
    }

    #[test]
    fn directory_entry_limit_disables_cleanup_before_touching_logs() {
        let directory = tempfile::tempdir().expect("temporary log directory");
        for index in 0..=MAX_LOG_DIRECTORY_ENTRIES {
            let path = directory.path().join(format!("timetrace.{index}.jsonl"));
            File::create(path).expect("create managed log");
        }

        let result = cleanup_log_directory(directory.path());

        assert_eq!(
            result.expect_err("entry overflow must disable logging"),
            "log directory entry limit exceeded"
        );
        assert_eq!(
            std::fs::read_dir(directory.path())
                .expect("read temporary directory")
                .count(),
            MAX_LOG_DIRECTORY_ENTRIES + 1
        );
    }

    #[test]
    fn unrelated_files_are_not_counted_or_deleted() {
        let directory = tempfile::tempdir().expect("temporary log directory");
        let managed_path = directory.path().join("timetrace.current.jsonl");
        let unrelated_path = directory.path().join("other-component.log");
        let lock_path = directory.path().join(LOG_LOCK_FILE_NAME);
        File::create(&managed_path)
            .expect("create managed log")
            .set_len(17)
            .expect("size managed log");
        File::create(&unrelated_path)
            .expect("create unrelated log")
            .set_len(MAX_LOG_DIRECTORY_BYTES + 1)
            .expect("size unrelated log");
        File::create(&lock_path).expect("create lock file");

        let managed_bytes = cleanup_log_directory(directory.path()).expect("clean log directory");

        assert_eq!(managed_bytes, 17);
        assert!(managed_path.exists());
        assert_eq!(
            std::fs::metadata(&unrelated_path)
                .expect("unrelated file remains")
                .len(),
            MAX_LOG_DIRECTORY_BYTES + 1
        );
        assert!(lock_path.exists());
    }

    #[test]
    fn runtime_shutdown_is_idempotent_without_global_subscriber() {
        let directory = tempfile::tempdir().expect("temporary log directory");
        let (writer, guard) = NonBlockingBuilder::default()
            .buffered_lines_limit(4)
            .lossy(true)
            .finish(std::io::sink());
        let runtime = LoggingRuntime {
            _lock_file: acquire_log_lock(directory.path()).expect("acquire test logging lock"),
            writer: writer.clone(),
            accepting: Arc::new(AtomicBool::new(true)),
            guard: Mutex::new(Some(guard)),
            queue_dropped: writer.error_counter(),
            oversized_dropped: Arc::new(AtomicU64::new(0)),
            budget_dropped: Arc::new(AtomicU64::new(0)),
        };

        runtime.shutdown();
        runtime.shutdown();

        let has_guard = match runtime.guard.lock() {
            Ok(guard) => guard.is_some(),
            Err(poisoned) => poisoned.into_inner().is_some(),
        };
        assert!(!has_guard);
    }
}
