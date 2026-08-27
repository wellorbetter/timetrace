const GENERIC_RUNTIMES: &[&str] = &[
    "java", "javaw", "javaws", "python", "pythonw", "python3", "node", "dotnet",
    "electron", "chrome", "ruby", "php", "go", "cargo",
];

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

pub fn display_name_for(exe_path: &str, title: &str) -> String {
    if exe_path.is_empty() {
        return app_name_from_title(title).unwrap_or_else(|| "未知应用".into());
    }
    let file = exe_path
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(exe_path);
    let stem = file.trim_end_matches(".exe");
    let lower = stem.to_lowercase();

    if GENERIC_RUNTIMES.contains(&lower.as_str()) {
        let parts: Vec<&str> = exe_path.rsplit(['\\', '/']).collect();
        for part in parts.iter().skip(1) {
            if !is_meaningless_dir(part) {
                return (*part).to_string();
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

fn app_name_from_title(title: &str) -> Option<String> {
    let t = title.to_lowercase();
    if t.contains("minecraft") || t.contains(" mc") || t.starts_with("mc ") {
        Some("Minecraft".into())
    } else if t.contains("intellij") || t.contains("idea") {
        Some("IntelliJ IDEA".into())
    } else if t.contains("visual studio code") {
        Some("VS Code".into())
    } else if t.contains("visual studio") {
        Some("Visual Studio".into())
    } else if t.contains("pycharm") {
        Some("PyCharm".into())
    } else if t.contains("webstorm") {
        Some("WebStorm".into())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_meaningful_app_identity_without_timetrace_types() {
        assert_eq!(display_name_for(r"C:\Apps\Code.exe", "project"), "Code");
        assert_eq!(
            display_name_for(r"C:\JetBrains\bin\java.exe", "IntelliJ IDEA"),
            "JetBrains"
        );
    }
}
