# Change: Unify Overview, AI diary, and usage history

## Why

The current feature branch duplicates information across an external four-metric strip, the Overview carousel, and a standalone Recap page. This lowers information density, makes the dashboard taller than the calendar, and separates AI-generated prose from the diary it conceptually belongs to.

The main branch already has the preferred interaction model: one permanent calendar beside one coordinated data carousel, followed by the diary. The change should restore that Overview as-is, add usage history to the carousel, and redefine AI Recap as an opt-in capability that strengthens the existing diary.

## What Changes

- Restore the main-branch Overview composition and carousel behavior as the visual and interaction baseline.
- Preserve the feature branch's restrained desktop sidebar language—opaque warm-neutral surface, compact brand, low-saturation selected row, shortcut hints, and anchored local-recording status—while removing the Recap destination.
- Keep the main-branch Overview structure: range selector, calendar/carousel workspace, then the existing diary section.
- Remove the external four-metric summary strip. Any retained summary values live inside the carousel's summary page.
- Preserve the existing diary editor/feed below the workspace and add AI generation to it without replacing its manual workflow.
- Add one bounded usage-history carousel page linked to the same selection.
- Redefine AI Recap as AI diary generation: the default prompt writes one concise diary containing a usage summary, evidence-based habit reflection, and at most one practical suggestion instead of a separate report.
- Allow users to customize diary voice, length, structure, and emphasis while keeping factual/privacy guardrails non-editable.
- Keep manual AI diary generation available and optionally schedule one automatic generation per local day at a user-selected time.
- Directly publish successful AI diary generations with visible provenance metadata.
- Remove the standalone Recap navigation destination and route.
- Integrate all AI diary configuration, privacy controls, prompt customization, and automatic-generation scheduling directly into the existing Settings page; do not add an Overview settings control or a separate setup dialog.
- Preserve every original main-branch chart page and keep all original pages enabled by default. Overview Layout settings let users enable, disable, and reorder individual pages.

## Capabilities

### New Capabilities

- `overview-workspace`: The main-branch date-linked calendar/carousel and diary layout, with usage history added to the carousel.
- `ai-diary`: Opt-in AI generation of attributable diary entries from TimeTrace activity context.

### Modified Capabilities

- `settings`: AI provider onboarding and privacy controls become an inline Settings section rather than a Recap tab/dialog flow.
- `diary-storage`: Diary entries record whether they were handwritten, AI-generated, or AI-assisted.

### Removed Capabilities

- `standalone-recap`: The separate Recap route, sidebar item, report surface, and duplicated local recap presentation are removed.
- `dashboard-summary-strip`: The four metrics displayed above the calendar/carousel are removed.

## Impact

- Flutter: restoration of the main-branch dashboard composition, carousel preferences, diary enhancement, history page, router/sidebar, settings UI, AI state and copy.
- Rust bridge: diary provenance fields and a dedicated AI diary publish operation.
- SQLite: additive migration for diary source/model metadata; existing entries migrate as handwritten.
- Tests: responsive dashboard layout, carousel/date linkage, AI-disabled behavior, AI publishing/provenance, migration compatibility, and navigation removal.
- Packaging: a new Windows artifact is produced only after the approved spec is implemented and verified.

## Non-Goals

- Replacing the main-branch calendar visual design.
- Adding productivity scores, inferred tasks, mood, or fabricated accomplishments.
- Automatically moving or deleting an existing database.
- Enabling AI or sending data without explicit user configuration.
