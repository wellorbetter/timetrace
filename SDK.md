# TimeTrace Core SDK

The Rust core is packaged as a reusable SDK library with a **minimal public API** —
consumers interact only through the `TimeTraceApi` contract, never touching internals.

## Public API (the entire surface)

```
timetrace-core (lib)          — pure Rust, no UI, no network
├── contracts/                — 7 traits (the SDK interface)
│   ├── EventSource/EventSink — monitoring event stream
│   ├── DataStore             — storage + queries + diary
│   ├── ProcessQuery          — process list/kill
│   ├── StartupScanner        — startup entries
│   ├── IdleDetector          — away detection
│   └── WindowResolver        — foreground window
├── engine/                   — Win32 implementations (internal)
└── storage/                  — SQLite (internal)

timetrace-bridge (cdylib)     — FFI boundary for Flutter via flutter_rust_bridge
└── TimeTraceApi              — the ONLY entry point the UI uses
    ├── getDashboardData(start, end)
    ├── getDayDetail(date) / getDayHourly(date)
    ├── getWindowTitles(app, date)      ← Edge → bilibili pages
    ├── getDiaryEntries / setDiary / addDiaryImage
    ├── getStartupEntries / toggleStartup
    ├── getAppIcon(exe) / resolveExePath
    ├── getStats / getWeekTotals / exportCsv
    ├── setConfig / clearData / getUsageSplit
    └── setTrackingPaused
```

## Design rules (minimal external interaction)

1. **UI → bridge → core**, one direction. UI never calls engine/storage directly.
2. All methods are synchronous (`#[frb(sync)]`) — local SQLite, no async latency.
3. Errors return `Result<(), anyhow::Error>`; UI shows them, core logs them.
4. State (monitor handle, pause flag) is owned by `TimeTraceApi`, never exposed.
5. Dates are passed as `"YYYY-MM-DD"` strings — no timezone leakage across FFI.

## Embedding in other apps

```rust
// Rust host
let api = timetrace_core::AppConfig::load();
let db = SqliteStore::open(path)?;
let sink = Box::new(SessionAggregator::new(Arc::new(db.clone())));
run_monitor_loop(Win32WindowResolver, Win32IdleDetector::new(), poll, idle, sink);
```

```dart
// Flutter host
await RustLib.init(externalLibrary: ExternalLibrary.open('timetrace_bridge.dll'));
initializeApi(dbPath: '$apdata\\TimeTrace\\time.db');
final data = Api.instance.getDashboardData(start: s, end: e);
```
