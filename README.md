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

<p align="center">
  <a href="#下载">下载</a> ·
  <a href="#界面导览">界面导览</a> ·
  <a href="#ai-日记与隐私边界">AI 与隐私</a> ·
  <a href="#从源码构建">源码构建</a>
</p>

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

## 界面导览

### 一个日历，五种使用视图

选中日期后，右侧轮播会同步切换应用柱状图（页首主图）、使用占比、当日汇总、应用明细与 24 小时时段分布；不需要在多个页面之间来回跳转。

| 使用占比 | 当日汇总 |
| --- | --- |
| ![应用使用占比](docs/screenshots/v1.1-share.png) | ![当日活跃汇总](docs/screenshots/v1.1-daily-summary.png) |
| 应用明细 | 24 小时时段分布 |
| ![应用列表与时长](docs/screenshots/v1.1-app-list.png) | ![分时使用情况](docs/screenshots/v1.1-hourly.png) |

### 使用事实旁边，就是当天的日记

概览向下滚动即可写 Markdown 日记、添加图片，或让 AI 根据当天的真实使用事实生成一篇可编辑的日记；AI 内容会标记模型来源，不会冒充手写内容。

![日记编辑与 AI 生成日记](docs/screenshots/v1.1-ai-diary.png)

### 从外观到概览顺序都由你决定

| 主题、字体、背景与透明度 | 轮播模块开关与排序 |
| --- | --- |
| ![外观与背景设置](docs/screenshots/v1.1-appearance.png) | ![概览布局设置](docs/screenshots/v1.1-layout.png) |

### AI 不是黑盒开关

模型 Endpoint、模型名、API Key 环境变量、写作语气、是否反思、是否给建议、是否参考既有日记，以及手动/定时生成都可以独立控制。

| 模型服务与连接检查 | 写作要求与生成方式 |
| --- | --- |
| ![AI 模型设置](docs/screenshots/v1.1-ai-settings.png) | ![AI 写作与定时设置](docs/screenshots/v1.1-ai-writing.png) |

### 后台记录与数据仍在你手里

| 轮询、空闲阈值、托盘与开机启动 | 数据目录、导出与清除 |
| --- | --- |
| ![监控与后台行为设置](docs/screenshots/v1.1-monitoring.png) | ![本地数据管理（用户名已打码）](docs/screenshots/v1.1-data-redacted.png) |

## AI 日记与隐私边界

AI 日记默认关闭。关闭时不会连接模型服务，也不会发送使用记录或日记正文。

开启并生成时，TimeTrace 会把所选日期的必要使用事实发送到你配置的模型 Endpoint，包括聚合活跃/空闲时长、会话数量、切换次数、峰值时段、主要应用和有限的使用历史。窗口标题、文件路径和原始事件不会进入 AI 请求；已有日记正文默认也不发送，只有你单独开启“允许参考已有日记”后才会包含。

API Key 由你指定的系统环境变量提供，TimeTrace 只保存环境变量名，不保存密钥内容。连接测试只验证模型服务，不发送 TimeTrace 数据。使用第三方模型服务时，仍需遵守该服务商的隐私政策和计费规则。

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
