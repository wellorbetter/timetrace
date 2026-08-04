//! 应用识别与命名（Application Identity）。
//!
//! 纯逻辑、无 Win32 依赖，集中管理：
//! - `display_name_for`: 由 exe 路径 + 窗口标题推断友好应用名
//!   （普通 exe → 文件名；通用运行时 → 父目录；无意义目录 → 标题关键词）
//! - `normalize_app_name`: 已知进程变体合并（msedge/browser → Edge 等）
//! - `app_name_from_title`: 窗口标题关键词识别（Minecraft / IDEA / VS Code …）

/// 通用运行时 exe 名 —— 它们的文件名无意义，需要靠路径/标题区分。
const GENERIC_RUNTIMES: &[&str] = &[
    "java", "javaw", "javaws", "python", "pythonw", "python3", "node", "dotnet",
    "electron", "chrome", "ruby", "php", "go", "cargo",
];

/// 无意义的路径父目录 —— 遇到则继续向上找，最终回退标题关键词。
fn is_meaningless_dir(dir: &str) -> bool {
    let d = dir.to_lowercase();
    d == "bin"
        || d == "bin64"
        || d.starts_with("jre")
        || d.starts_with("jdk")
        || d.contains("runtime")
        || d == "openjdk"
        || d == "windowsapps"
}

/// 由 exe 路径 + 窗口标题推断显示名（策略链，与社区做法一致）：
///   1. exe 路径为空（权限/进程退出）→ 标题或「未知应用」（绝不暴露 pid）
///   2. 普通 exe → 文件名
///   3. 通用运行时 → 路径父目录（跳过 bin/jdk/jre 等无意义目录）
///   4. 都不可靠 → 窗口标题关键词（Minecraft 等）→ 运行时友好名兜底
pub fn display_name_for(exe_path: &str, title: &str) -> String {
    if exe_path.is_empty() {
        return app_name_from_title(title).unwrap_or_else(|| "未知应用".into());
    }
    let file = exe_path.rsplit('\\').next().unwrap_or(exe_path);
    let stem = file.trim_end_matches(".exe");
    let lower = stem.to_lowercase();

    if GENERIC_RUNTIMES.contains(&lower.as_str()) {
        let parts: Vec<&str> = exe_path.rsplit('\\').collect();
        for p in parts.iter().skip(1) {
            if !is_meaningless_dir(p) {
                return (*p).to_string();
            }
        }
        return app_name_from_title(title).unwrap_or_else(|| {
            if lower.starts_with("java") {
                "Java".into()
            } else {
                stem.into()
            }
        });
    }
    stem.to_string()
}

/// 窗口标题关键词识别（适用于通用运行时 + UWP 宿主）。
pub fn app_name_from_title(title: &str) -> Option<String> {
    let t = title.to_lowercase();
    if t.contains("minecraft") || t.contains(" mc") || t.starts_with("mc ") {
        return Some("Minecraft".into());
    }
    if t.contains("intellij") || t.contains("idea") {
        return Some("IntelliJ IDEA".into());
    }
    if t.contains("visual studio code") {
        return Some("VS Code".into());
    }
    if t.contains("visual studio") {
        return Some("Visual Studio".into());
    }
    if t.contains("pycharm") {
        return Some("PyCharm".into());
    }
    if t.contains("webstorm") {
        return Some("WebStorm".into());
    }
    None
}

/// 已知进程变体合并为统一显示名（写库与查询两侧共用，保证匹配一致）。
pub fn normalize_app_name(name: &str) -> String {
    let lower = name.to_lowercase();
    if lower.contains("msedge") || lower.contains("webview2") {
        return "Edge".into();
    }
    if lower == "browser" || lower.contains("qbblink") {
        return "WeGame浏览器".into();
    }
    if lower.contains("leagueclient")
        || lower.contains("league of legends")
        || lower.contains("lol")
    {
        return "英雄联盟".into();
    }
    // 系统组件统一归「系统」
    if lower.contains("startmenu")
        || lower.contains("shellhost")
        || lower.contains("searchhost")
        || lower.contains("lockapp")
        || lower.contains("applicationframehost")
        || lower.contains("shellexperiencehost")
        || lower.contains("runtimebroker")
        || lower.contains("textinputhost")
        || lower.contains("dwm")
    {
        return "系统".into();
    }
    if lower.contains("explorer") {
        return "资源管理器".into();
    }
    if lower.contains("terminal") {
        return "终端".into();
    }
    name.into()
}
