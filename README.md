# TimeTrace

> One codebase. Two outputs. Zero duplication.
>
> `cargo build` → `tt.exe` (TUI) + `tt-gui.exe` (Desktop)

```
┌─────────────────────────────────────────────────┐
│              timetrace-core (lib)                │
│  contracts/ · engine/ · storage/ · config/      │
│  ┌───────────────────────────────────────────┐  │
│  │  7 traits · 4 Win32 impls · SQLite store  │  │
│  └───────────────┬───────────────────────────┘  │
│                  │                               │
│     ┌────────────┴────────────┐                 │
│     ▼                         ▼                 │
│  timetrace-tui (bin)    timetrace-gui (bin)      │
│  ratatui + crossterm     egui + eframe           │
│  → tt.exe                → tt-gui.exe            │
│  Terminal dashboard      Native window           │
└─────────────────────────────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/wellorbetter/timetrace.git
cd timetrace

# Build both
cargo build --release

# Terminal version
./target/release/tt

# Desktop version
./target/release/tt-gui
```

## Features

| Feature | TUI (`tt`) | GUI (`tt-gui`) |
|---------|------------|----------------|
| App usage tracking | ✅ | ✅ |
| Timeline + Top apps | ✅ | ✅ |
| Process list + kill | ✅ | ✅ |
| Startup manager | ✅ | ✅ |
| Keyboard-first | ✅ | — |
| System tray | 计划中 | ✅ |
| Adaptive colors | Season/day-night | System theme |
| Binary size | ~2 MB | ~4 MB |
| RAM (idle) | ~5 MB | ~15 MB |

## Architecture

```
crates/
├── core/          ← SHARED (contracts + engine + storage)
│   └── src/
│       ├── contracts/    7 traits, zero deps
│       ├── engine/       Win32 implementations
│       └── storage/      SQLite via rusqlite
│
├── tui/           ← TERMINAL (ratatui)
│   └── src/
│       ├── main.rs       Entry point
│       ├── app.rs        TUI app with 3 tabs
│       └── theme.rs      Adaptive color system
│
└── gui/           ← DESKTOP (egui)
    └── src/
        └── main.rs       Entry point + GUI app
```

## Keyboard Shortcuts (TUI)

| Key | Action |
|-----|--------|
| `1/2/3` | Switch tabs |
| `Tab` | Next tab |
| `q` | Quit |
| `Esc` | Close dialog |
| `k` | Kill process |
| `Space` | Toggle startup entry |

## License

MIT
