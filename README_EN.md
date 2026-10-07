<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  Activity statistics · Timeline · Local journal
  <br>
  <b>Rust</b> core + <b>Flutter</b> UI. Local records, optional AI summaries.
</p>

<p align="center">
  <a href="https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1"><img src="https://img.shields.io/badge/Release-v1.2.0--preview.1-537A68?style=flat-square" alt="v1.2.0-preview.1"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?style=flat-square" alt="Windows 10 / 11">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-67716C?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="README.md">中文</a> ·
  <a href="#download">Download</a> ·
  <a href="#interface-tour">Interface tour</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="https://github.com/wellorbetter/timetrace/issues">Report an issue</a>
</p>

![TimeTrace workspace](docs/screenshots/v1.2-workbench.png)

TimeTrace is an open-source desktop activity tracker and journal. See which applications you used and for how long, by hour, day, week, month or a custom range. Calendar, charts and journal share one workspace, with detailed records available when you need them.

## Download

**[Download the Windows x64 preview →](https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1)**

Extract the complete `TimeTrace-v1.2.0-preview.1-windows-x64.zip` archive and run `Release/timetrace_app.exe`. Exit the old version and back up your records before updating. Do not run multiple recording instances. [All releases](https://github.com/wellorbetter/timetrace/releases).

> This is a Windows preview. Some UI details and folder-opening issues remain and are planned for follow-up fixes. No new macOS package is included.

## What's new

v1.2 reorganizes the interface around a customizable workspace with calendar, rotating data views and journal. The timeline shows activity by time segment. Tasks, Pomodoro, countdown and poetry are available as widgets; timer history opens in a small dialog. Background, materials and settings controls have also been adjusted.

## Features

- **Activity statistics** — hourly, daily, weekly, monthly and custom ranges.
- **Timeline** — review time segments and expand detailed usage records.
- **Data views** — bar and pie charts, daily summary, application details and hourly distribution.
- **Journal and optional AI** — local Markdown entries, images and optional AI summaries.
- **Workspace widgets** — customizable layouts with tasks, Pomodoro, countdown and poetry.
- **Desktop settings** — background, theme, fonts, materials, tray, startup and excluded applications.

## Interface tour

### Review time segments, then inspect the details

Start with a segment overview and expand the applications and window records underneath.

| Timeline | Expanded records |
| --- | --- |
| ![Timeline](docs/screenshots/v1.2-time-flow.png) | ![Expanded records](docs/screenshots/v1.2-time-flow-details.png) |

### One calendar, several data views

Select a date to update the data views. Application durations appear in the hero screenshot; the carousel also offers daily summaries, application details and hourly distribution.

| Daily summary | Application details |
| --- | --- |
| ![Daily summary](docs/screenshots/v1.2-usage-summary.png) | ![Application details](docs/screenshots/v1.2-app-details.png) |

<details>
<summary>Show the hourly distribution screenshot</summary>

![Hourly distribution](docs/screenshots/v1.2-hourly.png)

</details>

### Summarize the day and make the interface yours

AI summaries are optional. Statistics and local journals work without AI; theme, language and fonts can be adjusted independently.

| AI summary preview | Appearance settings |
| --- | --- |
| ![AI summary](docs/screenshots/v1.2-ai-summary.png) | ![Appearance](docs/screenshots/v1.2-appearance.png) |

<sub>The owner selected these screenshots and their wallpaper. The wallpaper is not bundled as a default asset.</sub>

## Privacy

Basic records and journals stay local, without requiring an account. When enabled and triggered, AI summaries send necessary content to your configured model service, subject to its privacy policy and pricing. Poetry may access a public service, so the application is not completely offline.

Databases, journal images, executable paths and window titles may contain private information. Back them up and do not include keys or private records in issue reports.

## Development

| Module | Responsibility |
| --- | --- |
| `crates/core` | Activity tracking, time records and SQLite storage |
| `bridge` | Rust / Flutter bindings |
| `app` | Flutter desktop interface |

<details>
<summary>Build the Windows app from source</summary>

The current interface is merged into main. To reproduce the published package, use the [v1.2.0-preview.1 tag](https://github.com/wellorbetter/timetrace/tree/v1.2.0-preview.1). Requires Flutter, Rust and Visual Studio with Desktop development with C++.

```powershell
git switch --detach v1.2.0-preview.1
cd app
flutter pub get
flutter build windows --release --no-tree-shake-icons
```

</details>

## License

[MIT](LICENSE). Third-party components retain their licenses. The personal wallpaper shown in screenshots is not a reusable default asset.
