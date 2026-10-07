# TimeTrace

An open-source desktop activity tracker and journal, built with Rust and Flutter. Review which applications you used and how long you spent in them, by hour, day, week, month, or a custom range. Basic records stay local; AI summaries are optional.

[中文](README.md) · [Windows preview](https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1) · [All releases](https://github.com/wellorbetter/timetrace/releases) · [Issues](https://github.com/wellorbetter/timetrace/issues)

![Calendar, data and journal workspace](docs/screenshots/v1.2-workbench.png)

## What's new in the v1.2 preview

The interface has been reorganized around a customizable workspace: calendar, rotating data views and journal, with task lists, Pomodoro, countdown and poetry widgets. The activity timeline lets you review applications by time segment. Timer history opens in a small dialog. Background, material, theme and settings controls have also been adjusted.

This is a **Windows preview**, not a fully validated stable release. Some folder-opening and window-layout issues remain.

## Features

- Activity statistics: time ranges, bar and pie charts, application details and hourly distribution.
- Timeline: review applications and durations by time segment.
- Local journal: Markdown, images and optional AI summaries.
- Workspace widgets: tasks, Pomodoro, countdown and poetry.
- Desktop preferences: background, theme, fonts, materials, tray, startup and excluded applications.

## Screenshots

### Activity timeline

![Activity timeline](docs/screenshots/v1.2-time-flow.png)

### Daily activity summary

![Daily summary](docs/screenshots/v1.2-usage-summary.png)

### Application details and hourly distribution

![Application details](docs/screenshots/v1.2-app-details.png)

![Hourly distribution](docs/screenshots/v1.2-hourly.png)

### Expanded timeline records

![Timeline details](docs/screenshots/v1.2-time-flow-details.png)

### AI summary preview

![AI summary](docs/screenshots/v1.2-ai-summary.png)

### Appearance settings

![Theme, language and fonts](docs/screenshots/v1.2-appearance.png)

The owner selected these screenshots to show the current Windows interface. The wallpaper is user-selected and is not bundled as a default.

## Download

Get `TimeTrace-v1.2.0-preview.1-windows-x64.zip` from the [preview release](https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1), extract the complete archive and run `Release/timetrace_app.exe`. Windows 10 / 11 x64.

Exit the old version and back up your records before updating. Do not run multiple recording instances. Windows file properties still report the older `1.0.1`; identify this preview by its release tag and archive name.

There is no new macOS build in this release. Historical macOS packages do not validate the current interface.

## Privacy

Basic activity records and journals are stored locally, without requiring an account. When enabled and triggered, AI summaries send necessary content to your configured model service, subject to its privacy policy and pricing. Statistics and local journaling work without AI. Poetry may access a public service, so this is not a completely offline application.

Databases, journal images, executable paths and window titles may contain private information. Back them up and do not include keys or private records in issue reports.

## Source and build

This preview was developed from an earlier baseline. Use [release/v1.2.0-preview.1](https://github.com/wellorbetter/timetrace/tree/release/v1.2.0-preview.1) or its corresponding tag, rather than assuming main contains this interface.

Windows builds require Flutter, Rust and Visual Studio with Desktop development with C++:

```powershell
git switch release/v1.2.0-preview.1
cd app
flutter pub get
flutter build windows --release --no-tree-shake-icons
```

Run `flutter analyze`, `flutter test` and the relevant Rust tests for diagnostics. Test import errors remain in the preview; a successful release build is not evidence of a complete passing regression suite.

| Module | Responsibility |
| --- | --- |
| `crates/core` | Activity tracking and SQLite storage |
| `bridge` | Rust / Flutter bindings |
| `app` | Flutter desktop interface |

## License

[MIT](LICENSE). Third-party components retain their licenses. The personal wallpaper shown in screenshots is not distributed as a reusable default asset.
