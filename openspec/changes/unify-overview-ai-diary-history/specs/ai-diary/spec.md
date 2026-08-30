## ADDED Requirements

### Requirement: AI writes a complete reflective diary

The default AI prompt SHALL produce one concise first-person diary entry about the selected date. When supported by the supplied facts, the same diary SHALL naturally include a brief reflection on the user's time-use pattern and at most one practical improvement suggestion. It SHALL NOT produce a dashboard headline, metric block, ranking, score, fact list, or separate report/insight surface.

#### Scenario: Activity context is sufficient

- **WHEN** AI diary generation is requested with factual application-use history
- **THEN** the model returns diary prose suitable for direct publication
- **AND** it may describe observed application use and chronology
- **AND** it may include one habit observation and one gentle suggestion that are directly supported by the supplied facts
- **AND** it does not claim unobserved tasks, outcomes, intent, emotion, or productivity

#### Scenario: Context cannot establish concrete work

- **WHEN** only application names and durations are known
- **THEN** the diary uses cautious language about what was observed
- **AND** it does not invent what the user accomplished
- **AND** it omits a suggestion when no defensible suggestion can be derived

### Requirement: Prompt customization is bounded

The Settings page SHALL let the user customize diary voice, length, structure, emphasis, and whether habit reflection or suggestions are included. The application SHALL keep a non-editable system prompt that enforces factual grounding, privacy boundaries, and the output contract.

#### Scenario: User customizes writing style

- **WHEN** the user saves a custom diary instruction
- **THEN** subsequent AI diaries follow that requested voice and structure
- **AND** the instruction persists locally
- **AND** the user can restore the built-in default

#### Scenario: Custom instruction conflicts with factual guardrails

- **WHEN** a custom instruction asks the model to invent unsupported activities, outcomes, or personal states
- **THEN** the fixed system prompt continues to prohibit those claims
- **AND** TimeTrace still validates the returned content before publication

#### Scenario: User disables suggestions

- **WHEN** the user turns off `包含改进建议`
- **THEN** AI diary generation still summarizes the selected day's usage
- **AND** no suggestion is required in the generated diary

### Requirement: AI use is explicit and configured in Settings

AI diary SHALL remain disabled by default. Enablement, provider, model, endpoint, API-key guidance, connection testing, privacy options, prompt customization, habit-reflection preference, suggestion preference, and automatic-generation scheduling SHALL be integrated into the existing Settings page as one `AI 日记` section.

#### Scenario: User has never configured AI

- **WHEN** the user opens Settings
- **THEN** the AI Diary section explains the disabled local state in one compact block
- **AND** no API key is required until AI is enabled

#### Scenario: User configures a provider

- **WHEN** the user enables AI diary
- **THEN** model and credential controls expand inline in the Settings page
- **AND** prompt and content preferences are editable in the same section
- **AND** the user can optionally enable daily automatic generation and select a local clock time
- **AND** the user can test the connection without sending TimeTrace usage or diary content

#### Scenario: User views Overview

- **WHEN** AI is configured or unconfigured
- **THEN** Overview does not show an AI settings button in its app bar

### Requirement: Successful AI output is published with provenance

A successful AI generation SHALL create a published diary entry tagged with its source and model. Provenance SHALL be stored as structured metadata rather than inserted into the diary body.

#### Scenario: AI diary is published

- **WHEN** generation succeeds and the publish action completes
- **THEN** a diary entry is stored with source `ai_generated`
- **AND** the entry displays `AI 生成` and the configured model
- **AND** it participates in the same diary feed, calendar marker, and date filters as handwritten entries

#### Scenario: Existing data is migrated

- **WHEN** a database created before this change is opened
- **THEN** existing diary entries are treated as `manual`
- **AND** no diary content or images are lost

### Requirement: Editing preserves honest provenance

An AI-generated entry SHALL remain distinguishable after a user edits it.

#### Scenario: User edits an AI-generated entry

- **WHEN** the edited content is saved
- **THEN** the entry source becomes `ai_assisted`
- **AND** the UI displays `AI 辅助`
- **AND** the original model metadata remains available

### Requirement: AI failure never creates a misleading entry

Failed, timed-out, malformed, or cancelled AI generation SHALL NOT publish a fallback local recap as if it were an AI diary.

#### Scenario: Provider request fails

- **WHEN** the model request fails or returns invalid content
- **THEN** no diary entry is published
- **AND** the existing manual diary data is unchanged
- **AND** the existing diary section shows a recoverable inline error

### Requirement: Manual generation remains available

The existing diary section SHALL provide a manual AI generation action whenever AI diary is enabled and configured. A successful result SHALL be directly published. A second AI generation for the same selected date SHALL require explicit confirmation.


#### Scenario: User manually generates a diary

- **WHEN** the user clicks `AI 写今日日记` for a selected day that has no AI-generated diary
- **THEN** the model is called once and a successful result is directly published
- **AND** the new entry appears in the existing diary feed with AI provenance

#### Scenario: User manually regenerates the same day

- **WHEN** an AI-generated or AI-assisted entry already exists for the selected day
- **THEN** TimeTrace asks for confirmation before making another model request
- **AND** cancelling the confirmation leaves the diary unchanged

### Requirement: Daily automatic generation is configurable

The Settings page SHALL provide an optional `每日自动生成` switch and a local-time picker. When enabled, TimeTrace SHALL attempt at most one automatic AI diary publication for the current local day at or after the configured time while the application is running, including while minimized to the system tray.

#### Scenario: Configured time arrives normally

- **WHEN** AI diary is enabled and configured, automatic generation is enabled, the configured local time arrives, valid activity exists, and no AI diary has been generated automatically for today
- **THEN** TimeTrace generates and directly publishes one AI diary for today
- **AND** it records completion for that local date to prevent duplicate automatic publication

#### Scenario: Application is minimized to tray

- **WHEN** the configured time arrives while the main window is hidden but TimeTrace is still running in the tray
- **THEN** automatic generation proceeds under the same conditions as when the window is visible

#### Scenario: System misses the configured time

- **WHEN** TimeTrace starts or resumes later than the configured time on the same local day
- **THEN** it performs one catch-up attempt if today's automatic diary has not already been completed
- **AND** it does not automatically backfill previous dates

#### Scenario: Automatic diary already exists

- **WHEN** the scheduler checks again on a local date already marked complete
- **THEN** no model request is made and no duplicate diary is published

#### Scenario: No meaningful activity exists

- **WHEN** the scheduled attempt finds no valid activity for today
- **THEN** no empty diary is generated or published
- **AND** the scheduler may re-evaluate later that same day without marking the date complete

#### Scenario: Scheduled generation fails

- **WHEN** provider, network, validation, or publication fails during an automatic attempt
- **THEN** no diary is published and the date is not marked complete
- **AND** failure is logged and surfaced non-intrusively

#### Scenario: User changes the automatic time

- **WHEN** the user saves a new automatic-generation time
- **THEN** future checks use the new local clock time
- **AND** an already completed automatic diary for today is not generated again

### Requirement: AI diary generation is day-scoped

AI diary generation SHALL create a diary for one selected local date. Week and Month selections SHALL display existing diaries and aggregated data but SHALL NOT generate one synthetic range diary.

#### Scenario: User views Week or Month

- **WHEN** the active range is Week or Month
- **THEN** existing diary entries remain visible for that range
- **AND** AI generation requires selecting one concrete calendar day
