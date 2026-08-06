# TimeTrace

> 本地优先的 Windows 使用统计 + 日记应用
> Local-first Windows time tracking & journal app

**Rust 核心 + Flutter UI · 100% 本地运行，无网络、无遥测**
**Rust core + Flutter UI · 100% local, no network, no telemetry**

使用统计 · 应用图标 · 数据仪表盘 · 日记
Usage stats · App icons · Data dashboard · Journal

---

## 功能 / Features

- **使用统计 / Usage stats** — 自动记录前台应用活跃时长；自动识别空闲、锁屏与睡眠，不计入活跃时间。
- **应用图标 / App icons** — 实时识别前台应用与图标；系统托盘常驻，右键菜单快速控制。
- **数据仪表盘 / Dashboard** — 柱状图、饼图、24h 时段分布、当日汇总、应用分布轮播，与日历联动。
- **日记 / Journal** — 朋友圈式日记：Markdown 编辑、图片相册、草稿自动保存、按天分组折叠。
- **设置 / Settings** — 空闲阈值、开机启动等可配置。

## 技术栈 / Tech Stack

| 模块 | 说明 |
| --- | --- |
| `crates/core` | Rust 核心：Win32 事件钩子监控、空闲/睡眠检测、SQLite 存储 |
| `bridge` | flutter_rust_bridge 跨语言绑定 |
| `app/` | Flutter UI：Riverpod 3 + Material 3，Windows 桌面 |

## 截图 / Screenshots

| 仪表盘 Dashboard | 日记 Journal |
| --- | --- |
| ![dashboard](docs/screenshots/dashboard.png) | ![journal](docs/screenshots/journal.png) |

> 截图待补充。如何添加截图：见 [docs/screenshots/README.md](docs/screenshots/README.md)。

## 构建 / Build

```bash
# Rust 核心测试
cargo test -p timetrace-core --lib

# Flutter 静态分析（0 error）
cd app && flutter analyze

# Windows Release 构建
cd app && flutter build windows --release
```

## 开发过程 / How It Was Built

全程 vibe coding：前期用 DeepSeek V4 Flash + Pi 快速搭出原型，后期切换到 Codex 持续做性能与交互优化。
Vibe-coded end to end: prototyped with DeepSeek V4 Flash + Pi, then polished with Codex for performance and UX.

## 隐私 / Privacy

所有数据只保存在本地 SQLite（`%APPDATA%\TimeTrace\time.db`），不上传任何内容。
All data stays in local SQLite; nothing is uploaded.