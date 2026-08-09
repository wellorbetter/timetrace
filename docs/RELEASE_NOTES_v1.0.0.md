# TimeTrace v1.0.0

## 修复

- 修复排除应用未生效、轮询单位显示错误、数据库路径和版本号显示不一致。
- 修复 CSV 字段未转义、页面访问时间偏差和监控句柄无法停止的问题。
- 为数据库读路径和常见锁异常增加降级处理，避免异常直接导致应用退出。
- 修复 `crates/gui` workspace 编译错误，并补齐 Rust/Flutter CI 检查。
- 清理未使用的 Heartbeat、未知应用构造器和重复的应用名归一化逻辑。

## 新增

- 设置页支持当前用户开机启动、启动时最小化、自动开始追踪和关闭窗口进托盘。
- 主题、语言、字体、背景、背景透明度和仪表盘顺序会持久化保存。
- 排除应用支持搜索运行中进程、多选、真实 exe 图标和手动添加。
- 数据库异常会在仪表盘显示可重试的降级提示。
- Release 包提供完整 Windows x64 可解压运行目录。

## 验证

- `cargo test --workspace`
- `cargo build --workspace`
- `flutter analyze --no-fatal-infos`
- `flutter test`
- `flutter build windows --release`

下载后解压整个目录，运行 `timetrace_app.exe`，不要单独复制 exe 文件。
