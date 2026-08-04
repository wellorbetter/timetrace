# TimeTrace — 项目工作流指南

Windows 桌面应用：Rust 核心（前台应用监控/统计/日记存储）+ Flutter UI。
**隐私优先，100% 本地**，SQLite 存储，无网络无遥测。

## 仓库结构
```
crates/core/   Rust 核心：contracts(7个trait) + engine(Win32实现) + storage(SQLite)
bridge/        flutter_rust_bridge 桥：TimeTraceApi（~30 同步方法）
app/           Flutter 前端（feature-first + Riverpod 3 + GoRouter）
  lib/src/features/{dashboard,calendar,settings}/
  lib/src/core/{widgets,theme,router,responsive,format}/
  lib/src/bridge/  ← FRB codegen 产物（api.dart / frb_generated.dart）
tools/         构建脚本 + 迁移用 python 脚本
docs/          产品/设计/归档文档
```

## 构建流程（关键！）

### Rust 核心改动后（改 crates/core 或 bridge/api.rs）
1. `cd /mnt/i/Github/pr/timetrace && /mnt/c/Users/wellorbetter/.cargo/bin/cargo.exe test -p timetrace-core --lib`（13 测试必须过）
2. `cargo.exe build -p timetrace-bridge --release` → 产出 `target/release/timetrace_bridge.dll`
3. 如果改了 `bridge/src/api.rs` 的公开 API → 必须跑 FRB codegen：
   `/mnt/c/Users/wellorbetter/.cargo/bin/flutter_rust_bridge_codegen.exe generate --config-file frb.yaml`
   （frb.yaml 用 `\\?\` verbatim 路径；codegen 会重写 app/lib/src/bridge/api.dart + frb_generated.rs）

### Flutter 改动后（app/ 下 .dart）
1. `cmd.exe /c "cd /d I:\Github\pr\timetrace\app && D:\flutter\bin\flutter.bat analyze"` → 必须 0 error
2. 构建 release：
   `cmd /c "cd /d I:\Github\pr\timetrace\app && powershell -NoProfile -ExecutionPolicy Bypass -File C:/tools/flutter_vcvars.ps1 build windows --release"`
   （flutter_vcvars.ps1 注入 vcvars + fake VS 环境 + 19041 SDK + Ninja —— 本机 VS 是坏的，必须走这个脚本）
3. AOT 组装（flutter build 只产 kernel_blob，要手动 assemble）：
   `powershell -File C:/tools/flutter_vcvars.ps1 assemble -dBuildMode=release -dTargetPlatform=windows-x64 --output=build/windows/x64/runner/data aot_elf_release`
4. 手动组装 data/（每次都要）：
   ```
   mkdir -p build/windows/x64/runner/data/flutter_assets
   cp -r build/flutter_assets/* build/windows/x64/runner/data/flutter_assets/
   cp .dart_tool/flutter_build/902233d607dfad73835daeff29a06bbb/app.so build/windows/x64/runner/data/app.so
   cp /mnt/d/flutter/bin/cache/artifacts/engine/windows-x64/icudtl.dat build/windows/x64/runner/data/icudtl.dat
   cp /mnt/d/flutter/bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll build/windows/x64/runner/flutter_windows.dll
   cp /mnt/i/Github/pr/timetrace/target/release/timetrace_bridge.dll build/windows/x64/runner/timetrace_bridge.dll
   ```
5. 启动验证：`cd build/windows/x64/runner && start timetrace_app.exe`，查日志：
   - `C:\Users\wellorbetter\AppData\Roaming\TimeTrace\app.log`（Flutter 错误）
   - `...\timetrace.log`（Rust）
   - 检查最新运行无 "FLUTTER ERROR" / "API init FAILED"

### 坑
- 构建失败常见原因：旧进程锁文件 → 先 `taskkill /f /im timetrace_app.exe`，删 `build/windows .dart_tool/flutter_build` 再构建
- app.so 目录 hash（902233d...）在删除 .dart_tool 后会变 — 用 `ls .dart_tool/flutter_build/*/app.so` 找
- DB 在 `%APPDATA%\TimeTrace\time.db`（WAL 模式，数据可能在 time.db-wal）
- 修改 Rust schema → 必须加迁移（schema.rs MIGRATIONS_* + sqlite.rs run_migrations 守卫），旧库不能崩

## 测试
- Rust: `cargo.exe test -p timetrace-core --lib`（13 个，storage 相关）
- Flutter: `flutter.bat analyze` 0 error 0 warning
- 手动冒烟：启动 app 看仪表盘/日历/日记/设置

## 产品要点
- 仪表盘：单页纵向（范围chips → 数据轮播[柱状图/饼图/汇总/应用] → 日历[左] → 应用分布 → 日记）
- 日记：朋友圈式（按天分组可折叠、条目内联编辑、草稿/已发布 status、图片相册堆叠+全屏画廊）
- 监控：SetWinEventHook 事件驱动（前台 + 标题变化）+ 轮询兜底；应用名归一化（msedge→Edge、java→父目录、标题关键词兜底）
- 提交习惯：中文 commit，一个逻辑改动一个 commit
