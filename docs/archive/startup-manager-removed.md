# 废案：自启动管理（Startup Manager）— 2026-08 移除

> 状态：**已移除**（v1.0.x）。本文件为技术档案，记录该功能的完整实现与移除原因，
> 便于未来按需恢复。

## 功能简介

Windows 自启动项管理：扫描、禁用、启用系统启动项。

- 扫描范围：注册表（HKCU/HKLM Run 键）、启动文件夹（%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup）、计划任务（schtasks）
- 每个启动项展示：名称、命令、来源位置、图标（SHGetFileInfoW 提取 exe 图标）
- 操作：启用 / 禁用（registry 删除/写入值；文件夹移入/移出 `StartupDisabled` 子目录；计划任务 `schtasks /Change /DISABLE`）
- UI：`启动` 导航页（NavigationRail）→ 启动项列表卡片，开关切换

## 架构（三层）

```
┌─ Flutter UI ─────────────────────────────────────────────┐
│ features/startup/presentation/startup_screen.dart        │
│ features/startup/presentation/widgets/startup_tile.dart  │
│ features/startup/providers/startup_provider.dart         │
│   ↓ 桥接（flutter_rust_bridge, 同步方法）                 │
├─ bridge ────────────────────────────────────────────────┤
│ getStartupEntries() -> Vec<StartupDto>                   │
│ setStartupEnabled(path, enabled) -> Result<()>           │
│   ↓                                                      │
├─ Rust core ─────────────────────────────────────────────┤
│ contracts/startup.rs : StartupScanner trait              │
│   - scan() -> Vec<StartupEntry>                          │
│   - set_enabled(path, enabled) -> Result<()>             │
│ engine/startup_win32.rs : StartupScannerWin32            │
│   - 注册表: HKCU\Software\Microsoft\Windows\CurrentVersion\Run
│   - 文件夹: 启动目录扫描 .lnk/.exe
│   - 计划任务: schtasks /query /fo csv /v 解析
│ storage/sqlite.rs : startup_entries 表（缓存扫描结果）     │
└──────────────────────────────────────────────────────────┘
```

### 关键实现细节（startup_win32.rs）

1. **注册表**：
   - 枚举 `HKCU\...\Run` 与 `HKLM\...\Run` 的值
   - 命令形如 `"C:\path\app.exe" --flag`，resolve 可执行路径后提取图标
2. **启动文件夹**：
   - 扫描 `%APPDATA%\...\Startup\*.lnk`（快捷方式）
   - 禁用 = 移动到 `StartupDisabled` 子目录；启用 = 移回
3. **计划任务**：
   - `schtasks /Query /FO CSV /V` 解析 CSV 输出（编码 GBK → UTF-8 转换）
   - 禁用 = `schtasks /Change /TN <name> /DISABLE`
4. **图标提取**（contracts/process.rs + engine/process_sysinfo.rs）：
   - `SHGetFileInfoW` 主路径 → 失败回退 `ExtractIconExW`
   - 图标经 RGBA 转码为 `IconDto` 传给 Flutter 渲染

## 移除原因（产品决策）

1. **功能聚合过宽**：TimeTrace 定位是"本地隐私优先的时间追踪 + 日历日记"，
   自启动管理属于系统工具范畴，与核心价值无关，会稀释产品认知。
2. **维护成本**：schtasks 解析、快捷方式移动等边界情况多（权限、UAC、重定向），
   与主产品线无关的代码不值得长期维护。
3. **页面结构重构**：仪表盘改为"概览 / 日历日记"双 Tab 后，导航只保留
   仪表盘 + 设置，去掉第三个导航入口。

## 恢复指南（如需重新启用）

1. **Flutter 侧**：`git show <commit>:app/lib/src/features/startup/...` 找回三个文件
   （screen / tile / provider），重新注册 `GoRoute('/startup')` + NavigationRail 项。
2. **Rust/bridge 侧**：`getStartupEntries` / `setStartupEnabled` 仍保留在
   `bridge/src/api.rs` 与 `crates/core/src/engine/startup_win32.rs`（未被删除，
   仅为休眠 API），重新接入 UI 即可，无需重写 Rust 逻辑。
3. **数据库**：`startup_entries` 表仍存在（schema.rs），缓存逻辑可复用。

## 相关文件（移除时点状态）

| 文件 | 处置 |
|---|---|
| app/lib/src/features/startup/presentation/startup_screen.dart | 已删除 |
| app/lib/src/features/startup/presentation/widgets/startup_tile.dart | 已删除 |
| app/lib/src/features/startup/providers/startup_provider.dart | 已删除 |
| app/lib/src/core/router/app_router.dart（自启动路由+导航项） | 已修改 |
| bridge/src/api.rs（StartupDto / getStartupEntries / setStartupEnabled） | 保留（休眠） |
| crates/core/src/contracts/startup.rs | 保留（休眠） |
| crates/core/src/engine/startup_win32.rs | 保留（休眠） |
| crates/core/src/storage/sqlite.rs（startup_entries） | 保留（休眠） |

## 移除提交

- commit `2fb95cc` 之后，本次"双 Tab + 去自启动"改动提交（见 git log）。
