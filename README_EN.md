<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  Local-first desktop activity tracker + journal
  <br>
  <b>Rust</b> core + <b>Flutter</b> UI · no account, no cloud, no telemetry
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

## Why TimeTrace

TimeTrace puts “where did my computer time go?” and “what did I do today?” on one local timeline. It tracks foreground activity automatically, then connects the day through calendars, charts, an AI-Recap-style review, and a journal. Core data lives in local SQLite: no sign-in and no activity history sent to a cloud service.

## Features

- **Activity tracking** — records foreground-app active time while excluding idle, lock-screen, and sleep periods
- **AI-Recap-style review** — summarizes the day by app and session with insights and time-allocation views
- **Dashboard** — bar chart / donut chart / 24-hour distribution / daily summary / app carousel, synchronized with the calendar
- **Journal** — social-feed-style diary with Markdown, image albums, auto-saved drafts, and collapsible day groups
- **Desktop integration** — foreground-app/icon resolution, system tray, autostart, and start-minimized behavior
- **Personalization** — excluded apps, monitoring options, theme/font/background, opacity, and dashboard ordering

## Demo & Screenshots

Desktop acceptance CI launches the real app and produces Windows / macOS / Ubuntu walkthrough artifacts. macOS also keeps a deterministic Flutter render-tree demo so a screen-capture permission issue cannot be mistaken for a successful recording simply because an MP4 file exists.

| | |
| --- | --- |
| ![Bar chart](docs/screenshots/dashboard-bar.png) | ![Donut chart](docs/screenshots/dashboard-pie.png) |
| ![Daily summary](docs/screenshots/dashboard-summary.png) | ![App distribution](docs/screenshots/dashboard-apps.png) |
| ![Hourly distribution](docs/screenshots/dashboard-hourly.png) | |

TimeTrace supports local background images, adjustable opacity, and the same background treatment across the dashboard and settings page:

![Dashboard with background](docs/screenshots/background-dashboard.png)

![Settings with background opacity](docs/screenshots/background-settings.png)

## Platform Status

| Platform | Status | Current validation scope |
| --- | --- | --- |
| Windows 10/11 | ✅ Primary release platform | Release build, foreground/idle tracking, tray, full desktop acceptance |
| macOS | 🧪 Desktop acceptance | Native Release build, Rust bridge, tray, real app launch and recording validation |
| Ubuntu X11 / XWayland | 🧪 Desktop acceptance | Native Release bundle, foreground/idle tracking, tray, Xvfb walkthrough |
| Native Wayland | ⚠️ Limited | Global foreground observation depends on compositor and permission model; full support is not claimed |

> Releases are currently Windows-first. macOS / Linux status is represented by the desktop acceptance CI until packaged releases are published.

## Tech Stack

| Module | Description |
| --- | --- |
| `crates/core` | Rust core: platform activity/idle detection, session aggregation, SQLite storage |
| `bridge` | `flutter_rust_bridge` bindings |
| `app/` | Flutter UI: Riverpod 3 + Material 3 across desktop targets |
| `.github/workflows` | Rust / Flutter CI plus native Windows / macOS / Ubuntu acceptance and demo recording |

## Build & Verify

### Common requirements

- Flutter SDK (stable)
- Rust stable toolchain
- Flutter desktop toolchain for the target OS

### Common checks

```bash
cargo test --workspace

cd app
flutter analyze --no-fatal-infos
flutter test
```

### Windows

```powershell
cargo build -p timetrace-bridge --release
cd app
flutter build windows --release
```

Requires Visual Studio 2022 with the Desktop development with C++ workload.

### macOS

```bash
./scripts/build_macos.sh
```

### Ubuntu

```bash
./scripts/build_linux.sh
```

Linux activity tracking is currently validated on X11 / XWayland. Pure Wayland global window observation is subject to desktop-environment permission constraints.

## Download

- Latest release: <https://github.com/wellorbetter/timetrace/releases>
- Windows: grab `TimeTrace-vX.Y.Z-windows-x64.zip`, unzip it, and run `timetrace_app.exe` — no installer required.

## Privacy

Activity history, preferences, and journal content stay on the local machine. Windows stores the default database at `%APPDATA%\TimeTrace\time.db`; macOS and Linux use their platform application-data directories. TimeTrace requires no account and includes no telemetry upload.

## License

[MIT](LICENSE)
