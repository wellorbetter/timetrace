# Nowline

Nowline is TimeTrace's local live-caption surface: recent foreground activity
passes by like restrained lyrics while the current episode stays highlighted.
It is a presentation of the same factual activity stream used by AI Recap, not
a second tracker and not an autonomous agent.

## Data path

```mermaid
flowchart TD
    A[Foreground monitor] --> B[TrackedEvent channel]
    B --> C[SQLite session aggregator]
    B --> D[Bounded live ring buffer]
    D --> E[Read-only local FFI snapshot]
    E --> F[Deterministic semanticizer]
    F --> G[Nowline page and overlay]
```

The in-memory buffer keeps at most 12 application episodes. Title changes
inside one application update the current episode instead of producing a line
for every tab or document. The Flutter surface polls the small snapshot every
750 ms; it performs no database scan and no network request.

## Privacy contract

| Data | Default | Notes |
| --- | --- | --- |
| Application name | Visible locally | Uses the existing TimeTrace event source |
| Window title | Hidden | Explicit opt-in; known sensitive titles remain redacted |
| Excluded applications | Never shown | Reuses the monitor's existing exclusion boundary |
| Keystrokes / clipboard | Never captured | Not part of the TimeTrace event model |
| AI/model request | Never used for live updates | No waiting agent and no background token spend |
| Network sharing | Not implemented | The `LiveActivityPort` boundary allows a future redacted transport |

Pausing tracking closes the current live episode immediately. The TimeTrace
window itself is filtered from Nowline so the overlay cannot narrate itself.

## Desktop behavior

- The existing TimeTrace window can enter a compact transparent,
  always-on-top mode and later restore its exact size and position.
- The Nowline page rebuilds the latest 12 completed episodes for today from
  SQLite, so its compact scrollback survives an application restart.
- The overlay can be dragged while unlocked.
- Click-through mode sends pointer input to the application beneath it. Use the
  TimeTrace tray/menu-bar item to unlock or return to the main window.
- Placement, line count, opacity, timestamps, title visibility, and the initial
  click-through state are persisted locally in `nowline.json`.

The surface uses `window_manager`, so the Flutter implementation is shared by
Windows and macOS. Platform-specific foreground resolution remains inside the
existing Rust core.

## Visual contract

Nowline keeps TimeTrace's compact, data-dense desktop language. Glass is a
functional layer rather than a decoration applied to every card:

- the launch hero and floating overlay use a clipped backdrop blur;
- ledger and settings surfaces remain translucent but do not stack blur
  filters;
- every surface has an outer separator and a one-pixel inner highlight so the
  boundary remains legible over light, dark, and textured backgrounds;
- high-contrast mode removes blur, raises surface opacity, and strengthens the
  outer border;
- historical text keeps semantic foreground contrast; only the decorative
  timeline marker fades with age;
- the settings dashboard becomes two columns on wide desktop windows and a
  full-width compact stack in narrow windows.

The reusable `NowlineGlassSurface` encodes these roles so the page, preview,
and overlay cannot drift into separate visual systems.

## Deliberate non-goals for this PR

- friend accounts, presence rooms, or a cloud backend
- broadcasting raw history or window titles
- invoking AI for every activity switch
- a second monitor process or duplicate SQLite writer

A later paired mode can implement `LiveActivityPort` with an encrypted,
redacted presence-card transport without changing the timeline UI or weakening
the local default.
