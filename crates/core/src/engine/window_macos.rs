//! macOS foreground application resolution via AppKit.
//!
//! NSWorkspace exposes the frontmost NSRunningApplication without requesting
//! Accessibility or Automation permission. TimeTrace records app identity on
//! macOS by default; window-title tracking can remain an optional permissioned
//! enhancement instead of blocking the core time-tracking experience.

use objc2_app_kit::NSWorkspace;

use crate::contracts::events::AppInfo;
use crate::contracts::window::WindowResolver;

pub struct MacOsWindowResolver;

impl MacOsWindowResolver {
    pub fn new() -> Self { Self }
}

impl WindowResolver for MacOsWindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        let workspace = NSWorkspace::sharedWorkspace();
        let app = workspace.frontmostApplication()?;
        let name = app.localizedName()?.to_string();
        if name.is_empty() { return None; }

        let exe_path = app
            .executableURL()
            .and_then(|url| url.path())
            .map(|path| path.to_string())
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| name.clone());

        Some(AppInfo::new(exe_path, name))
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}
