## ADDED Requirements

### Requirement: Overview has one primary workspace

The Overview SHALL preserve the main branch's structure and visual order: date-range selector, permanent calendar beside one carousel, then the existing diary section. It SHALL NOT show an external four-metric strip or a separate AI summary card.

#### Scenario: Overview opens on a desktop window

- **WHEN** the user opens Overview at a two-column width
- **THEN** the calendar appears on the left and exactly one carousel page appears on the right
- **AND** their outer card heights are equal
- **AND** no active-time/app-count/focus/most-used strip appears above them
- **AND** the original diary section remains below the calendar/carousel workspace

#### Scenario: Overview opens in a narrow window

- **WHEN** the available content width falls below the desktop breakpoint
- **THEN** the same calendar and carousel content stack without horizontal overflow
- **AND** no information is removed solely because of the narrower width

### Requirement: Main-branch carousel behavior is the baseline

The Overview carousel SHALL preserve the main branch's card styling, infinite one-page navigation, clickable page indicators, cached pages, calendar alignment, and cross-page app selection behavior unless this specification explicitly changes it.

#### Scenario: User crosses the carousel boundary

- **WHEN** the user advances from the last visible page or moves backward from the first visible page
- **THEN** the carousel moves by one page without sweeping across intermediate pages

#### Scenario: User selects an application from a data view

- **WHEN** a chart or history affordance selects an application and requests the application page
- **THEN** the carousel resolves the destination against the visible page order
- **AND** the selected row is brought into view with a stable alignment
- **AND** the whole dashboard does not jump vertically

### Requirement: Original carousel pages remain enabled by default

The default visible order SHALL preserve the main branch's original Bar, Pie, Summary, Applications, and Hourly pages, followed by the new Usage History page. Every original page SHALL be enabled by default. Overview Layout settings SHALL let the user enable, disable, and reorder individual carousel pages.

#### Scenario: Existing user has no explicit hidden-view preference

- **WHEN** the updated application loads the user's existing carousel order
- **THEN** Usage History is appended without deleting the user's known order
- **AND** every original main-branch page remains enabled unless the user previously disabled it

#### Scenario: User disables chart pages

- **WHEN** the user hides Bar and Pie
- **THEN** Summary, Applications, Hourly, and Usage History remain available
- **AND** the user can re-enable Bar and Pie from Overview Layout settings

### Requirement: Summary metrics live inside the summary page

The summary page SHALL provide a compact date/range summary using the main-branch summary presentation. Long application names SHALL receive enough width to remain readable and SHALL expose the full name through a tooltip or detail interaction when truncation is unavoidable.

#### Scenario: Most-used application has a long executable name

- **WHEN** the most-used application name does not fit on one line
- **THEN** it does not shrink the primary value typography below the design token minimum
- **AND** the user can reveal the full application name

### Requirement: Calendar selection links every carousel page

All carousel pages and the diary section SHALL derive their content from the same dashboard range and effective calendar date. A selection change SHALL clear stale per-page focus and update visible content without requiring route navigation.

#### Scenario: User selects a day in the calendar

- **WHEN** the selected calendar day changes
- **THEN** Bar, Pie, Summary, Applications, Hourly, Usage History, and the diary section refresh for that effective selection
- **AND** an expanded application/session row from the previous selection is closed

#### Scenario: User selects week or month

- **WHEN** the user selects a multi-day range
- **THEN** aggregate data pages use that range
- **AND** the diary section and Usage History show entries from that same range in newest-first order

### Requirement: AI strengthens the original diary section

The original diary section below the calendar/carousel workspace SHALL remain the single place for manual diary authoring and published diary entries. AI generation SHALL be added as a compact action inside that existing diary workflow; it SHALL NOT create a new diary carousel page or a separate AI report surface.

#### Scenario: User writes without AI

- **WHEN** the user writes, edits, publishes, deletes, or attaches images manually
- **THEN** the behavior remains compatible with the main-branch diary
- **AND** AI configuration is not required

#### Scenario: AI is disabled

- **WHEN** AI diary is not enabled in Settings
- **THEN** manual diary authoring remains fully available
- **AND** no model request is made
- **AND** the diary uses a quiet status or action state rather than a large onboarding surface

### Requirement: Usage History is a bounded carousel page

The Usage History page SHALL display factual application-use records only. It SHALL use lazy internal scrolling, omit invalid zero-length noise, and cap the initially rendered records while retaining access to the remaining records through scrolling.

#### Scenario: Range contains many activity records

- **WHEN** the selected range contains more records than fit in the page
- **THEN** the list remains within the calendar-matched card height
- **AND** records show time, application, and meaningful duration in a consistent row layout
- **AND** the dashboard itself does not grow with the record count

#### Scenario: No activity exists

- **WHEN** the selected range has no valid activity records
- **THEN** the page shows a concise empty state and no zero-duration placeholder rows

### Requirement: Standalone Recap navigation is removed

The application SHALL have no standalone Recap destination after this change.

#### Scenario: User views the sidebar

- **WHEN** the application shell renders
- **THEN** the primary destinations are Overview and Settings
- **AND** the previous Recap route and keyboard shortcut are unavailable

### Requirement: Desktop sidebar keeps the approved visual language

The application shell SHALL retain the approved compact desktop sidebar style: an opaque warm-neutral surface separated from the content canvas, a concise TimeTrace brand row, equal-height navigation rows, a low-saturation green selected background, subdued shortcut hints, generous unused vertical space, and an anchored local-recording status card.

#### Scenario: Overview is selected

- **WHEN** the application opens after the standalone Recap destination is removed
- **THEN** Overview uses the full rounded selected-row treatment previously demonstrated in the approved sidebar reference
- **AND** Settings remains a quiet unselected row
- **AND** removing Recap does not collapse the sidebar width or enlarge the remaining navigation rows

#### Scenario: Background image is visible in the content canvas

- **WHEN** the user has configured a custom background image
- **THEN** the sidebar remains visually opaque and readable
- **AND** content imagery does not show through the sidebar surface or reduce navigation contrast

#### Scenario: Keyboard shortcuts are shown

- **WHEN** the desktop sidebar renders
- **THEN** each available destination shows its current shortcut in a subdued trailing column
- **AND** shortcut text alignment remains stable across rows

### Requirement: The desktop canvas uses one restrained visual system

Overview, Diary, Usage History, and Settings SHALL share the approved warm-neutral and muted-green visual language. Primary content surfaces SHALL remain sufficiently opaque over custom backgrounds, use consistent neutral borders and restrained shadows, and follow a stable typography hierarchy rather than mixing arbitrary heavy and light weights.

#### Scenario: Custom background is visually busy

- **WHEN** a high-detail custom image is visible behind the content canvas
- **THEN** primary cards remain readable without the image competing with text or charts
- **AND** translucent treatment is limited to secondary decorative layers

#### Scenario: Multiple cards appear together

- **WHEN** calendar, carousel, diary, or settings cards share a screen
- **THEN** equivalent cards use consistent corner radii, border strength, shadow weight, title weight, and internal spacing
- **AND** muted green is reserved for selection, status, and meaningful data emphasis
