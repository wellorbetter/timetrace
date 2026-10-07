<p align="center">
  <img src="app/assets/icon_preview.png" width="96" alt="TimeTrace">
</p>

<h1 align="center">TimeTrace</h1>

<p align="center">
  电脑使用统计 · 时间流 · 本地日记
  <br>
  <b>Rust</b> 核心 + <b>Flutter</b> 界面，记录本地保存，AI 总结可选。
</p>

<p align="center">
  <a href="https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1"><img src="https://img.shields.io/badge/Release-v1.2.0--preview.1-537A68?style=flat-square" alt="v1.2.0-preview.1"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?style=flat-square" alt="Windows 10 / 11">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-67716C?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="README_EN.md">English</a> ·
  <a href="#下载">下载</a> ·
  <a href="#界面导览">界面导览</a> ·
  <a href="#隐私">隐私</a> ·
  <a href="https://github.com/wellorbetter/timetrace/issues">反馈问题</a>
</p>

![TimeTrace 工作台](docs/screenshots/v1.2-workbench.png)

TimeTrace 是一款开源的电脑使用统计与日记工具。看看每天、每周、每月把时间花在哪些软件上，也可以查某个小时用了多久 LOL、浏览器用了多久。日历、图表和日记放在一个工作台里，需要时再展开具体记录。

## 下载

**[下载 Windows x64 预览版 →](https://github.com/wellorbetter/timetrace/releases/tag/v1.2.0-preview.1)**

完整解压 `TimeTrace-v1.2.0-preview.1-windows-x64.zip`，运行 `Release/timetrace_app.exe`。更新前退出旧版本并备份记录，不要同时运行多份记录进程。[查看所有版本](https://github.com/wellorbetter/timetrace/releases)。

> 当前为 Windows 预览版，还有一些 UI 细节和文件夹打开问题，预计后续修复。本次暂无新的 macOS 包。

## 这次更新

v1.2 主要重新整理了界面和工作台：日历、数据轮播与日记放在一起，组件可以调整布局；加入时间流，按时段回看使用记录。任务清单、番茄钟、倒计时和每日诗词也放进了组件里，计时记录通过小弹窗查看，背景、材质与设置入口也做了调整。

## 功能

- **使用统计** — 小时、日、周、月与自定义范围，查看应用时长和使用分布。
- **时间流** — 按时段回看应用，再展开查看具体的使用记录。
- **多种图表** — 柱状图、饼图、当日汇总、应用明细与时段分布，联动日历查看。
- **日记与 AI 总结** — 本地 Markdown 日记、图片，以及可选的 AI 总结。
- **工作台组件** — 调整布局，放入任务清单、番茄钟、倒计时和每日诗词。
- **桌面设置** — 背景、主题、字体、材质、托盘、开机启动与排除应用。

## 界面导览

### 按时间回看，也能展开细节

先看这一段用了什么，再查看具体应用与窗口记录。

| 时间流 | 展开的使用记录 |
| --- | --- |
| ![时间流](docs/screenshots/v1.2-time-flow.png) | ![时间流详情](docs/screenshots/v1.2-time-flow-details.png) |

### 一个日历，多种数据视图

选中日期后，数据视图跟着切换。页首展示应用时长，下方可以看当天汇总、应用明细和时段分布。

| 当天使用汇总 | 应用明细 |
| --- | --- |
| ![当天使用汇总](docs/screenshots/v1.2-usage-summary.png) | ![应用明细](docs/screenshots/v1.2-app-details.png) |

<details>
<summary>查看时段分布截图</summary>

![时段分布](docs/screenshots/v1.2-hourly.png)

</details>

### 整理一天，调整自己的界面

AI 总结是可选入口；不配置 AI，也可以使用统计与本地日记。主题、语言和字体按自己的习惯设置。

| AI 总结预览 | 外观设置 |
| --- | --- |
| ![AI 总结预览](docs/screenshots/v1.2-ai-summary.png) | ![外观设置](docs/screenshots/v1.2-appearance.png) |

<sub>截图由作者选定，背景是用户自行选择的图片，不是安装包的默认素材。</sub>

## 隐私

基础活动记录和日记保存在本地，不需要注册账号。启用并触发 AI 总结时，必要内容会发送到自己配置的模型服务，遵循该服务的隐私与计费规则。诗词可能访问公共接口，因此不将应用描述为完全离线。

数据库、日记图片、应用路径和窗口标题可能包含私人信息，请妥善备份；反馈时不要上传 Key 或私人记录。

## 开发

| 模块 | 职责 |
| --- | --- |
| `crates/core` | 应用监控、时间记录与 SQLite 存储 |
| `bridge` | Rust / Flutter 跨语言绑定 |
| `app` | Flutter 桌面界面 |

<details>
<summary>从源码构建 Windows 版</summary>

当前界面已合入 main。复现发布包请使用 [v1.2.0-preview.1 标签](https://github.com/wellorbetter/timetrace/tree/v1.2.0-preview.1)。需要 Flutter、Rust 和 Visual Studio 的“使用 C++ 的桌面开发”工具链。

```powershell
git switch --detach v1.2.0-preview.1
cd app
flutter pub get
flutter build windows --release --no-tree-shake-icons
```

</details>

前期使用 DeepSeek + Pi 搭出原型，后续通过 Codex 持续调整界面与交互。欢迎提 issue，也欢迎 Star。

## License

[MIT](LICENSE)。第三方组件保留各自许可；截图中的个人背景不作为可再分发的默认素材。
