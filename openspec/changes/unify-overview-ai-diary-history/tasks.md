# Tasks

> Implementation approved by the user and completed with engineering and product acceptance.

## 1. Approval and baseline

- [x] 1.1 Confirm AI generation trigger and duplicate-generation behavior.
- [x] 1.2 Confirm provenance transition after a user edit.
- [x] 1.3 Confirm day-only versus range AI generation.
- [x] 1.4 Capture the main-branch carousel baseline and approved Overview page order.

## 2. Diary provenance storage

- [x] 2.1 Add the SQLite migration for `source` and `source_model` without altering existing content or image links.
- [x] 2.2 Extend Rust storage contracts, SQLite implementation, bridge API, and DTOs.
- [x] 2.3 Add an atomic AI diary publication operation.
- [x] 2.4 Mark user edits of AI-generated entries as AI-assisted.
- [x] 2.5 Regenerate and verify flutter_rust_bridge bindings.

## 3. AI diary domain

- [x] 3.1 Replace the legacy recap output contract with a diary-content result.
- [x] 3.2 Rewrite the system/user prompts for factual first-person diary prose.
- [x] 3.2a Add locally persisted custom diary instructions, reflection/suggestion preferences, and restore-default behavior.
- [x] 3.3 Remove local recap fallback publication behavior.
- [x] 3.4 Implement trigger, loading, error, duplicate-confirmation, publish, and provider invalidation flows.
- [x] 3.4a Implement local-time scheduling, tray execution, same-day catch-up, completion deduplication, and retryable failures.
- [x] 3.5 Update terminology from Recap/AI 回顾 to AI 日记 in active user-facing code.

## 4. Overview workspace

- [x] 4.1 Restore the main-branch carousel composition and remove `DashboardSummaryStrip` from Overview.
- [x] 4.2 Preserve the original diary block below the calendar/carousel and add a compact AI writing action to it.
- [x] 4.3 Add the Usage History page key with preference migration.
- [x] 4.4 Keep every original main-branch carousel page enabled by default and configurable in Overview Layout settings.
- [x] 4.5 Preserve the manual diary, images, drafts, editing, publishing, and feed behavior while adding AI action/status and provenance.
- [x] 4.6 Implement the bounded lazy Usage History page and filter invalid zero-duration rows.
- [x] 4.7 Correct visible-order page targeting, app focus alignment, and long-name disclosure.
- [x] 4.8 Verify equal calendar/carousel height and narrow-window stacking.

## 5. Navigation and settings

- [x] 5.1 Remove the Recap sidebar destination, route, shortcut, and standalone report screen.
- [x] 5.2 Reassign remaining keyboard shortcuts consistently.
- [x] 5.2a Preserve the approved opaque warm-neutral sidebar, brand block, compact selected row, aligned shortcut hints, and anchored local-recording status card.
- [x] 5.2b Apply shared opacity, radius, border, shadow, spacing, and typography tokens across Overview, Diary, History, and Settings.
- [x] 5.3 Replace the AI Recap tile/dialog flow with one inline AI Diary Settings section.
- [x] 5.4 Keep provider onboarding, API-key guidance, connection test, privacy controls, prompt customization, manual/automatic generation controls, and data-storage settings intact.

## 6. Verification

- [x] 6.1 Add Rust schema migration and storage behavior tests.
- [x] 6.2 Add AI prompt/result and failure behavior tests.
- [x] 6.3 Add widget tests for exact main-branch Overview structure, carousel/date/diary linkage, bounded history scrolling, and removed Recap navigation.
- [x] 6.4 Add interaction tests for app focus and AI diary provenance.
- [x] 6.4a Add scheduler tests for local time, tray state, catch-up, deduplication, empty days, and provider failure.
- [x] 6.5 Run formatter, Flutter analyze/tests, Rust tests, and Windows build.
- [x] 6.6 Review final screenshots against the approved OpenSpec and main-branch carousel baseline.
- [x] 6.7 Produce and deliver a versioned Windows x64 EXE package.
