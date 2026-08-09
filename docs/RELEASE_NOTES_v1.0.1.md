# TimeTrace v1.0.1

这是对既有 v1.0.0 的稳定性、设置体验与 Windows 发布包的补丁版本。

## 修复

- 修复排除应用、轮询间隔单位、数据目录、版本显示和 CSV 转义问题。
- 为数据库读取、监控线程和窗口事件增加降级/生命周期处理。
- 修复 workspace 构建、重复应用名归一化和无效死代码问题。
- CI 现在覆盖 Rust workspace、Flutter analyze/test 与 Windows 构建。

## 新增

- 设置项持久化：主题、字体、语言、背景透明度、仪表盘顺序、启动与监控偏好。
- 开机启动与启动最小化设置；排除应用支持运行中进程搜索、图标和手动添加。
- Windows x64 ZIP 发布包内置 MSVC 运行库，解压后可直接启动。

## 验证

```text
cargo test --workspace
flutter analyze --no-fatal-infos
flutter test
```

下载 ZIP 后请解压整个目录，再运行 `timetrace_app.exe`。
