# Design: Overview workspace with AI diary and usage history

## Context

`origin/main` uses a stable dashboard structure: range chips, a permanent calendar, a same-height data carousel, and a separate diary section. The feature branch added a top summary strip and a standalone Recap route that combines AI/local recap, diary, and history. User feedback rejects the duplicated hierarchy but supports the existing theme, calendar, and original carousel behavior.

The design therefore treats `origin/main` as the baseline and makes only three targeted changes: remove the feature-branch top strip, add Usage History as one carousel page, and add AI authoring to the existing diary below the workspace. AI strengthens Diary rather than becoming a second reporting system.

## Goals

- Restore the original carousel's appearance and predictable navigation.
- Fit the full primary workspace without the external metric strip consuming height.
- Make range/calendar selection the single source of truth for all pages.
- Make AI output a real, attributable diary entry.
- Keep AI setup discoverable but confined to Settings.

## Non-Goals

- Redesigning the calendar or app shell.
- Adding new chart types.
- Treating application names as proof of completed work.
- Auto-enabling AI.
- Reusing the old Recap report UI under a different title.

## Information Architecture

### App shell

1. Overview
2. Settings

The standalone Recap destination and `Ctrl+2` mapping are removed. The remaining shortcuts are reassigned consistently during implementation.

The sidebar visual reference is the approved feature-branch shell: opaque warm off-white surface, thin content divider, compact rounded TimeTrace mark, restrained typography, 40–48 px navigation rows, muted green full-row selection, right-aligned shortcut hints, and the bordered `本地记录` status card anchored at the bottom. With only Overview and Settings remaining, preserve the width, rhythm, and deliberate empty space rather than enlarging or centering the two destinations.

### Overview

1. Range selector: Today / Yesterday / Week / Month
2. Two-column workspace on desktop, stacked workspace on narrow windows
   - Calendar
   - Carousel
3. The original diary section below the workspace, enhanced by an optional AI writing action

### Default carousel order

1. Bar
2. Pie
3. Summary
4. Applications
5. Hourly
6. Usage History

All original main-branch pages are enabled by default. Overview Layout settings allow every carousel page, including Bar and Pie, to be enabled, disabled, and reordered.

## Decisions

### Decision 1: Restore rather than redesign the carousel

Reuse the main-branch PageView behavior, navigation arrows, indicator behavior, repaint boundaries, and calendar-height alignment. Port only fixes required for visible-order indexing, long names, and the added Usage History page.

Rationale: the user explicitly prefers the main-branch carousel; minimizing visual invention reduces regression risk.

### Decision 2: One selection model

`dashboardRangeProvider` remains the owner of range and effective date. Every page reads the same selection. Page-specific state such as selected application, expanded session, scroll focus, AI loading state, and diary editing state resets when the effective selection changes.

For multi-day ranges, data pages aggregate the range, while the existing Diary section and Usage History list entries in the same range. Calendar day selection switches to the selected day behavior already used by the dashboard provider.

### Decision 3: Fixed outer height, internal page scrolling

At desktop widths the calendar is measured after layout and the carousel adopts exactly that height, matching the main-branch behavior. The Usage History page owns an internal lazy scroll view. Carousel page changes never change the outer height.

At narrow widths, the carousel uses a responsive minimum height and stacks with the calendar. Layout decisions use parent constraints rather than device type.

### Decision 4: AI output is a published diary entry

Replace the recap `headline + summary` contract with a diary content contract. Successful output is stored through a dedicated bridge method that attaches source/model metadata atomically. Provider failures do not fall back to publishing a local statistical recap.

Manual generation is always available from the existing Diary section; success directly publishes, and a second generation for the same selected date requires confirmation. Settings may additionally enable one scheduled automatic generation per local day at a selected clock time.

The automatic scheduler runs inside the TimeTrace desktop process, including while minimized to tray. It stores the last completed local date, checks after startup/resume as well as at the scheduled time, catches up only on the same day, and never backfills previous dates automatically. Missing activity does not create an empty entry or mark the date complete. Failed requests remain retryable and never publish a fallback recap.

### Decision 5: Provenance is structured

Add the following diary metadata:

- `source`: `manual`, `ai_generated`, or `ai_assisted`
- `source_model`: nullable model identifier

Existing entries default to `manual`. Editing an `ai_generated` entry through the user editor changes it to `ai_assisted`; editing `manual` remains `manual`.

Do not encode the source in Markdown content. This keeps export and display concerns separable and prevents a user edit from accidentally deleting provenance.

### Decision 6: Settings are inline

Replace the current recap settings tile/dialog interaction with an inline `AI 日记` section in the existing Settings scroll. Disabled state is compact. Enabling expands provider/model/endpoint/credential/privacy/test controls, prompt customization, reflection/suggestion preferences, manual/automatic generation controls, local-time picker, and restore-default action in place. The Overview app bar receives no settings affordance.

### Decision 7: History means raw use history

The History page is not an AI interpretation. It presents factual chronological activity/session records with time, app, and meaningful duration. It filters zero-length noise, uses lazy scrolling, and remains bounded by the carousel card.

### Decision 8: Preserve the approved desktop shell style

Use the current compact custom sidebar rather than reverting to Material `NavigationRail`. Keep its warm-neutral opaque surface and low-saturation selected treatment so navigation remains legible over custom content backgrounds. Remove only the Recap destination; keep the brand block, bottom local-recording status, row proportions, shortcuts, border treatment, and spacing hierarchy.

Extend the same visual grammar to the content canvas: warm off-white primary surfaces, muted gray-green accents, thin neutral borders, minimal shadows, consistent radii, and controlled opacity. Background imagery is atmospheric rather than structural; text, controls, charts, and diary content must never depend on it for contrast. Use a small, repeatable typography hierarchy—strong brand, semibold section title, regular body, subdued metadata—to eliminate the uneven bold/light treatment reported in the current build.

## Data Flow

1. User changes range or selects a calendar date.
2. Dashboard data, diary entries, and usage history refresh from the same selection.
3. User uses the original Diary section and optionally requests AI generation.
4. The client builds a bounded factual context from observed activity and allowed diary text.
5. The provider returns diary prose.
6. Rust publishes the entry with `ai_generated` and model metadata in one transaction.
7. Calendar markers, Diary, and related providers invalidate and refresh.

For scheduled generation, a local scheduler first verifies AI readiness, today's meaningful activity, and the stored last-completed date before entering step 4.

## Prompt Contract

Prompting has two layers:

1. A non-editable system prompt owns factual grounding, privacy, and output validation.
2. A locally persisted user instruction controls voice, length, structure, emphasis, habit reflection, and suggestions.

The fixed system prompt instructs the model to:

- write concise first-person Chinese diary prose;
- use only observed application history and explicitly allowed diary context;
- distinguish observation from inference;
- never invent projects, tasks, outcomes, emotions, intent, or productivity;
- naturally include a brief habit reflection and at most one evidence-based suggestion when enabled and defensible;
- avoid metric blocks, rankings, scores, fact lists, and JSON fields unrelated to diary content;
- return a single machine-readable `content` string.

The model context includes a bounded selected date, ordered usage-history facts, top observed applications, and optional existing diary text only when that privacy option is enabled. Context assembly is controlled by the application rather than by editable prompt placeholders so custom instructions cannot exfiltrate data that the user did not allow.

## Migration

1. Add nullable/source columns with safe defaults in a new SQLite migration.
2. Update storage contracts and DTOs.
3. Regenerate flutter_rust_bridge bindings.
4. Treat all pre-migration rows as `manual`.
5. Preserve IDs, dates, content, status, timestamps, and image links.

## Error Handling

- AI disabled: manual diary remains; show quiet disabled copy.
- Missing key/config: no request; direct the user to the inline Settings section.
- Timeout/provider error/invalid response: no publication; inline retry.
- Database publication error: show failure and retain generated text transiently long enough for retry/copy, but do not claim it was published.
- Empty range: Summary/History use compact empty states; manual diary remains available for a day.

## Verification Strategy

- Provider/unit tests for visible-order migration and selection synchronization.
- Widget tests at desktop and narrow constraints for absence of the external strip, equal desktop card heights, carousel order, bounded scrolling, and route removal.
- Interaction tests for calendar changes, carousel navigation, app-to-list focus, AI disabled state, generation success/failure, duplicate confirmation, and provenance after editing.
- Scheduler tests for local-time changes, tray execution, same-day catch-up, date deduplication, empty activity, failure retryability, and no previous-day backfill.
- Rust migration/storage tests for existing databases and source transitions.
- Prompt contract tests that assert diary-only output schema and exclusion of legacy recap fields.
- Prompt customization tests that assert persistence, restore-default behavior, suggestion toggles, and fixed-guardrail precedence.
- Flutter analyze/test, Rust tests, Windows build, and a final screenshot review against the main-branch carousel.

## Confirmed Product Decisions

1. Manual generation remains available and directly publishes after success; repeat generation for the same selected day requires confirmation.
2. Daily automatic generation is optional and uses a user-selected local time.
3. Automatic generation runs while TimeTrace remains in the tray and catches up only later on the same local day.
4. Editing an AI-generated diary changes its provenance from `AI 生成` to `AI 辅助`.
5. AI generation is day-scoped; Week and Month display existing entries without producing a synthetic range diary.
