<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  本地优先的桌面使用追踪与日记应用
  <br>
  <b>Rust</b> 核心 + <b>Flutter</b> UI · 默认离线 · AI 可选开启
</p>

<p align="center">
  <a href="README_EN.md">English</a>
  ·
  <a href="https://github.com/wellorbetter/timetrace/releases">
    <img src="https://img.shields.io/github/v/release/wellorbetter/timetrace" alt="Release">
  </a>
  ·
  <img src="https://github.com/wellorbetter/timetrace/actions/workflows/ci.yml/badge.svg" alt="CI">
  ·
  <a href="LICENSE"><img src="https://img.shields.io/github/license/wellorbetter/timetrace" alt="MIT License"></a>
</p>

![TimeTrace v1.1 概览](docs/screenshots/v1.1-overview.png)

TimeTrace 自动记录前台应用与活跃时长，把日历、图表、应用明细和日记放在一个桌面工作区里。记录默认只保存在你的电脑上；AI 日记是明确选择后才启用的可选功能。

## 下载

前往 [GitHub Releases](https://github.com/wellorbetter/timetrace/releases/latest) 下载最新版本。

| 平台 | 状态 | 使用方式 |
| --- | --- | --- |
| Windows 10/11 x64 | 稳定支持 | 下载 `TimeTrace-vX.Y.Z-windows-x64.zip`，完整解压后运行 `timetrace_app.exe` |
| macOS | 自用预览 | 下载 `TimeTrace-vX.Y.Z-macos.zip`，解压后运行 `Install TimeTrace.command`；当前未经过 Apple notarization |

## 功能

- **自动追踪** — 记录前台应用、窗口标题和活跃时长；识别空闲、锁屏与睡眠，避免把离开时间算作使用时间
- **日历与概览** — 柱状图、饼图、24 小时时段分布、当日汇总、应用排行和历史明细与日历联动
- **本地日记** — Markdown 编辑、图片相册、草稿保存、按日期整理，并与当天的真实使用记录放在一起
- **AI 日记（可选）** — 支持 DeepSeek 与 OpenAI-compatible Chat Completions；可自定义模型、Endpoint、写作要求与每日生成时间
- **桌面体验** — 系统托盘、开机启动、启动最小化、排除应用、浅色/深色主题、字体、背景和概览布局均可配置
- **数据控制** — 自定义数据库目录，导出 CSV，随时暂停记录或清除全部本地数据

## AI 日记与隐私边界

AI 日记默认关闭。关闭时不会连接模型服务，也不会发送使用记录或日记正文。

开启并生成时，TimeTrace 会把所选日期的必要使用事实发送到你配置的模型 Endpoint，包括聚合活跃/空闲时长、会话数量、切换次数、峰值时段、主要应用和有限的使用历史。窗口标题、文件路径和原始事件不会进入 AI 请求；已有日记正文默认也不发送，只有你单独开启“允许参考已有日记”后才会包含。

API Key 由你指定的系统环境变量提供，TimeTrace 只保存环境变量名，不保存密钥内容。连接测试只验证模型服务，不发送 TimeTrace 数据。使用第三方模型服务时，仍需遵守该服务商的隐私政策和计费规则。

| AI 日记 | AI 设置 |
| --- | --- |
| ![AI 生成日记](docs/screenshots/v1.1-ai-diary.png) | ![AI 日记设置](docs/screenshots/v1.1-ai-settings.png) |

## 本地数据

TimeTrace 的 SQLite 数据库可能包含应用名称、可执行文件路径、窗口标题、使用会话以及你写入的日记。默认位置：

- Windows：`%APPDATA%\TimeTrace\time.db`
- macOS：`~/Library/Application Support/TimeTrace/time.db`

这些本地数据不会因为安装或启动 TimeTrace 自动上传。请把数据库和日记图片视为私人数据并妥善备份。

## 从源码构建

### Windows

环境：Flutter stable、Rust stable、Visual Studio 2022（含“使用 C++ 的桌面开发”）。

```powershell
cargo test --workspace
cd app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build windows --release
```

### macOS

环境：Flutter stable、Rust stable、Xcode Command Line Tools。

```bash
cargo test -p timetrace-core -p timetrace-bridge
chmod +x scripts/build_macos.sh
./scripts/build_macos.sh
```

## 架构

| 模块 | 说明 |
| --- | --- |
| `crates/core` | 跨平台追踪、空闲检测、会话聚合与 SQLite 存储 |
| `bridge` | `flutter_rust_bridge` 跨语言绑定 |
| `app/` | Flutter 桌面 UI（Riverpod + Material 3） |

## License

[MIT](LICENSE)
