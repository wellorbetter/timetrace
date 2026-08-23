//! Host-side diagnostic emission ports and authenticated plugin ingress.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use timetrace_plugin_api::{
    ContractError, CorrelationId, DiagnosticEvent, DiagnosticLevel, DiagnosticTarget,
    PluginDiagnosticDraft, TimestampMillis,
};

use crate::AuthenticatedPluginSession;

static PLUGIN_CORRELATION_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Result of a best-effort structured diagnostic emission attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticEmitOutcome {
    /// The event was accepted by the bounded host sink.
    Accepted,
    /// The active host filter disabled this level and target.
    Filtered,
    /// Canonical validation or the persisted encoded-size limit rejected it.
    Rejected,
    /// The process-wide sink was unavailable.
    Unavailable,
    /// Shutdown has started and no new events are accepted.
    ShuttingDown,
}

/// Host-internal output port for fully attributed canonical diagnostic events.
///
/// This is an integration port for trusted host components such as the bridge
/// file sink. It must never be exposed as plugin ingress; plugins receive a
/// [`ScopedPluginDiagnosticEmitter`] that accepts only unattributed drafts.
/// Implementations are best-effort and must not block on persistent I/O.
pub trait CanonicalDiagnosticSink: Send + Sync {
    /// Returns whether an event would currently pass the host filter.
    fn is_enabled(&self, level: DiagnosticLevel, target: DiagnosticTarget) -> bool;

    /// Validates and emits one event whose attribution was created by the host.
    fn emit_canonical(&self, event: DiagnosticEvent) -> DiagnosticEmitOutcome;
}

/// Authenticated plugin diagnostic ingress scoped to one host session.
///
/// The session is borrowed so this ingress cannot be constructed from a wire
/// payload or outlive its host-owned authentication context. Every accepted
/// draft receives host-generated identity, target, timestamp, and correlation.
pub struct ScopedPluginDiagnosticEmitter<'session> {
    session: &'session AuthenticatedPluginSession,
    sink: &'session dyn CanonicalDiagnosticSink,
}

impl<'session> ScopedPluginDiagnosticEmitter<'session> {
    /// Creates plugin diagnostic ingress for a host-authenticated session.
    #[must_use]
    pub fn new(
        session: &'session AuthenticatedPluginSession,
        sink: &'session dyn CanonicalDiagnosticSink,
    ) -> Self {
        Self { session, sink }
    }

    /// Returns whether plugin diagnostics at `level` currently pass filtering.
    #[must_use]
    pub fn is_enabled(&self, level: DiagnosticLevel) -> bool {
        self.sink.is_enabled(level, DiagnosticTarget::Plugin)
    }

    /// Validates a plugin draft, injects trusted attribution, and emits it.
    pub fn emit(&self, draft: PluginDiagnosticDraft) -> DiagnosticEmitOutcome {
        if !self.is_enabled(draft.level) {
            return DiagnosticEmitOutcome::Filtered;
        }
        if draft.validate_basic().is_err() {
            return DiagnosticEmitOutcome::Rejected;
        }
        let Ok(event) = attributed_plugin_event(self.session, draft) else {
            return DiagnosticEmitOutcome::Rejected;
        };
        self.sink.emit_canonical(event)
    }
}

fn attributed_plugin_event(
    session: &AuthenticatedPluginSession,
    draft: PluginDiagnosticDraft,
) -> Result<DiagnosticEvent, ContractError> {
    let sequence = PLUGIN_CORRELATION_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let event = DiagnosticEvent {
        timestamp: current_timestamp(),
        level: draft.level,
        target: DiagnosticTarget::Plugin,
        event_code: draft.event_code,
        plugin_id: Some(session.plugin_id().clone()),
        correlation_id: CorrelationId::new(format!("plugin-{sequence}"))?,
        duration: draft.duration,
        fields: draft.fields,
    };
    event.validate_basic()?;
    Ok(event)
}

fn current_timestamp() -> TimestampMillis {
    let millis = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis(),
        Err(_) => 0,
    };
    let millis = i64::try_from(millis).unwrap_or(i64::MAX);
    TimestampMillis(millis)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    use semver::Version;
    use timetrace_plugin_api::{
        CURRENT_MANIFEST_SCHEMA_VERSION, HostApiRange, Platform, PluginId, PluginManifest,
        PublisherId, ScalarValue,
    };

    use super::*;
    use crate::{PermissionControlPlane, PluginCatalog};

    #[derive(Default)]
    struct RecordingSink {
        events: Mutex<Vec<DiagnosticEvent>>,
    }

    impl CanonicalDiagnosticSink for RecordingSink {
        fn is_enabled(&self, _level: DiagnosticLevel, _target: DiagnosticTarget) -> bool {
            true
        }

        fn emit_canonical(&self, event: DiagnosticEvent) -> DiagnosticEmitOutcome {
            match self.events.lock() {
                Ok(mut events) => events.push(event),
                Err(poisoned) => poisoned.into_inner().push(event),
            }
            DiagnosticEmitOutcome::Accepted
        }
    }

    fn authenticated_session() -> (PermissionControlPlane, AuthenticatedPluginSession, PluginId) {
        let plugin_id = PluginId::new("trusted-plugin").expect("valid plugin id");
        let manifest = PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: plugin_id.clone(),
            publisher: PublisherId::new("wellorbetter").expect("valid publisher"),
            display_name: "Trusted plugin".to_owned(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("valid range"),
            platforms: vec![Platform::WindowsX64],
            contributions: Vec::new(),
            requested_capabilities: Vec::new(),
        };
        let catalog = PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, [manifest])
            .expect("valid catalog");
        let control = PermissionControlPlane::from_catalog(&catalog);
        let session = control
            .open_session(&plugin_id)
            .expect("host opens authenticated session");
        (control, session, plugin_id)
    }

    #[test]
    fn scoped_ingress_injects_authenticated_attribution() {
        let (_control, session, plugin_id) = authenticated_session();
        let sink = RecordingSink::default();
        let ingress = ScopedPluginDiagnosticEmitter::new(&session, &sink);
        let outcome = ingress.emit(PluginDiagnosticDraft {
            level: DiagnosticLevel::Info,
            event_code: "plugin.operation.completed".to_owned(),
            duration: None,
            fields: BTreeMap::from([(
                timetrace_plugin_api::DiagnosticField::Status,
                ScalarValue::String("completed".to_owned()),
            )]),
        });

        assert_eq!(outcome, DiagnosticEmitOutcome::Accepted);
        let events = match sink.events.lock() {
            Ok(events) => events,
            Err(poisoned) => poisoned.into_inner(),
        };
        let event = events.first().expect("one event recorded");
        assert_eq!(event.plugin_id.as_ref(), Some(&plugin_id));
        assert_eq!(event.target, DiagnosticTarget::Plugin);
        assert!(event.timestamp.0 > 0);
        assert!(event.correlation_id.as_str().starts_with("plugin-"));
    }

    #[test]
    fn canonical_sink_is_not_the_plugin_draft_interface() {
        fn accepts_plugin_ingress(_ingress: &ScopedPluginDiagnosticEmitter<'_>) {}

        let (_control, session, _plugin_id) = authenticated_session();
        let sink = RecordingSink::default();
        accepts_plugin_ingress(&ScopedPluginDiagnosticEmitter::new(&session, &sink));
    }
}
