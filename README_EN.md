<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  A local-first desktop activity tracker and journal
  <br>
  <b>Rust</b> core + <b>Flutter</b> UI · Offline by default · Optional AI
</p>

<p align="center">
  <a href="README.md">中文</a>
  ·
  <a href="https://github.com/wellorbetter/timetrace/releases">
    <img src="https://img.shields.io/github/v/release/wellorbetter/timetrace" alt="Release">
  </a>
  ·
  <img src="https://github.com/wellorbetter/timetrace/actions/workflows/ci.yml/badge.svg" alt="CI">
  ·
  <a href="LICENSE"><img src="https://img.shields.io/github/license/wellorbetter/timetrace" alt="MIT License"></a>
</p>

![TimeTrace v1.1 overview](docs/screenshots/v1.1-overview.png)

TimeTrace automatically records foreground applications and active time, then brings the calendar, charts, app details, and journal into one desktop workspace. Records stay on your computer by default; AI journaling is an explicit opt-in.

## Download

Get the latest build from [GitHub Releases](https://github.com/wellorbetter/timetrace/releases/latest).

| Platform | Status | How to run |
| --- | --- | --- |
| Windows 10/11 x64 | Stable | Download `TimeTrace-vX.Y.Z-windows-x64.zip`, extract the complete folder, and run `timetrace_app.exe` |
| macOS | Self-use preview | Download `TimeTrace-vX.Y.Z-macos.zip`, extract it, and run `Install TimeTrace.command`; the app is not Apple-notarized yet |

## Features

- **Automatic tracking** — records foreground apps, window titles, and active time while excluding idle, locked, and suspended periods
- **Calendar and overview** — calendar-linked bar, donut, hourly, daily summary, app ranking, and history views
- **Local journal** — Markdown editing, image albums, draft persistence, and date-based organization beside the day's activity facts
- **AI journal (optional)** — works with DeepSeek and OpenAI-compatible Chat Completions endpoints, with configurable models, writing preferences, and a daily schedule
- **Desktop experience** — system tray, startup/minimize behavior, excluded apps, light/dark themes, fonts, backgrounds, and overview layout controls
- **Data control** — choose the database folder, export CSV, pause tracking, or delete all local data

## AI journal and privacy boundary

AI journaling is off by default. While it is off, TimeTrace does not contact a model service or send usage records or journal text.

When you opt in and generate an entry, TimeTrace sends the configured endpoint only the selected day's necessary usage facts: aggregate active/idle time, session and context-switch counts, peak time, top applications, and a bounded usage history. Window titles, file paths, and raw events are excluded. Existing journal text is also excluded unless you separately enable “Allow existing journal entries.”

The API key comes from a system environment variable that you name; TimeTrace stores the variable name, not the key. The connection test sends no TimeTrace data. Your configured model provider's privacy policy and pricing still apply.

| AI journal | AI settings |
| --- | --- |
| ![AI-generated journal](docs/screenshots/v1.1-ai-diary.png) | ![AI journal settings](docs/screenshots/v1.1-ai-settings.png) |

## Local data

The SQLite database can contain application names, executable paths, window titles, usage sessions, and journal entries. Its default location is:

- Windows: `%APPDATA%\TimeTrace\time.db`
- macOS: `~/Library/Application Support/TimeTrace/time.db`

Installing or starting TimeTrace does not automatically upload this local data. Treat the database and journal images as private data and back them up accordingly.

## Build from source

### Windows

Requirements: Flutter stable, Rust stable, and Visual Studio 2022 with Desktop development with C++.

```powershell
cargo test --workspace
cd app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build windows --release
```

### macOS

Requirements: Flutter stable, Rust stable, and Xcode Command Line Tools.

```bash
cargo test -p timetrace-core -p timetrace-bridge
chmod +x scripts/build_macos.sh
./scripts/build_macos.sh
```

## Architecture

| Module | Description |
| --- | --- |
| `crates/core` | Cross-platform tracking, idle detection, session aggregation, and SQLite storage |
| `bridge` | `flutter_rust_bridge` bindings |
| `app/` | Flutter desktop UI (Riverpod + Material 3) |

## License

[MIT](LICENSE)
