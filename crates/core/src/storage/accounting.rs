//! SQLite persistence for the canonical accounting ledger.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use rusqlite::{OptionalExtension, Transaction, TransactionBehavior, params};

use crate::contracts::accounting::{
    AccountingError, AccountingInterval, AccountingState, AccountingStore, AttributionIdentity,
    CanonicalBatch, CheckpointAck, CheckpointReason, LifecycleEvidence, ProducerCheckpointState,
    ProductionCheckpoint, ProductionCheckpointError, RecoveryPoint, UtcInterval,
};
use crate::engine::accounting::AccountingReducer;
use crate::storage::SqliteStore;

impl SqliteStore {
    #[cfg(test)]
    fn write_canonical_batch_internal(
        &self,
        batch: &CanonicalBatch,
        fail_after_intervals: bool,
    ) -> Result<(), AccountingError> {
        validate_batch(batch)?;
        let mut conn = self.lock();
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| AccountingError::Storage(error.to_string()))?;
        write_batch_tx(&tx, batch, fail_after_intervals)?;
        tx.commit()
            .map_err(|error| AccountingError::Storage(error.to_string()))
    }

    fn commit_production_checkpoint_internal(
        &self,
        checkpoint: &ProductionCheckpoint,
        fault: Option<CommitFault>,
    ) -> Result<CheckpointAck, ProductionCheckpointError> {
        let mut conn = self.lock();
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_checkpoint_error)?;
        // Revalidate the full public payload while holding the writer lock.
        // Staging is intentionally pure and its public value may have been
        // deserialized or mutated before it reaches this trust boundary.
        if checkpoint.source_identity.trim().is_empty() || checkpoint.source_revision < 0 {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "source identity/revision is invalid".to_owned(),
            ));
        }
        if checkpoint.boundary != checkpoint.batch.observed_through {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "boundary must equal batch observed_through".to_owned(),
            ));
        }
        validate_batch(&checkpoint.batch)?;
        if checkpoint.content_hash != checkpoint.compute_content_hash() {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "content hash does not match checkpoint payload".to_owned(),
            ));
        }
        let metadata = read_producer_metadata(&tx)?;
        if let Some(existing) = metadata.as_ref().filter(|item| {
            item.last_source_identity.as_deref() == Some(checkpoint.source_identity.as_str())
                && item.last_source_revision == Some(checkpoint.source_revision)
        }) {
            if existing.last_content_hash.as_deref() == Some(checkpoint.content_hash.as_str()) {
                return Ok(existing.ack(true)?);
            }
            return Err(ProductionCheckpointError::ConflictingReplay {
                source_identity: checkpoint.source_identity.clone(),
                source_revision: checkpoint.source_revision,
            });
        }
        if let Some(existing) = metadata.as_ref().filter(|item| {
            item.last_source_identity.as_deref() == Some(checkpoint.source_identity.as_str())
                && item
                    .last_source_revision
                    .is_some_and(|revision| checkpoint.source_revision < revision)
        }) {
            return Err(ProductionCheckpointError::StaleRevision {
                source_identity: checkpoint.source_identity.clone(),
                incoming: checkpoint.source_revision,
                existing: existing.last_source_revision.expect("filtered as Some"),
            });
        }
        let actual_from = metadata
            .as_ref()
            .map(|item| item.observed_through)
            .or(legacy_observed_through(&tx)?);
        if actual_from != checkpoint.expected_from {
            return Err(ProductionCheckpointError::StaleExpectedFrom {
                expected: checkpoint.expected_from,
                actual: actual_from,
            });
        }
        if let Some(durable) = actual_from {
            if checkpoint.boundary < durable
                || (checkpoint.boundary == durable && !checkpoint.first_cutover)
            {
                return Err(ProductionCheckpointError::InvalidCheckpoint(format!(
                    "non-replay checkpoint boundary {} must advance durable watermark {}",
                    checkpoint.boundary, durable
                )));
            }
        }
        let canonical_mode = metadata.as_ref().and_then(|item| item.cutover_at).is_some();
        if checkpoint.first_cutover == canonical_mode
            || checkpoint.first_cutover != (checkpoint.reason == CheckpointReason::FirstCutover)
        {
            return Err(ProductionCheckpointError::ModeConflict(
                "checkpoint mode does not match durable cutover state".to_owned(),
            ));
        }
        let cutover_at = if checkpoint.first_cutover {
            close_open_legacy_tx(&tx, checkpoint.boundary)?;
            inject_fault(fault, CommitFault::AfterLegacyClosure)?;
            checkpoint.boundary
        } else {
            metadata
                .as_ref()
                .and_then(|item| item.cutover_at)
                .expect("canonical mode checked")
        };
        write_intervals_tx(&tx, &checkpoint.batch)?;
        inject_fault(fault, CommitFault::AfterIntervals)?;
        let placeholder = actual_from.unwrap_or(checkpoint.boundary);
        tx.execute(
            "INSERT INTO accounting_metadata (
                singleton_id, observed_through, cutover_at, lifecycle,
                last_source_identity, last_source_revision, last_content_hash
             ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(singleton_id) DO UPDATE SET
                cutover_at = excluded.cutover_at,
                lifecycle = excluded.lifecycle,
                last_source_identity = excluded.last_source_identity,
                last_source_revision = excluded.last_source_revision,
                last_content_hash = excluded.last_content_hash",
            params![
                placeholder.to_rfc3339(),
                cutover_at.to_rfc3339(),
                checkpoint.reason.as_str(),
                checkpoint.source_identity,
                checkpoint.source_revision,
                checkpoint.content_hash,
            ],
        )
        .map_err(storage_checkpoint_error)?;
        inject_fault(fault, CommitFault::AfterMetadataIdentity)?;
        inject_fault(fault, CommitFault::BeforeObservedThrough)?;
        tx.execute(
            "UPDATE accounting_metadata SET observed_through = ?1 WHERE singleton_id = 1",
            params![checkpoint.boundary.to_rfc3339()],
        )
        .map_err(storage_checkpoint_error)?;
        tx.commit().map_err(storage_checkpoint_error)?;
        Ok(CheckpointAck {
            durable_observed_through: checkpoint.boundary,
            cutover_at,
            lifecycle: checkpoint.reason,
            source_identity: checkpoint.source_identity.clone(),
            source_revision: checkpoint.source_revision,
            content_hash: checkpoint.content_hash.clone(),
            replayed: false,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommitFault {
    AfterLegacyClosure,
    AfterIntervals,
    AfterMetadataIdentity,
    BeforeObservedThrough,
}

fn inject_fault(
    actual: Option<CommitFault>,
    point: CommitFault,
) -> Result<(), ProductionCheckpointError> {
    if actual == Some(point) {
        return Err(ProductionCheckpointError::Accounting(
            AccountingError::Storage(format!(
                "injected production checkpoint failure at {point:?}"
            )),
        ));
    }
    Ok(())
}

impl AccountingStore for SqliteStore {
    fn load_producer_checkpoint_state(
        &self,
    ) -> Result<ProducerCheckpointState, ProductionCheckpointError> {
        let conn = self.lock();
        load_producer_state(&conn)
    }

    fn commit_production_checkpoint(
        &self,
        checkpoint: &ProductionCheckpoint,
    ) -> Result<CheckpointAck, ProductionCheckpointError> {
        self.commit_production_checkpoint_internal(checkpoint, None)
    }

    fn write_canonical_batch(&self, batch: &CanonicalBatch) -> Result<(), AccountingError> {
        let state = self
            .load_producer_checkpoint_state()
            .map_err(checkpoint_to_accounting)?;
        let first_cutover = matches!(state, ProducerCheckpointState::LegacyPreCutover { .. });
        if !first_cutover && state.observed_through() == Some(batch.observed_through) {
            validate_batch(batch)?;
            let conn = self.lock();
            if canonical_batch_is_exact_replay(&conn, batch)? {
                // Compatibility-only read path for callers predating
                // ProductionCheckpoint. It performs no mutation; all new or
                // advancing writes still pass through the atomic commit seam.
                return Ok(());
            }
            return Err(AccountingError::Storage(format!(
                "invalid production checkpoint: non-replay checkpoint boundary {} must advance durable watermark {}",
                batch.observed_through, batch.observed_through
            )));
        }
        let mut sources: Vec<_> = batch
            .intervals
            .iter()
            .map(|item| format!("{}@{}", item.source_identity, item.source_revision))
            .collect();
        sources.sort();
        sources.dedup();
        let revision = batch
            .intervals
            .iter()
            .map(|item| item.source_revision)
            .max()
            .unwrap_or(0);
        let checkpoint = ProductionCheckpoint::staged(
            if first_cutover {
                CheckpointReason::FirstCutover
            } else {
                CheckpointReason::Heartbeat
            },
            batch.observed_through,
            state.observed_through(),
            format!(
                "compat:{}:{}",
                if first_cutover { "first" } else { "current" },
                sources.join("|")
            ),
            revision,
            batch.clone(),
            first_cutover,
        )
        .map_err(checkpoint_to_accounting)?;
        self.commit_production_checkpoint(&checkpoint)
            .map(|_| ())
            .map_err(checkpoint_to_accounting)
    }

    fn load_accounting_intervals(
        &self,
        range: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        let conn = self.lock();
        let mut canonical = load_canonical(&conn, range)?;
        let durable = read_watermark(&conn)?
            .or(legacy_observed_through(&conn)?)
            .unwrap_or(range.start)
            .min(range.end);
        let cutover = read_producer_metadata(&conn)
            .ok()
            .flatten()
            .and_then(|metadata| metadata.cutover_at);
        let legacy_range = UtcInterval {
            start: range.start,
            end: durable.min(cutover.unwrap_or(durable)).max(range.start),
        };
        if legacy_range.start < legacy_range.end {
            let legacy = load_legacy(&conn, &legacy_range)?;
            for legacy_interval in legacy {
                for uncovered in subtract_covered(&legacy_interval.range, &canonical) {
                    canonical.push(AccountingInterval {
                        range: uncovered,
                        ..legacy_interval.clone()
                    });
                }
            }
        }
        canonical.sort_by_key(|item| item.range.start);
        Ok(canonical)
    }

    fn durable_observed_through(&self) -> Result<Option<DateTime<Utc>>, AccountingError> {
        let conn = self.lock();
        Ok(read_watermark(&conn)?.or(legacy_observed_through(&conn)?))
    }

    fn last_known_observed_through(&self) -> Option<DateTime<Utc>> {
        let conn = self.lock();
        read_watermark(&conn)
            .ok()
            .flatten()
            .or_else(|| legacy_observed_through(&conn).ok().flatten())
    }

    fn refresh_current(
        &self,
        _as_of: DateTime<Utc>,
    ) -> Result<Option<DateTime<Utc>>, AccountingError> {
        // The monitor owns the open-session checkpoint transaction. The store
        // seam exposes its latest committed receipt without extending it to
        // wall clock; alternate implementations can checkpoint before return.
        self.durable_observed_through()
    }

    fn recover_after_restart(&self, point: &RecoveryPoint) -> Result<(), AccountingError> {
        let durable = self
            .durable_observed_through()?
            .unwrap_or(point.restart_at.min(point.first_successful_observation));
        if point.first_successful_observation <= durable {
            return Ok(());
        }
        let recovery_range = UtcInterval::new(durable, point.first_successful_observation)?;
        let mut candidates = vec![AccountingInterval {
            range: recovery_range.clone(),
            state: AccountingState::Unknown,
            attribution: AttributionIdentity::default(),
            source_identity: point.source_identity.clone(),
            source_revision: point.source_revision,
        }];
        if let Some(LifecycleEvidence {
            interval,
            precise: true,
        }) = &point.lifecycle
        {
            if let Some(proven) = interval.intersection(&recovery_range) {
                candidates.push(AccountingInterval {
                    range: proven,
                    state: AccountingState::SystemGap,
                    attribution: AttributionIdentity::default(),
                    source_identity: point.source_identity.clone(),
                    source_revision: point.source_revision,
                });
            }
        }
        let intervals = AccountingReducer.reduce_intervals(&recovery_range, &candidates);
        let state = self
            .load_producer_checkpoint_state()
            .map_err(checkpoint_to_accounting)?;
        let first_cutover = matches!(state, ProducerCheckpointState::LegacyPreCutover { .. });
        let checkpoint = ProductionCheckpoint::staged(
            if first_cutover {
                CheckpointReason::FirstCutover
            } else {
                CheckpointReason::StartupRecovery
            },
            point.first_successful_observation,
            state.observed_through(),
            point.source_identity.clone(),
            point.source_revision,
            CanonicalBatch {
                intervals,
                observed_through: point.first_successful_observation,
            },
            first_cutover,
        )
        .map_err(checkpoint_to_accounting)?;
        self.commit_production_checkpoint(&checkpoint)
            .map(|_| ())
            .map_err(checkpoint_to_accounting)
    }
}

fn validate_batch(batch: &CanonicalBatch) -> Result<(), AccountingError> {
    let mut revisions: BTreeMap<&str, i64> = BTreeMap::new();
    for interval in &batch.intervals {
        if interval.source_identity.trim().is_empty() {
            return Err(AccountingError::Storage(
                "source_identity must not be empty".to_owned(),
            ));
        }
        if interval.source_revision < 0 {
            return Err(AccountingError::Storage(
                "source_revision must be non-negative".to_owned(),
            ));
        }
        if interval.range.start >= interval.range.end {
            return Err(AccountingError::InvalidRange {
                start: interval.range.start,
                end: interval.range.end,
            });
        }
        if interval.range.end > batch.observed_through {
            return Err(AccountingError::Storage(
                "interval extends past observed_through".to_owned(),
            ));
        }
        match revisions.get(interval.source_identity.as_str()) {
            Some(existing) if *existing != interval.source_revision => {
                return Err(AccountingError::Storage(format!(
                    "mixed revisions for source {}",
                    interval.source_identity
                )));
            }
            _ => {
                revisions.insert(interval.source_identity.as_str(), interval.source_revision);
            }
        }
    }
    Ok(())
}

fn canonical_batch_is_exact_replay(
    conn: &rusqlite::Connection,
    batch: &CanonicalBatch,
) -> Result<bool, AccountingError> {
    if batch.intervals.is_empty() {
        return Ok(false);
    }
    let mut by_source: BTreeMap<&str, Vec<&AccountingInterval>> = BTreeMap::new();
    for interval in &batch.intervals {
        by_source
            .entry(interval.source_identity.as_str())
            .or_default()
            .push(interval);
    }
    for (source, intervals) in by_source {
        let stored_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM accounting_intervals WHERE source_identity = ?1",
                params![source],
                |row| row.get(0),
            )
            .map_err(|error| AccountingError::Storage(error.to_string()))?;
        if stored_count != intervals.len() as i64 {
            return Ok(false);
        }
        for item in intervals {
            let matches: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM accounting_intervals
                     WHERE source_identity = ?1 AND source_revision = ?2
                       AND started_at = ?3 AND ended_at = ?4 AND state = ?5
                       AND app_id IS ?6 AND window_id IS ?7 AND window_app_id IS ?8
                       AND page_id IS ?9 AND page_window_id IS ?10",
                    params![
                        item.source_identity,
                        item.source_revision,
                        item.range.start.to_rfc3339(),
                        item.range.end.to_rfc3339(),
                        state_name(item.state),
                        item.attribution.app_id,
                        item.attribution.window_id,
                        item.attribution.window_app_id,
                        item.attribution.page_id,
                        item.attribution.page_window_id,
                    ],
                    |row| row.get(0),
                )
                .map_err(|error| AccountingError::Storage(error.to_string()))?;
            if matches != 1 {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

#[cfg(test)]
fn write_batch_tx(
    tx: &Transaction<'_>,
    batch: &CanonicalBatch,
    fail_after_intervals: bool,
) -> Result<(), AccountingError> {
    write_intervals_tx(tx, batch)?;
    if fail_after_intervals {
        return Err(AccountingError::Storage(
            "injected failure after interval writes".to_owned(),
        ));
    }
    let old = read_watermark(tx)?;
    let next = old
        .map(|value| value.max(batch.observed_through))
        .unwrap_or(batch.observed_through);
    tx.execute(
        "INSERT INTO accounting_metadata(singleton_id, observed_through) VALUES(1, ?1)
         ON CONFLICT(singleton_id) DO UPDATE SET observed_through = excluded.observed_through",
        params![next.to_rfc3339()],
    )
    .map_err(|error| AccountingError::Storage(error.to_string()))?;
    Ok(())
}

fn write_intervals_tx(tx: &Transaction<'_>, batch: &CanonicalBatch) -> Result<(), AccountingError> {
    let incoming: BTreeMap<&str, i64> =
        batch
            .intervals
            .iter()
            .fold(BTreeMap::new(), |mut map, item| {
                map.entry(item.source_identity.as_str())
                    .and_modify(|revision| *revision = item.source_revision)
                    .or_insert(item.source_revision);
                map
            });
    for (source, revision) in &incoming {
        let existing: Option<i64> = tx
            .query_row(
                "SELECT MAX(source_revision) FROM accounting_intervals WHERE source_identity = ?1",
                params![source],
                |row| row.get(0),
            )
            .map_err(|error| AccountingError::Storage(error.to_string()))?;
        if existing.is_some_and(|existing| *revision < existing) {
            return Err(AccountingError::StaleRevision {
                source_identity: (*source).to_owned(),
                incoming: *revision,
                existing: existing.expect("checked as Some"),
            });
        }
    }
    for (source, revision) in &incoming {
        let existing: Option<i64> = tx
            .query_row(
                "SELECT MAX(source_revision) FROM accounting_intervals WHERE source_identity = ?1",
                params![source],
                |row| row.get(0),
            )
            .map_err(|error| AccountingError::Storage(error.to_string()))?;
        if existing.is_some_and(|existing| *revision > existing) {
            tx.execute(
                "DELETE FROM accounting_intervals WHERE source_identity = ?1",
                params![source],
            )
            .map_err(|error| AccountingError::Storage(error.to_string()))?;
        }
    }
    for item in &batch.intervals {
        tx.execute(
            "INSERT OR IGNORE INTO accounting_intervals (
                source_identity, source_revision, started_at, ended_at, state,
                app_id, window_id, window_app_id, page_id, page_window_id
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                item.source_identity,
                item.source_revision,
                item.range.start.to_rfc3339(),
                item.range.end.to_rfc3339(),
                state_name(item.state),
                item.attribution.app_id,
                item.attribution.window_id,
                item.attribution.window_app_id,
                item.attribution.page_id,
                item.attribution.page_window_id,
            ],
        )
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    }
    Ok(())
}

fn load_canonical(
    conn: &rusqlite::Connection,
    range: &UtcInterval,
) -> Result<Vec<AccountingInterval>, AccountingError> {
    let mut stmt = conn
        .prepare(
            "SELECT source_identity, source_revision, started_at, ended_at, state,
                    app_id, window_id, window_app_id, page_id, page_window_id
             FROM accounting_intervals
             WHERE started_at < ?2 AND ended_at > ?1
             ORDER BY started_at, id",
        )
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let rows = stmt
        .query_map(
            params![range.start.to_rfc3339(), range.end.to_rfc3339()],
            |row| {
                let start: String = row.get(2)?;
                let end: String = row.get(3)?;
                let state: String = row.get(4)?;
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    start,
                    end,
                    state,
                    AttributionIdentity {
                        app_id: row.get(5)?,
                        window_id: row.get(6)?,
                        window_app_id: row.get(7)?,
                        page_id: row.get(8)?,
                        page_window_id: row.get(9)?,
                    },
                ))
            },
        )
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let mut result = Vec::new();
    for row in rows {
        let (source_identity, source_revision, start, end, state, attribution) =
            row.map_err(|error| AccountingError::Storage(error.to_string()))?;
        let item = AccountingInterval {
            range: UtcInterval::new(parse_utc(&start)?, parse_utc(&end)?)?,
            state: parse_state(&state)?,
            attribution,
            source_identity,
            source_revision,
        };
        if let Some(clipped) = item.range.intersection(range) {
            result.push(AccountingInterval {
                range: clipped,
                ..item
            });
        }
    }
    Ok(result)
}

fn load_legacy(
    conn: &rusqlite::Connection,
    range: &UtcInterval,
) -> Result<Vec<AccountingInterval>, AccountingError> {
    let mut stmt = conn
        .prepare(
            "SELECT id, app_name, window_title, started_at, ended_at, duration_secs, is_idle
             FROM usage_sessions
             WHERE COALESCE(duration_secs, 0) > 0
             ORDER BY started_at, id",
        )
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i32>(6)? != 0,
            ))
        })
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let mut result = Vec::new();
    for row in rows {
        let (id, app, title, started, ended, duration, idle) =
            row.map_err(|error| AccountingError::Storage(error.to_string()))?;
        let started = parse_utc(&started)?;
        let computed_end = started + chrono::Duration::seconds(duration.max(0));
        let ended = ended
            .as_deref()
            .map(parse_utc)
            .transpose()?
            .unwrap_or(computed_end)
            .min(computed_end)
            .min(range.end);
        if started >= ended {
            continue;
        }
        let full = UtcInterval {
            start: started,
            end: ended,
        };
        if let Some(clipped) = full.intersection(range) {
            result.push(AccountingInterval {
                range: clipped,
                state: if idle || app == "__IDLE__" {
                    AccountingState::Idle
                } else {
                    AccountingState::Active
                },
                attribution: if idle || app == "__IDLE__" {
                    AttributionIdentity::default()
                } else {
                    AttributionIdentity {
                        app_id: Some(app.clone()),
                        window_id: title.clone(),
                        window_app_id: title.as_ref().map(|_| app.clone()),
                        page_id: title.clone(),
                        page_window_id: title,
                    }
                },
                source_identity: format!("legacy:usage_session:{id}"),
                source_revision: 0,
            });
        }
    }
    Ok(result)
}

fn subtract_covered(range: &UtcInterval, canonical: &[AccountingInterval]) -> Vec<UtcInterval> {
    let mut fragments = vec![range.clone()];
    for cover in canonical {
        let mut next = Vec::new();
        for fragment in fragments {
            if cover.range.end <= fragment.start || cover.range.start >= fragment.end {
                next.push(fragment);
                continue;
            }
            if fragment.start < cover.range.start {
                next.push(UtcInterval {
                    start: fragment.start,
                    end: cover.range.start.min(fragment.end),
                });
            }
            if fragment.end > cover.range.end {
                next.push(UtcInterval {
                    start: cover.range.end.max(fragment.start),
                    end: fragment.end,
                });
            }
        }
        fragments = next;
    }
    fragments
}

#[derive(Debug, Clone)]
struct ProducerMetadata {
    observed_through: DateTime<Utc>,
    cutover_at: Option<DateTime<Utc>>,
    lifecycle: Option<CheckpointReason>,
    last_source_identity: Option<String>,
    last_source_revision: Option<i64>,
    last_content_hash: Option<String>,
}

impl ProducerMetadata {
    fn ack(&self, replayed: bool) -> Result<CheckpointAck, ProductionCheckpointError> {
        Ok(CheckpointAck {
            durable_observed_through: self.observed_through,
            cutover_at: self.cutover_at.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "replay metadata has no cutover boundary".to_owned(),
                )
            })?,
            lifecycle: self.lifecycle.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "replay metadata has no lifecycle".to_owned(),
                )
            })?,
            source_identity: self.last_source_identity.clone().ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "replay metadata has no source identity".to_owned(),
                )
            })?,
            source_revision: self.last_source_revision.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "replay metadata has no source revision".to_owned(),
                )
            })?,
            content_hash: self.last_content_hash.clone().ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "replay metadata has no content hash".to_owned(),
                )
            })?,
            replayed,
        })
    }
}

fn load_producer_state(
    conn: &rusqlite::Connection,
) -> Result<ProducerCheckpointState, ProductionCheckpointError> {
    let metadata = read_producer_metadata(conn)?;
    if let Some(metadata) = metadata.filter(|item| item.cutover_at.is_some()) {
        return Ok(ProducerCheckpointState::CanonicalCurrent {
            cutover_at: metadata.cutover_at.expect("filtered as Some"),
            observed_through: metadata.observed_through,
            lifecycle: metadata.lifecycle.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "canonical metadata has no lifecycle".to_owned(),
                )
            })?,
            last_source_identity: metadata.last_source_identity.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "canonical metadata has no source identity".to_owned(),
                )
            })?,
            last_source_revision: metadata.last_source_revision.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "canonical metadata has no source revision".to_owned(),
                )
            })?,
            last_content_hash: metadata.last_content_hash.ok_or_else(|| {
                ProductionCheckpointError::ModeConflict(
                    "canonical metadata has no content hash".to_owned(),
                )
            })?,
        });
    }
    Ok(ProducerCheckpointState::LegacyPreCutover {
        legacy_observed_through: read_watermark(conn)?.or(legacy_observed_through(conn)?),
    })
}

fn read_producer_metadata(
    conn: &rusqlite::Connection,
) -> Result<Option<ProducerMetadata>, ProductionCheckpointError> {
    let raw: Option<(
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
    )> = conn
        .query_row(
            "SELECT observed_through, cutover_at, lifecycle, last_source_identity,
                    last_source_revision, last_content_hash
             FROM accounting_metadata WHERE singleton_id = 1",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .optional()
        .map_err(storage_checkpoint_error)?;
    raw.map(|(observed, cutover, lifecycle, identity, revision, hash)| {
        Ok(ProducerMetadata {
            observed_through: parse_utc(&observed)?,
            cutover_at: cutover.as_deref().map(parse_utc).transpose()?,
            lifecycle: lifecycle
                .as_deref()
                .map(parse_checkpoint_reason)
                .transpose()?,
            last_source_identity: identity,
            last_source_revision: revision,
            last_content_hash: hash,
        })
    })
    .transpose()
}

fn close_open_legacy_tx(
    tx: &Transaction<'_>,
    boundary: DateTime<Utc>,
) -> Result<(), ProductionCheckpointError> {
    for (table, id_column) in [("usage_sessions", "id"), ("page_visits", "id")] {
        let sql = format!(
            "SELECT {id_column}, started_at, duration_secs FROM {table} WHERE ended_at IS NULL"
        );
        let mut stmt = tx.prepare(&sql).map_err(storage_checkpoint_error)?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            })
            .map_err(storage_checkpoint_error)?;
        let mut open = Vec::new();
        for row in rows {
            open.push(row.map_err(storage_checkpoint_error)?);
        }
        drop(stmt);
        for (id, started, persisted_duration) in open {
            let started = parse_utc(&started)?;
            // Recovery must never extend a legacy open row past its last
            // durable checkpoint. A brand-new row without a checkpoint can
            // close at the cutover boundary because the staged canonical
            // observations cover that same trusted range.
            let trusted_end = if started >= boundary {
                started
            } else {
                persisted_duration
                    .map(|seconds| started + chrono::Duration::seconds(seconds.max(0)))
                    // A NULL duration is an uncheckpointed, potentially stale
                    // crash row. Without a runtime row identity/coverage proof
                    // it contributes no trusted active tail at cutover.
                    .unwrap_or(started)
                    .min(boundary)
            };
            let update = format!(
                "UPDATE {table} SET ended_at = ?1, duration_secs = ?2
                 WHERE {id_column} = ?3 AND ended_at IS NULL"
            );
            tx.execute(
                &update,
                params![
                    trusted_end.to_rfc3339(),
                    (trusted_end - started).num_seconds(),
                    id
                ],
            )
            .map_err(storage_checkpoint_error)?;
        }
    }
    Ok(())
}

fn parse_checkpoint_reason(value: &str) -> Result<CheckpointReason, ProductionCheckpointError> {
    match value {
        "heartbeat" => Ok(CheckpointReason::Heartbeat),
        "current_read" => Ok(CheckpointReason::CurrentRead),
        "pause" => Ok(CheckpointReason::Pause),
        "resume" => Ok(CheckpointReason::Resume),
        "stop" => Ok(CheckpointReason::Stop),
        "startup_recovery" => Ok(CheckpointReason::StartupRecovery),
        "first_cutover" => Ok(CheckpointReason::FirstCutover),
        other => Err(ProductionCheckpointError::InvalidCheckpoint(format!(
            "unknown checkpoint lifecycle {other}"
        ))),
    }
}

fn storage_checkpoint_error(error: rusqlite::Error) -> ProductionCheckpointError {
    ProductionCheckpointError::Accounting(AccountingError::Storage(error.to_string()))
}

fn checkpoint_to_accounting(error: ProductionCheckpointError) -> AccountingError {
    match error {
        ProductionCheckpointError::Accounting(error) => error,
        other => AccountingError::Storage(other.to_string()),
    }
}

fn read_watermark(conn: &rusqlite::Connection) -> Result<Option<DateTime<Utc>>, AccountingError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT observed_through FROM accounting_metadata WHERE singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    raw.as_deref().map(parse_utc).transpose()
}

fn legacy_observed_through(
    conn: &rusqlite::Connection,
) -> Result<Option<DateTime<Utc>>, AccountingError> {
    let mut stmt = conn
        .prepare(
            "SELECT started_at, ended_at, duration_secs
             FROM usage_sessions WHERE COALESCE(duration_secs, 0) > 0",
        )
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .map_err(|error| AccountingError::Storage(error.to_string()))?;
    let mut latest = None;
    for row in rows {
        let (started, ended, duration) =
            row.map_err(|error| AccountingError::Storage(error.to_string()))?;
        let started = parse_utc(&started)?;
        let checkpoint_end = started + chrono::Duration::seconds(duration.max(0));
        let end = ended
            .as_deref()
            .map(parse_utc)
            .transpose()?
            .unwrap_or(checkpoint_end)
            .min(checkpoint_end);
        latest = Some(latest.map_or(end, |current: DateTime<Utc>| current.max(end)));
    }
    Ok(latest)
}

fn parse_utc(value: &str) -> Result<DateTime<Utc>, AccountingError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| AccountingError::Storage(error.to_string()))
}

fn state_name(state: AccountingState) -> &'static str {
    match state {
        AccountingState::Active => "active",
        AccountingState::Idle => "idle",
        AccountingState::Paused => "paused",
        AccountingState::PrivacyExcluded => "privacy_excluded",
        AccountingState::SystemGap => "system_gap",
        AccountingState::Unknown => "unknown",
    }
}

fn parse_state(value: &str) -> Result<AccountingState, AccountingError> {
    match value {
        "active" => Ok(AccountingState::Active),
        "idle" => Ok(AccountingState::Idle),
        "paused" => Ok(AccountingState::Paused),
        "privacy_excluded" => Ok(AccountingState::PrivacyExcluded),
        "system_gap" => Ok(AccountingState::SystemGap),
        "unknown" => Ok(AccountingState::Unknown),
        other => Err(AccountingError::Storage(format!(
            "unknown accounting state {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::storage::{DataStore, SessionRecord};
    use crate::engine::accounting::totals_for;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    fn store() -> SqliteStore {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "timetrace-ledger-{}-{n}.sqlite3",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        SqliteStore::open(path).unwrap()
    }

    fn at(minute: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 15, 10, 0, 0)
            .single()
            .unwrap()
            + chrono::Duration::minutes(i64::from(minute))
    }

    fn canonical(start: u32, end: u32, revision: i64) -> AccountingInterval {
        canonical_for("monitor:session:1", start, end, revision)
    }

    fn canonical_for(source: &str, start: u32, end: u32, revision: i64) -> AccountingInterval {
        AccountingInterval {
            range: UtcInterval::new(at(start), at(end)).unwrap(),
            state: AccountingState::Active,
            attribution: AttributionIdentity {
                app_id: Some("canonical-app".into()),
                ..AttributionIdentity::default()
            },
            source_identity: source.into(),
            source_revision: revision,
        }
    }

    fn checkpoint(
        state: &ProducerCheckpointState,
        reason: CheckpointReason,
        boundary: u32,
        source_revision: i64,
    ) -> ProductionCheckpoint {
        ProductionCheckpoint::staged(
            reason,
            at(boundary),
            state.observed_through(),
            "producer:runtime:1".into(),
            source_revision,
            CanonicalBatch {
                intervals: vec![canonical(0, boundary, source_revision)],
                observed_through: at(boundary),
            },
            reason == CheckpointReason::FirstCutover,
        )
        .unwrap()
    }

    #[test]
    fn replay_is_idempotent_and_canonical_precedes_legacy() {
        let store = store();
        let legacy = SessionRecord {
            id: 0,
            app_path: "c:/legacy.exe".into(),
            app_name: "legacy-app".into(),
            window_title: Some("legacy-window".into()),
            started_at: at(0),
            ended_at: Some(at(60)),
            duration_secs: Some(3600),
            is_idle: false,
            date: at(0).date_naive(),
        };
        store.insert_session(&legacy);
        let batch = CanonicalBatch {
            intervals: vec![canonical(0, 60, 1)],
            observed_through: at(60),
        };
        store.write_canonical_batch(&batch).unwrap();
        store.write_canonical_batch(&batch).unwrap();
        let range = UtcInterval::new(at(0), at(60)).unwrap();
        let rows = store.load_accounting_intervals(&range).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_identity, "monitor:session:1");
        assert_eq!(totals_for(&rows).active_seconds, 3600);
    }

    #[test]
    fn transaction_failure_after_interval_write_rolls_back_rows_and_watermark() {
        let store = store();
        store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![canonical(0, 10, 1)],
                observed_through: at(10),
            })
            .unwrap();
        let replacement = CanonicalBatch {
            intervals: vec![canonical(0, 20, 2)],
            observed_through: at(20),
        };
        assert!(
            store
                .write_canonical_batch_internal(&replacement, true)
                .is_err()
        );
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(10)));
        let rows = store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(20)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_revision, 1);
        assert_eq!(rows[0].range.end, at(10));

        // The failed transaction did not poison or partially consume the
        // revision. Retrying the exact replacement succeeds atomically.
        store.write_canonical_batch(&replacement).unwrap();
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(20)));
        let rows = store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(20)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_revision, 2);
        assert_eq!(rows[0].range.end, at(20));
    }

    #[test]
    fn revisions_are_monotonic_mixed_batches_rejected_and_newer_replaces() {
        let store = store();
        let revision2 = CanonicalBatch {
            intervals: vec![canonical(0, 20, 2)],
            observed_through: at(20),
        };
        store.write_canonical_batch(&revision2).unwrap();
        store.write_canonical_batch(&revision2).unwrap();

        let stale = CanonicalBatch {
            intervals: vec![canonical(0, 30, 1)],
            observed_through: at(30),
        };
        assert!(matches!(
            store.write_canonical_batch(&stale),
            Err(AccountingError::StaleRevision { .. })
        ));
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(20)));

        let mixed = CanonicalBatch {
            intervals: vec![canonical(0, 20, 2), canonical(20, 30, 3)],
            observed_through: at(30),
        };
        assert!(store.write_canonical_batch(&mixed).is_err());
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(20)));

        let revision3 = CanonicalBatch {
            intervals: vec![canonical(0, 30, 3)],
            observed_through: at(30),
        };
        store.write_canonical_batch(&revision3).unwrap();
        let rows = store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(30)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_revision, 3);
        assert_eq!(rows[0].range.end, at(30));
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(30)));
    }

    #[test]
    fn multi_source_batches_are_atomic_across_stale_replay_and_newer_sources() {
        let stale_store = store();
        stale_store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![canonical_for("source-a", 0, 20, 2)],
                observed_through: at(20),
            })
            .unwrap();
        let stale_plus_new = CanonicalBatch {
            intervals: vec![
                canonical_for("source-a", 0, 10, 1),
                canonical_for("source-b", 20, 30, 1),
            ],
            observed_through: at(30),
        };
        assert!(matches!(
            stale_store.write_canonical_batch(&stale_plus_new),
            Err(AccountingError::StaleRevision {
                source_identity,
                incoming: 1,
                existing: 2,
            }) if source_identity == "source-a"
        ));
        let rows = stale_store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(30)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_identity, "source-a");
        assert_eq!(rows[0].source_revision, 2);
        assert_eq!(
            stale_store.durable_observed_through().unwrap(),
            Some(at(20))
        );

        // Equal replay is idempotent while a new source in the same batch is
        // still committed; there is no early-return data loss.
        stale_store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![
                    canonical_for("source-a", 0, 20, 2),
                    canonical_for("source-b", 20, 30, 1),
                ],
                observed_through: at(30),
            })
            .unwrap();
        let rows = stale_store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(30)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| row.source_identity == "source-b"));
        assert_eq!(
            stale_store.durable_observed_through().unwrap(),
            Some(at(30))
        );

        let higher_store = store();
        higher_store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![canonical_for("source-a", 0, 20, 2)],
                observed_through: at(20),
            })
            .unwrap();
        higher_store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![
                    canonical_for("source-a", 0, 30, 3),
                    canonical_for("source-b", 30, 40, 1),
                ],
                observed_through: at(40),
            })
            .unwrap();
        let rows = higher_store
            .load_accounting_intervals(&UtcInterval::new(at(0), at(40)).unwrap())
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert!(
            rows.iter()
                .any(|row| { row.source_identity == "source-a" && row.source_revision == 3 })
        );
        assert!(
            rows.iter()
                .any(|row| { row.source_identity == "source-b" && row.source_revision == 1 })
        );
        assert_eq!(
            higher_store.durable_observed_through().unwrap(),
            Some(at(40))
        );

        let all_stale = CanonicalBatch {
            intervals: vec![canonical_for("source-a", 0, 10, 1)],
            observed_through: at(50),
        };
        assert!(matches!(
            higher_store.write_canonical_batch(&all_stale),
            Err(AccountingError::StaleRevision { .. })
        ));
        assert_eq!(
            higher_store.durable_observed_through().unwrap(),
            Some(at(40))
        );
    }

    #[test]
    fn crash_recovery_is_unknown_except_precise_lifecycle_evidence() {
        let store = store();
        store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![canonical(0, 10, 1)],
                observed_through: at(10),
            })
            .unwrap();
        let point = RecoveryPoint {
            restart_at: at(20),
            first_successful_observation: at(30),
            lifecycle: Some(LifecycleEvidence {
                interval: UtcInterval::new(at(15), at(20)).unwrap(),
                precise: true,
            }),
            source_identity: "recovery:boot:1".into(),
            source_revision: 1,
        };
        store.recover_after_restart(&point).unwrap();
        store.recover_after_restart(&point).unwrap();
        let range = UtcInterval::new(at(10), at(30)).unwrap();
        let rows = AccountingReducer
            .reduce_intervals(&range, &store.load_accounting_intervals(&range).unwrap());
        let totals = totals_for(&rows);
        assert_eq!(totals.system_gap_seconds, 300);
        assert_eq!(totals.unknown_seconds, 900);
        assert_eq!(totals.active_seconds, 0);
        assert_eq!(totals.accounted_seconds(), 1200);
    }

    #[test]
    fn production_checkpoint_faults_roll_back_cutover_and_retry_cleanly() {
        for fault in [
            CommitFault::AfterLegacyClosure,
            CommitFault::AfterIntervals,
            CommitFault::AfterMetadataIdentity,
            CommitFault::BeforeObservedThrough,
        ] {
            let store = store();
            store.insert_session(&SessionRecord {
                id: 0,
                app_path: "c:/legacy.exe".into(),
                app_name: "legacy-app".into(),
                window_title: Some("legacy-window".into()),
                started_at: at(0),
                ended_at: None,
                duration_secs: None,
                is_idle: false,
                date: at(0).date_naive(),
            });
            store.insert_session(&SessionRecord {
                id: 0,
                app_path: "c:/current.exe".into(),
                app_name: "current-app".into(),
                window_title: Some("durable".into()),
                started_at: at(5),
                ended_at: None,
                duration_secs: Some(300),
                is_idle: false,
                date: at(5).date_naive(),
            });
            let state = ProducerCheckpointState::load(&store).unwrap();
            assert_eq!(
                state,
                ProducerCheckpointState::LegacyPreCutover {
                    legacy_observed_through: Some(at(10))
                }
            );
            let staged = ProductionCheckpoint::staged(
                CheckpointReason::FirstCutover,
                at(10),
                state.observed_through(),
                "producer:runtime:1".into(),
                1,
                CanonicalBatch {
                    intervals: vec![canonical_for("monitor:current", 5, 10, 1)],
                    observed_through: at(10),
                },
                true,
            )
            .unwrap();

            assert!(
                store
                    .commit_production_checkpoint_internal(&staged, Some(fault))
                    .is_err()
            );
            assert_eq!(ProducerCheckpointState::load(&store).unwrap(), state);
            let before = store
                .load_accounting_intervals(&UtcInterval::new(at(0), at(10)).unwrap())
                .unwrap();
            assert_eq!(totals_for(&before).active_seconds, 300);
            let legacy = store.get_sessions_by_date(at(0).date_naive());
            assert_eq!(legacy.len(), 2);
            assert!(legacy.iter().all(|session| session.ended_at.is_none()));

            let ack = store.commit_production_checkpoint(&staged).unwrap();
            assert!(!ack.replayed);
            assert_eq!(ack.durable_observed_through, at(10));
            let replay = store.commit_production_checkpoint(&staged).unwrap();
            assert!(replay.replayed);
            assert_eq!(replay.durable_observed_through, at(10));
            let legacy = store.get_sessions_by_date(at(0).date_naive());
            let stale = legacy
                .iter()
                .find(|session| session.app_name == "legacy-app")
                .unwrap();
            assert_eq!(stale.ended_at, Some(at(0)));
            assert_eq!(stale.duration_secs, Some(0));
            let current = legacy
                .iter()
                .find(|session| session.app_name == "current-app")
                .unwrap();
            assert_eq!(current.ended_at, Some(at(10)));
            assert_eq!(current.duration_secs, Some(300));
        }
    }

    #[test]
    fn first_cutover_excludes_uncheckpointed_stale_open_tail() {
        let store = store();
        store.insert_session(&SessionRecord {
            id: 0,
            app_path: "c:/stale.exe".into(),
            app_name: "stale-app".into(),
            window_title: Some("crashed".into()),
            started_at: at(0),
            ended_at: None,
            duration_secs: None,
            is_idle: false,
            date: at(0).date_naive(),
        });
        store.insert_session(&SessionRecord {
            id: 0,
            app_path: "c:/current.exe".into(),
            app_name: "current-app".into(),
            window_title: Some("durable".into()),
            started_at: at(5),
            ended_at: None,
            duration_secs: Some(300),
            is_idle: false,
            date: at(5).date_naive(),
        });
        let state = ProducerCheckpointState::load(&store).unwrap();
        assert_eq!(state.observed_through(), Some(at(10)));
        let staged = ProductionCheckpoint::staged(
            CheckpointReason::FirstCutover,
            at(10),
            state.observed_through(),
            "producer:cutover".into(),
            1,
            CanonicalBatch {
                intervals: vec![canonical_for("monitor:current", 5, 10, 1)],
                observed_through: at(10),
            },
            true,
        )
        .unwrap();
        store.commit_production_checkpoint(&staged).unwrap();

        let sessions = store.get_sessions_by_date(at(0).date_naive());
        let stale = sessions
            .iter()
            .find(|session| session.app_name == "stale-app")
            .unwrap();
        assert_eq!(stale.ended_at, Some(at(0)));
        assert_eq!(stale.duration_secs, Some(0));
        let current = sessions
            .iter()
            .find(|session| session.app_name == "current-app")
            .unwrap();
        assert_eq!(current.ended_at, Some(at(10)));
        assert_eq!(current.duration_secs, Some(300));

        let range = UtcInterval::new(at(0), at(10)).unwrap();
        let reduced = AccountingReducer
            .reduce_intervals(&range, &store.load_accounting_intervals(&range).unwrap());
        let totals = totals_for(&reduced);
        assert_eq!(totals.active_seconds, 300);
        assert_eq!(totals.unknown_seconds, 300);
        assert_eq!(totals.accounted_seconds(), 600);
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(10)));
    }

    #[test]
    fn production_checkpoint_rejects_conflict_stale_revision_and_stale_watermark() {
        let store = store();
        let initial_state = ProducerCheckpointState::load(&store).unwrap();
        let initial = checkpoint(&initial_state, CheckpointReason::FirstCutover, 10, 1);
        store.commit_production_checkpoint(&initial).unwrap();

        let mut conflict = initial.clone();
        conflict.batch.intervals[0].attribution.app_id = Some("conflicting-app".into());
        conflict.content_hash = conflict.compute_content_hash();
        assert!(matches!(
            store.commit_production_checkpoint(&conflict),
            Err(ProductionCheckpointError::ConflictingReplay { .. })
        ));
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(10)));

        let current = ProducerCheckpointState::load(&store).unwrap();
        let newer = checkpoint(&current, CheckpointReason::Heartbeat, 20, 2);
        store.commit_production_checkpoint(&newer).unwrap();
        let stale = ProductionCheckpoint::staged(
            CheckpointReason::Heartbeat,
            at(30),
            ProducerCheckpointState::load(&store)
                .unwrap()
                .observed_through(),
            "producer:runtime:1".into(),
            1,
            CanonicalBatch {
                intervals: vec![canonical(0, 30, 1)],
                observed_through: at(30),
            },
            false,
        )
        .unwrap();
        assert!(matches!(
            store.commit_production_checkpoint(&stale),
            Err(ProductionCheckpointError::StaleRevision { .. })
        ));

        let mut stale_watermark = checkpoint(
            &ProducerCheckpointState::load(&store).unwrap(),
            CheckpointReason::Heartbeat,
            30,
            1,
        );
        stale_watermark.source_identity = "producer:other".into();
        stale_watermark.expected_from = Some(at(10));
        stale_watermark.content_hash = stale_watermark.compute_content_hash();
        assert!(matches!(
            store.commit_production_checkpoint(&stale_watermark),
            Err(ProductionCheckpointError::StaleExpectedFrom {
                expected: Some(expected),
                actual: Some(actual),
            }) if expected == at(10) && actual == at(20)
        ));
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(20)));
    }

    #[test]
    fn commit_revalidates_public_payload_and_rejects_watermark_regression() {
        let store = store();
        let initial_state = ProducerCheckpointState::load(&store).unwrap();
        let initial = checkpoint(&initial_state, CheckpointReason::FirstCutover, 10, 1);
        store.commit_production_checkpoint(&initial).unwrap();
        let current = ProducerCheckpointState::load(&store).unwrap();
        let advance = checkpoint(&current, CheckpointReason::Heartbeat, 20, 2);
        store.commit_production_checkpoint(&advance).unwrap();
        let before_state = ProducerCheckpointState::load(&store).unwrap();
        let range = UtcInterval::new(at(0), at(20)).unwrap();
        let before_rows = store.load_accounting_intervals(&range).unwrap();

        let mut changed_boundary = checkpoint(&before_state, CheckpointReason::Heartbeat, 30, 3);
        changed_boundary.boundary = at(29);
        changed_boundary.content_hash = changed_boundary.compute_content_hash();
        assert!(matches!(
            store.commit_production_checkpoint(&changed_boundary),
            Err(ProductionCheckpointError::InvalidCheckpoint(_))
        ));

        let mut changed_batch_boundary =
            checkpoint(&before_state, CheckpointReason::Heartbeat, 30, 3);
        changed_batch_boundary.batch.observed_through = at(29);
        changed_batch_boundary.content_hash = changed_batch_boundary.compute_content_hash();
        assert!(matches!(
            store.commit_production_checkpoint(&changed_batch_boundary),
            Err(ProductionCheckpointError::InvalidCheckpoint(_))
        ));

        let stale_compat = CanonicalBatch {
            intervals: vec![canonical_for("compat:stale", 0, 10, 1)],
            observed_through: at(10),
        };
        assert!(matches!(
            store.write_canonical_batch(&stale_compat),
            Err(AccountingError::Storage(message)) if message.contains("must advance durable watermark")
        ));

        assert_eq!(ProducerCheckpointState::load(&store).unwrap(), before_state);
        assert_eq!(store.durable_observed_through().unwrap(), Some(at(20)));
        assert_eq!(
            store.load_accounting_intervals(&range).unwrap(),
            before_rows
        );
    }
}
