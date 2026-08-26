//! macOS foreground application resolution.
//!
//! `lsappinfo` queries LaunchServices directly and does not require
//! Accessibility/Automation permission. TimeTrace deliberately records app
//! identity without window titles on macOS so basic tracking works immediately
//! after launch; page/window-level tracking can be added later as an opt-in
//! Accessibility feature.

use std::process::Command;

use crate::contracts::events::AppInfo;
use crate::contracts::window::WindowResolver;

pub struct MacOsWindowResolver;

impl MacOsWindowResolver {
    pub fn new() -> Self { Self }
}

impl WindowResolver for MacOsWindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        let front = command_output("lsappinfo", &["front"])?;
        let specifier = normalize_asn(front.trim());

        let name = query_field(&specifier, "name")?;
        if name.is_empty() { return None; }
        let exe_path = query_field(&specifier, "executablepath")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| name.clone());

        Some(AppInfo::new(exe_path, name))
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

fn query_field(specifier: &str, field: &str) -> Option<String> {
    let output = command_output("lsappinfo", &["info", "-only", field, specifier])?;
    let (_, value) = output.split_once('=')?;
    Some(value.trim().trim_matches('"').to_string())
}

fn normalize_asn(value: &str) -> String {
    if value.starts_with("ASN:0x0-") && !value.starts_with("ASN:0x0-0x") {
        return value.replacen("ASN:0x0-", "ASN:0x0-0x", 1);
    }
    value.to_string()
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() { return None; }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::normalize_asn;

    #[test]
    fn normalizes_recent_lsappinfo_asn_format() {
        assert_eq!(normalize_asn("ASN:0x0-1234:"), "ASN:0x0-0x1234:");
        assert_eq!(normalize_asn("ASN:0x0-0x1234:"), "ASN:0x0-0x1234:");
    }
}
