<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  Local-first Windows time tracking &amp; journal app
  <br>
  <b>Rust</b> core + <b>Flutter</b> UI · 100% local, no network, no telemetry
</p>

<p align="center">
  <a href="README.md">中文</a>
  ·
  <a href="https://github.com/wellorbetter/timetrace/releases">
    <img src="https://img.shields.io/github/v/release/wellorbetter/timetrace" alt="Release">
  </a>
  ·
  <img src="https://github.com/wellorbetter/timetrace/actions/workflows/ci.yml/badge.svg" alt="CI">
</p>

---

## Features

- **Usage stats** — tracks foreground app active time; auto-detects idle, lock screen and sleep, excluded from active time
- **App icons** — resolves the foreground app and its icon in real time; lives in the system tray with a quick right-click menu
- **Dashboard** — bar chart / donut chart / 24h hourly distribution / daily summary / app distribution carousel, synced with the calendar
- **Journal** — social-feed style diary: Markdown editing, image albums, auto-saved drafts, grouped & collapsible by day
- **Settings** — idle threshold, auto-start and more

## Screenshots

| | |
| --- | --- |
| ![Bar chart](docs/screenshots/dashboard-bar.png) | ![Donut chart](docs/screenshots/dashboard-pie.png) |
| ![Daily summary](docs/screenshots/dashboard-summary.png) | ![App distribution](docs/screenshots/dashboard-apps.png) |
| ![Hourly distribution](docs/screenshots/dashboard-hourly.png) | |

## Tech Stack

| Module | Description |
| --- | --- |
| `crates/core` | Rust core: Win32 event-hook monitoring, idle/sleep detection, SQLite storage |
| `bridge` | flutter_rust_bridge bindings |
| `app/` | Flutter UI: Riverpod 3 + Material 3, Windows desktop |

## Build

### Prerequisites

- Windows 10/11
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) (stable channel)
- [Rust toolchain](https://rustup.rs/) (`cargo` must be on PATH; the Rust bridge is built automatically)
- Visual Studio 2022 (Desktop development with C++ workload)

### Commands

```bash
# 1) Rust core tests
cargo test -p timetrace-core --lib

# 2) Flutter static analysis
cd app && flutter analyze --no-fatal-infos

# 3) Windows Release build (compiles & copies timetrace_bridge.dll automatically)
cd app && flutter build windows --release
# Output: app/build/windows/x64/runner/Release/
```

## Download

- Latest release: <https://github.com/wellorbetter/timetrace/releases>
- Grab `TimeTrace-vX.Y.Z-windows-x64.zip`, unzip and run `timetrace_app.exe` — no install needed.

## How It Was Built

Vibe-coded end to end: prototyped with DeepSeek V4 Flash + Pi, then polished with Codex for performance and UX.

## Privacy

All data stays in local SQLite (`%APPDATA%\TimeTrace\time.db`); nothing is uploaded.

## License

[MIT](LICENSE)