# TimeTrace 优化调研与实施方案（2026-08-05）

## 一、调研结论

### 1.1 当前实现（exe 实测 + 代码审查）

| 维度 | 现状 | 证据 |
|---|---|---|
| 监控 | WinEventHook（前台切换/标题变化，500ms 节流）+ 1s 轮询兜底 | monitor.rs |
| 空闲 | GetLastInputInfo 阈值 5 分钟，超时才置 __IDLE__ | idle_win32.rs |
| 睡眠 | 轮询 gap > 5×poll 即重置内存会话，但不关闭 DB 中的会话 | monitor.rs |
| 锁屏 | 前台变为 LockApp -> 归一化为「系统」，不算空闲 | app_identity.rs |
| 图标 | SHGetFileInfoW/ExtractIconExW 提取，但 clean_exe_path() 有截断 bug | api.rs |
| 仪表盘 | 每 2s 全量刷新（多次 FFI + SQL），隐藏到托盘也照刷 | dashboard_provider.dart |
| 会话记录 | 秒级抖动会话大量产生（1~3s），睡眠时长被误记到睡前应用 | time.db 实测 |

### 1.2 实测数据问题（time.db，2026-08-05）
- 今日「系统」52,009s ≈ 14.4h —— 锁屏 + 睡眠被误记为活跃「系统」。
- 今日空闲会话仅 5 条/1,907s —— 空闲几乎只在桌面待机触发，锁屏/睡眠完全没进空闲。
- 短会话噪音：英雄联盟/终端/资源管理器/timetrace_app 交替出现 1~3s 会话。
- app.log 反复出现 icon NULL：Edge / Code / WindowsTerminal / PowerPoint / Clash Verge / Razer 等所有带空格路径的 exe 全部提取失败。

### 1.3 市场同类实现对照
- RescueTime：空闲 5 分钟计时器；超过阈值后把宽限的 5 分钟从应用活跃中扣除；其 Linux 版锁屏误记问题与当前实现相同（macOS 版锁屏即算离开）。
- ActivityWatch (aw-watcher-afk)：键盘/鼠标无输入 3 分钟 -> AFK；macOS 上锁屏/睡眠直接置 AFK。
- ManicTime：默认 10 分钟无输入 -> Away；解锁后立即展示 Away 视图。
- 共识：锁屏/睡眠应立即视为离开，空闲宽限期不应计入任何应用。

## 二、产品与架构方案（8 项需求 -> 9 个任务）

| # | 需求 | 根因 | 方案 | 归属 |
|---|---|---|---|---|
| 1 | 图标缺失 | clean_exe_path() 对含空格未加引号路径截断 | 修复路径解析（引号感知，空格合法）；Dart 侧加失败黑名单缓存，避免反复 FFI | Rust + Flutter |
| 2 | 空闲/锁屏/睡眠统计 | 锁屏不算空闲；睡眠 gap 不关 DB 会话，睡眠时长记到睡前应用；宽限期计入应用 | 锁屏/屏保立即 Idle（grace=0）；输入空闲宽限 grace=threshold，IdleStarted 用 now-grace 关上一会话；睡眠 gap 发 GapDetected{ts} 按 ts 关会话 | Rust |
| 3 | 某小时时间占比 | 无按小时维度 API/UI | 新增 get_hour_apps(date,hour) + get_app_hourly(app,date)；UI 新增「时段」轮播页（24h 分布 + 点击小时看 App 占比），应用详情加小时分布 | Rust + Flutter |
| 4 | 柱状图字体小、名字截断 | fontSize 8~9，名字硬截 5 字符 | 字号 10~11，FittedBox 完整名/两行，窄屏 6 根，tabular figures | Flutter |
| 5 | 饼图缩小与分割线/图例重叠 | PieChartCard 固定 160×160，Column 高度不足时溢出 | LayoutBuilder 响应式直径 = min(160, 可用高-图例高)，图例行高 22->18，防溢出 | Flutter |
| 6 | 日记编辑器无输入时蓝色块 | 容器 surfaceContainerLow 蓝灰 + 状态 chip 常驻 primaryContainer 蓝 | 空闲态中性容器+细边框，状态 chip 用中性色，聚焦/输入才有主色强调 | Flutter |
| 7 | 统计精度 | 睡眠误记、宽限期误记、事件时间戳未用 | 见 #2；会话开/关统一用事件时间戳；时长 clamp>=0 | Rust |
| 8 | 空间优化 | 轮播高度固定 330/400/360，图例/内边距偏大 | 响应式高度 + 紧凑图例/内边距，窄屏适配 | Flutter |
| 9 | 时间/功耗 | 1s 轮询 + 2s 全量刷新 + 隐藏时照刷 | 轮询默认 3s；空闲时跳过窗口解析；去掉无用 Heartbeat；仪表盘可见时才刷（10s 周期），隐藏暂停 | Rust + Flutter |

## 三、架构改动点

### Rust 核心（crates/core + bridge）
- contracts/events.rs：IdleStarted 增加 grace: Duration；新增 GapDetected { timestamp }。
- engine/monitor.rs：锁屏/屏保识别（lockapp/logonui/*.scr）-> 立即空闲；gap 检测发送 GapDetected；空闲态跳过窗口解析；删除 heartbeat 发送。
- engine/aggregator.rs：全部会话开/关改用事件时间戳；IdleStarted 用 ts-grace 关上一会话、以 ts-grace 开空闲会话；GapDetected 按 ts 关闭悬空会话。
- storage：新增 get_hour_apps(date,hour)、get_app_hourly(app,date)（复用跨小时拆分逻辑）；MemoryStore 补桩。
- bridge/src/api.rs：修复 clean_exe_path；暴露两个小时维度 API。
- config.rs：默认 poll 1000 -> 3000ms。
- 测试：补齐 clean_exe_path / 跨小时拆分 / gap 关闭用例；原有 13 测试保持通过。

### Flutter 前端（app/）
- dashboard_screen.dart：轮播高度自适应；刷新策略改为可见时 10s、隐藏暂停。
- app_chart_section.dart：字号/完整名/窄屏 6 根。
- pie_chart_card.dart：LayoutBuilder 响应式直径 + 紧凑图例。
- markdown_diary_editor.dart：空闲态中性化。
- app_icon.dart：失败黑名单缓存 + 重试。
- 新增 hourly_chart_card.dart：「时段」轮播页（24h 柱状 + 点击小时显示该小时 App 占比）。
- 应用详情（app_list_tile / app_list_section）增加每小时分布。

## 四、验证标准（用户要求全部通过）
1. 图标：启动后 app.log 无 icon NULL；列表出现真实图标。
2. 空闲：锁屏后该段时间归 __IDLE__，不再累计到「系统」；睡眠时间不记入任何应用。
3. 小时占比：时段页可选择小时查看 App 占比。
4. 柱状图：字号 >=10、名字完整可读。
5. 饼图：任意窗口宽度下不重叠。
6. 日记：无输入时无蓝色块。
7. 精度：睡眠/宽限期不再误记。
8. 空间：无溢出、布局紧凑。
9. 功耗：cargo test 全过；Flutter analyze 0 error 0 warning；运行 CPU 明显下降。
