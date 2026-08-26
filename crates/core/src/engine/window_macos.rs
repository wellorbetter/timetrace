//! macOS foreground application resolution.
//!
//! System Events gives us the frontmost application and, when Accessibility
//! permission is available, the active window title. App tracking still works
//! when title access is denied.

use std::process::Command;

use crate::contracts::events::AppInfo;
use crate::contracts::window::WindowResolver;

pub struct MacOsWindowResolver;

impl MacOsWindowResolver {
    pub fn new() -> Self { Self }
}

impl WindowResolver for MacOsWindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        let identity = run_osascript(
            "tell application \"System Events\" to tell first application process whose frontmost is true to return (name as text) & \"|||\" & (unix id as text)"
        )?;
        let mut parts = identity.splitn(2, "|||");
        let name = parts.next()?.trim().to_string();
        let pid = parts.next()?.trim();
        if name.is_empty() { return None; }

        let exe_path = Command::new("ps")
            .args(["-p", pid, "-o", "comm="])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| name.clone());

        let title = run_osascript(
            "tell application \"System Events\" to tell first application process whose frontmost is true to if (count of windows) > 0 then return name of front window"
        ).filter(|s| !s.trim().is_empty());

        let mut app = AppInfo::new(exe_path, name);
        if let Some(title) = title { app = app.with_title(title); }
        Some(app)
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

fn run_osascript(script: &str) -> Option<String> {
    let output = Command::new("osascript").args(["-e", script]).output().ok()?;
    if !output.status.success() { return None; }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}
