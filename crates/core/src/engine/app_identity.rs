//! 应用识别与命名（Application Identity）。
//!
//! 纯逻辑、无 Win32 依赖，集中管理：
//! - `display_name_for`: 由 exe 路径 + 窗口标题推断友好应用名
//!   （普通 exe → 文件名；通用运行时 → 父目录；无意义目录 → 标题关键词）
//! - `normalize_app_name`: 已知进程变体合并（msedge/browser → Edge 等）
//! - `app_name_from_title`: 窗口标题关键词识别（Minecraft / IDEA / VS Code …）

use thiserror::Error;

/// Platform comparison rules used by executable-path identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutablePathPlatform {
    /// Windows paths use backslash separators and deterministic ASCII folding.
    Windows,
    /// macOS paths use slash separators and retain case.
    MacOs,
}

/// A non-sensitive executable-path validation failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ExecutablePathError {
    /// The supplied path contains no usable content.
    #[error("executable path is empty")]
    Empty,
    /// NUL cannot be represented safely in filesystem or SQLite identity.
    #[error("executable path contains a NUL character")]
    ContainsNul,
    /// Rules require a stable absolute executable path.
    #[error("executable path must be absolute")]
    Relative,
    /// A lexical parent component would escape the filesystem root.
    #[error("executable path escapes its root")]
    EscapesRoot,
    /// The absolute prefix does not contain a usable drive or network share.
    #[error("executable path has an invalid root")]
    InvalidRoot,
    /// A Windows component has trailing dots/spaces with ambiguous Win32 identity.
    #[error("executable path contains an ambiguous Windows component")]
    AmbiguousWindowsComponent,
    /// A durable rule cannot safely approximate Windows ordinal case identity.
    #[error("executable path uses unsupported Windows case mapping")]
    UnsupportedWindowsCaseMapping,
    /// U+FFFD can be produced by lossy UTF-16/path conversion and is not a
    /// collision-safe durable Windows executable identity.
    #[error("executable path contains a lossy Windows replacement character")]
    LossyWindowsReplacementCharacter,
}

/// Normalize an executable path using the current platform's identity rules.
///
/// The operation is lexical: it neither touches the filesystem nor requires
/// the executable to exist. This keeps rule matching deterministic and avoids
/// elevation or symlink-dependent identities.
pub fn normalize_executable_path(input: &str) -> Result<String, ExecutablePathError> {
    #[cfg(target_os = "windows")]
    const PLATFORM: ExecutablePathPlatform = ExecutablePathPlatform::Windows;
    #[cfg(not(target_os = "windows"))]
    const PLATFORM: ExecutablePathPlatform = ExecutablePathPlatform::MacOs;

    normalize_executable_path_for(input, PLATFORM)
}

/// Normalize an executable path for durable timeout-rule identity.
///
/// Windows compares filesystem names with an OS ordinal uppercase table. A
/// portable Unicode lowercase transform is not equivalent and can both merge
/// distinct paths and split equivalent ones. Until the schema stores a native
/// ordinal comparison key, this function accepts the exact, portable subset:
/// ASCII-case paths plus Unicode characters that have no case mapping. U+FFFD
/// is rejected before lexical normalization because it can represent multiple
/// invalid UTF-16 paths after a lossy Windows path conversion.
pub fn normalize_timeout_rule_path(input: &str) -> Result<String, ExecutablePathError> {
    #[cfg(target_os = "windows")]
    const PLATFORM: ExecutablePathPlatform = ExecutablePathPlatform::Windows;
    #[cfg(not(target_os = "windows"))]
    const PLATFORM: ExecutablePathPlatform = ExecutablePathPlatform::MacOs;

    normalize_timeout_rule_path_for(input, PLATFORM)
}

/// Normalize timeout-rule identity for an explicit platform.
///
/// This is primarily useful for deterministic cross-platform contract tests.
pub fn normalize_timeout_rule_path_for(
    input: &str,
    platform: ExecutablePathPlatform,
) -> Result<String, ExecutablePathError> {
    if platform == ExecutablePathPlatform::Windows && input.contains('\u{fffd}') {
        return Err(ExecutablePathError::LossyWindowsReplacementCharacter);
    }
    let normalized = normalize_executable_path_for(input, platform)?;
    if platform == ExecutablePathPlatform::Windows {
        if contains_non_ascii_case_mapping(&normalized) {
            return Err(ExecutablePathError::UnsupportedWindowsCaseMapping);
        }
    }
    Ok(normalized)
}

/// Normalize an executable path for an explicit platform.
///
/// This variant makes both identity policies deterministically testable on a
/// single host. Product code should normally call [`normalize_executable_path`].
pub fn normalize_executable_path_for(
    input: &str,
    platform: ExecutablePathPlatform,
) -> Result<String, ExecutablePathError> {
    let mut value = input.trim();
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        let quoted_value = &value[1..value.len() - 1];
        if platform == ExecutablePathPlatform::Windows
            && has_windows_extended_prefix(quoted_value.trim_start())
            && quoted_value.trim_end().len() != quoted_value.len()
        {
            return Err(ExecutablePathError::AmbiguousWindowsComponent);
        }
        value = quoted_value.trim();
    } else if platform == ExecutablePathPlatform::Windows
        && has_windows_extended_prefix(input.trim_start())
        && input.trim_end().len() != input.len()
    {
        // Whitespace is part of the extended namespace rather than decoration,
        // so stripping it would collapse two distinct paths into one rule key.
        return Err(ExecutablePathError::AmbiguousWindowsComponent);
    }
    if value.is_empty() {
        return Err(ExecutablePathError::Empty);
    }
    if value.contains('\0') {
        return Err(ExecutablePathError::ContainsNul);
    }

    match platform {
        ExecutablePathPlatform::Windows => normalize_windows_path(value),
        ExecutablePathPlatform::MacOs => normalize_macos_path(value),
    }
}

fn has_windows_extended_prefix(input: &str) -> bool {
    input
        .replace('/', "\\")
        .to_ascii_lowercase()
        .starts_with(r"\\?\")
}

fn normalize_windows_path(input: &str) -> Result<String, ExecutablePathError> {
    let mut path = input.replace('/', "\\");
    let lower = path.to_ascii_lowercase();
    if lower.starts_with(r"\\?\unc\") {
        path = format!(r"\\{}", &path[8..]);
    } else if lower.starts_with(r"\\?\") {
        path = path[4..].to_string();
    }

    if path.starts_with(r"\\") {
        return normalize_windows_unc(&path);
    }

    let bytes = path.as_bytes();
    if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' || bytes[2] != b'\\' {
        return Err(ExecutablePathError::Relative);
    }

    let mut components = Vec::new();
    normalize_windows_components(path[3..].split('\\'), &mut components)?;
    let drive = (bytes[0] as char).to_ascii_lowercase();
    let mut normalized = format!("{drive}:\\");
    normalized.push_str(&components.join("\\"));
    Ok(normalized.to_ascii_lowercase())
}

fn normalize_windows_unc(path: &str) -> Result<String, ExecutablePathError> {
    let mut raw = path[2..].split('\\').filter(|part| !part.is_empty());
    let server = raw.next().ok_or(ExecutablePathError::InvalidRoot)?;
    let share = raw.next().ok_or(ExecutablePathError::InvalidRoot)?;
    if server == "." || server == ".." || share == "." || share == ".." {
        return Err(ExecutablePathError::InvalidRoot);
    }
    validate_windows_component(server)?;
    validate_windows_component(share)?;
    let mut components = Vec::new();
    normalize_windows_components(raw, &mut components)?;
    let mut normalized = format!(r"\\{server}\{share}");
    if !components.is_empty() {
        normalized.push('\\');
        normalized.push_str(&components.join("\\"));
    }
    Ok(normalized.to_ascii_lowercase())
}

fn contains_non_ascii_case_mapping(path: &str) -> bool {
    path.chars().any(|character| {
        if character.is_ascii() {
            return false;
        }
        let original = character.to_string();
        character.to_lowercase().collect::<String>() != original
            || character.to_uppercase().collect::<String>() != original
    })
}

fn normalize_macos_path(path: &str) -> Result<String, ExecutablePathError> {
    if !path.starts_with('/') {
        return Err(ExecutablePathError::Relative);
    }
    let mut components = Vec::new();
    normalize_components(path[1..].split('/'), &mut components)?;
    if components.is_empty() {
        return Ok("/".to_string());
    }
    Ok(format!("/{}", components.join("/")))
}

fn normalize_windows_components<'a>(
    parts: impl IntoIterator<Item = &'a str>,
    components: &mut Vec<&'a str>,
) -> Result<(), ExecutablePathError> {
    for part in parts {
        match part {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    return Err(ExecutablePathError::EscapesRoot);
                }
            }
            _ => {
                validate_windows_component(part)?;
                components.push(part);
            }
        }
    }
    Ok(())
}

fn validate_windows_component(component: &str) -> Result<(), ExecutablePathError> {
    if component.ends_with(['.', ' ']) {
        return Err(ExecutablePathError::AmbiguousWindowsComponent);
    }
    Ok(())
}

fn normalize_components<'a>(
    parts: impl IntoIterator<Item = &'a str>,
    components: &mut Vec<&'a str>,
) -> Result<(), ExecutablePathError> {
    for part in parts {
        match part {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    return Err(ExecutablePathError::EscapesRoot);
                }
            }
            _ => components.push(part),
        }
    }
    Ok(())
}

/// 通用运行时 exe 名 —— 它们的文件名无意义，需要靠路径/标题区分。
const GENERIC_RUNTIMES: &[&str] = &[
    "java", "javaw", "javaws", "python", "pythonw", "python3", "node", "dotnet", "electron",
    "chrome", "ruby", "php", "go", "cargo",
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

/// Derive a privacy-safe reminder name without using parent directories or titles.
///
/// Process names and executable file stems are identity-like values suitable for
/// local status and notifications. Arbitrary path components and window titles
/// are deliberately excluded because they can contain project or document names.
pub fn privacy_safe_app_name(exe_path: &str, process_name: Option<&str>) -> String {
    let process_file = process_name
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .and_then(path_file_name);
    let executable_file = path_file_name(exe_path);
    let file = process_file.or(executable_file).unwrap_or("未知应用");
    let stem = strip_exe_suffix(file).trim();
    let lower = stem.to_lowercase();
    match lower.as_str() {
        "java" | "javaw" | "javaws" => "Java".to_string(),
        "python" | "pythonw" | "python3" => "Python".to_string(),
        "node" => "Node.js".to_string(),
        "dotnet" => ".NET".to_string(),
        "electron" => "Electron".to_string(),
        "ruby" => "Ruby".to_string(),
        "php" => "PHP".to_string(),
        "go" => "Go".to_string(),
        "cargo" => "Cargo".to_string(),
        "chrome" => "Chrome".to_string(),
        _ if stem.is_empty() => "未知应用".to_string(),
        _ => normalize_app_name(stem),
    }
}

fn path_file_name(path: &str) -> Option<&str> {
    path.rsplit(['\\', '/']).find(|part| !part.is_empty())
}

fn strip_exe_suffix(file_name: &str) -> &str {
    if file_name
        .get(file_name.len().saturating_sub(4)..)
        .is_some_and(|suffix| suffix.eq_ignore_ascii_case(".exe"))
    {
        &file_name[..file_name.len() - 4]
    } else {
        file_name
    }
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
    if lower == "code" || lower == "code.exe" {
        return "VS Code".into();
    }
    if lower.contains("explorer") {
        return "资源管理器".into();
    }
    if lower.contains("terminal") {
        return "终端".into();
    }
    name.into()
}

#[cfg(test)]
mod path_tests {
    use super::{
        ExecutablePathError, ExecutablePathPlatform, normalize_executable_path_for,
        normalize_timeout_rule_path_for, privacy_safe_app_name,
    };

    #[test]
    fn windows_identity_normalizes_case_separators_and_dots() {
        let normalized = normalize_executable_path_for(
            r#""C:/Program Files/TimeTrace/./bin/../TimeTrace.EXE""#,
            ExecutablePathPlatform::Windows,
        )
        .expect("valid Windows executable");
        assert_eq!(normalized, r"c:\program files\timetrace\timetrace.exe");
    }

    #[test]
    fn windows_identity_removes_extended_prefixes() {
        assert_eq!(
            normalize_executable_path_for(
                r"\\?\C:\Apps\TimeTrace.exe",
                ExecutablePathPlatform::Windows,
            )
            .unwrap(),
            r"c:\apps\timetrace.exe"
        );
        assert_eq!(
            normalize_executable_path_for(
                r"\\?\UNC\Server\Share\Apps\TimeTrace.exe",
                ExecutablePathPlatform::Windows,
            )
            .unwrap(),
            r"\\server\share\apps\timetrace.exe"
        );
    }

    #[test]
    fn windows_identity_rejects_trailing_dot_or_space_components() {
        for path in [
            r"C:\Apps\Editor.exe.",
            r"C:\Apps.\Editor.exe",
            r"C:\Apps \Editor.exe",
            r"\\?\C:\Apps\Editor.exe.",
            r"\\?\C:\Apps \Editor.exe",
            r"\\?\UNC\Server\Share.\Editor.exe",
            "\\\\?\\C:\\Apps\\Editor.exe ",
            r#""\\?\C:\Apps\Editor.exe ""#,
        ] {
            assert_eq!(
                normalize_executable_path_for(path, ExecutablePathPlatform::Windows),
                Err(ExecutablePathError::AmbiguousWindowsComponent),
                "path should not create a second Win32 identity: {path}"
            );
        }
    }

    #[test]
    fn windows_identity_is_unicode_safe() {
        assert_eq!(
            normalize_executable_path_for(r"C:\程序\应用.EXE", ExecutablePathPlatform::Windows,)
                .unwrap(),
            r"c:\程序\应用.exe"
        );
    }

    #[test]
    fn windows_rule_identity_accepts_uncased_unicode_and_rejects_unsafe_case_folding() {
        assert_eq!(
            normalize_timeout_rule_path_for(r"C:\程序\应用.EXE", ExecutablePathPlatform::Windows,)
                .unwrap(),
            r"c:\程序\应用.exe"
        );
        for path in [
            r"C:\Apps\Σ.exe",
            r"C:\Apps\ς.exe",
            r"C:\Apps\ẞ.exe",
            r"C:\Apps\ß.exe",
            r"C:\Apps\K.exe",
        ] {
            assert_eq!(
                normalize_timeout_rule_path_for(path, ExecutablePathPlatform::Windows),
                Err(ExecutablePathError::UnsupportedWindowsCaseMapping),
                "portable lowercase must not impersonate Windows ordinal identity: {path}"
            );
        }
    }

    #[test]
    fn windows_timeout_rule_identity_rejects_lossy_replacement_only_for_rules() {
        let path = "C:\\Apps\\\u{fffd}.exe";
        assert_eq!(
            normalize_executable_path_for(path, ExecutablePathPlatform::Windows).unwrap(),
            "c:\\apps\\\u{fffd}.exe",
            "ordinary activity identity remains available"
        );
        assert_eq!(
            normalize_timeout_rule_path_for(path, ExecutablePathPlatform::Windows),
            Err(ExecutablePathError::LossyWindowsReplacementCharacter)
        );
        assert_eq!(
            normalize_timeout_rule_path_for(
                "C:\\Apps\\\u{fffd}\\..\\Editor.exe",
                ExecutablePathPlatform::Windows,
            ),
            Err(ExecutablePathError::LossyWindowsReplacementCharacter),
            "a lossy component must not be hidden by lexical normalization"
        );
        assert_eq!(
            normalize_timeout_rule_path_for(
                "/Applications/\u{fffd}.app/Contents/MacOS/App",
                ExecutablePathPlatform::MacOs,
            )
            .unwrap(),
            "/Applications/\u{fffd}.app/Contents/MacOS/App"
        );
    }

    #[test]
    fn macos_identity_retains_case_and_normalizes_components() {
        assert_eq!(
            normalize_executable_path_for(
                "/Applications/TimeTrace.app/./Contents/../Contents/MacOS/TimeTrace",
                ExecutablePathPlatform::MacOs,
            )
            .unwrap(),
            "/Applications/TimeTrace.app/Contents/MacOS/TimeTrace"
        );
    }

    #[test]
    fn identity_rejects_empty_relative_nul_and_root_escape() {
        assert_eq!(
            normalize_executable_path_for("  ", ExecutablePathPlatform::Windows),
            Err(ExecutablePathError::Empty)
        );
        assert_eq!(
            normalize_executable_path_for("app.exe", ExecutablePathPlatform::Windows),
            Err(ExecutablePathError::Relative)
        );
        assert_eq!(
            normalize_executable_path_for("C:\\Apps\\bad\0.exe", ExecutablePathPlatform::Windows,),
            Err(ExecutablePathError::ContainsNul)
        );
        assert_eq!(
            normalize_executable_path_for(r"C:\..\TimeTrace.exe", ExecutablePathPlatform::Windows,),
            Err(ExecutablePathError::EscapesRoot)
        );
        assert_eq!(
            normalize_executable_path_for("Applications/TimeTrace", ExecutablePathPlatform::MacOs),
            Err(ExecutablePathError::Relative)
        );
    }

    #[test]
    fn privacy_safe_name_never_uses_private_parent_components() {
        assert_eq!(
            privacy_safe_app_name(r"C:\Users\Alice\secret-client\node.exe", Some("node.exe")),
            "Node.js"
        );
        assert_eq!(
            privacy_safe_app_name("/Users/alice/private-project/python3", Some("python3")),
            "Python"
        );
        assert_eq!(privacy_safe_app_name(r"C:\Apps\msedge.exe", None), "Edge");
    }
}
