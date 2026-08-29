<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  本地优先的桌面使用统计 + 日记应用
  <br>
  <b>Rust</b> 核心 + <b>Flutter</b> UI · 数据留在本机，无账号、无云端、无遥测
</p>

<p align="center">
  <a href="README_EN.md">English</a>
  ·
  <a href="https://github.com/wellorbetter/timetrace/releases">
    <img src="https://img.shields.io/github/v/release/wellorbetter/timetrace" alt="Release">
  </a>
  ·
  <img src="https://github.com/wellorbetter/timetrace/actions/workflows/ci.yml/badge.svg" alt="CI">
</p>

---

## 为什么是 TimeTrace

TimeTrace 把「电脑今天都花在了哪里」和「今天做了什么」放进同一条本地时间线：自动统计前台应用活跃时间，再用日历、图表、AI Recap 风格回顾和日记把一天串起来。核心数据保存在本机 SQLite，不需要登录，也不会把活动记录上传到云端。

## 功能特性

- **使用统计** — 自动记录前台应用活跃时长；识别空闲、锁屏与睡眠，避免把离开电脑的时间算进去
- **AI Recap 风格回顾** — 按应用与 Session 汇总一天的使用情况，生成洞察和时间分配视图
- **数据仪表盘** — 柱状图 / 饼图 / 24h 时段分布 / 当日汇总 / 应用分布轮播，与日历联动
- **日记** — 朋友圈式日记：Markdown 编辑、图片相册、草稿自动保存、按天分组折叠
- **系统集成** — 前台应用与图标识别、系统托盘、开机启动、启动最小化
- **个性化** — 排除应用、监控参数、主题/字体/背景、透明度与仪表盘顺序均可配置并持久化

## 演示与截图

CI 会在桌面验收时真实启动应用并生成 Windows / macOS / Ubuntu walkthrough artifact；macOS 另外保留确定性的 Flutter render-tree Demo，用于避免系统录屏权限导致“有文件但没有可用画面”的假成功。

| | |
| --- | --- |
| ![柱状图](docs/screenshots/dashboard-bar.png) | ![饼图](docs/screenshots/dashboard-pie.png) |
| ![当日汇总](docs/screenshots/dashboard-summary.png) | ![应用分布](docs/screenshots/dashboard-apps.png) |
| ![时段分布](docs/screenshots/dashboard-hourly.png) | |

支持本地背景图片、透明度调节，以及带背景效果的仪表盘和设置页：

![使用统计与背景效果](docs/screenshots/background-dashboard.png)

![设置页与背景透明度](docs/screenshots/background-settings.png)

## 平台状态

| 平台 | 状态 | 当前验收范围 |
| --- | --- | --- |
| Windows 10/11 | ✅ 主发布平台 | Release 构建、前台窗口/空闲检测、托盘、完整桌面验收 |
| macOS | 🧪 桌面验收中 | 原生 Release 构建、Rust bridge、托盘、真实窗口启动与录制验收 |
| Ubuntu X11 / XWayland | 🧪 桌面验收中 | 原生 Release bundle、前台窗口/空闲检测、托盘、Xvfb walkthrough |
| 原生 Wayland | ⚠️ 有限制 | 全局前台活动观察依赖 compositor / 权限模型，当前不宣称完整支持 |

> Release 页面当前仍以 Windows 安装包为主；macOS / Linux 状态以 CI 桌面验收结果为准。

## 技术栈

| 模块 | 说明 |
| --- | --- |
| `crates/core` | Rust 核心：平台活动/空闲检测、Session 聚合、SQLite 存储 |
| `bridge` | `flutter_rust_bridge` 跨语言绑定 |
| `app/` | Flutter UI：Riverpod 3 + Material 3，多桌面平台界面 |
| `.github/workflows` | Rust / Flutter CI + Windows / macOS / Ubuntu 原生桌面验收与 Demo 录制 |

## 构建与验证

### 通用要求

- Flutter SDK（stable）
- Rust stable 工具链
- 对应平台的 Flutter desktop toolchain

### 常用命令

```bash
# Rust workspace
cargo test --workspace

# Flutter 静态分析与测试
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

需要 Visual Studio 2022「使用 C++ 的桌面开发」工作负载。

### macOS

```bash
./scripts/build_macos.sh
```

### Ubuntu

```bash
./scripts/build_linux.sh
```

Linux 当前的活动跟踪验收目标是 X11 / XWayland；纯 Wayland 的全局窗口观察受桌面环境权限限制。

## 下载

- 最新版本：<https://github.com/wellorbetter/timetrace/releases>
- Windows：下载 `TimeTrace-vX.Y.Z-windows-x64.zip`，解压后运行 `timetrace_app.exe`，无需安装。

## 隐私

活动记录、设置和日记均保存在本机。Windows 默认数据库位置为 `%APPDATA%\TimeTrace\time.db`；macOS / Linux 使用各自平台的应用数据目录。TimeTrace 不要求账号，也不包含遥测上传。

## License

[MIT](LICENSE)
