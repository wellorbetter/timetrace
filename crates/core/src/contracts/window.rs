//! Window resolution — maps win32 handles to `AppInfo`.
//!
//! This is the ONLY place that calls Win32 window/process APIs.

use super::events::AppInfo;

/// Resolves raw window handles to application information.
///
/// Implemented by `engine::window_win32`.
pub trait WindowResolver: Send + Sync {
    /// Get the `AppInfo` for the current foreground window.
    /// Returns `None` if the foreground window cannot be resolved
    /// (e.g., elevated/system process, or desktop window).
    fn get_foreground_app(&self) -> Option<AppInfo>;

    /// Get the window title text for the given window handle.
    /// Returns `None` if the window has no title or cannot be read.
    fn get_window_title(&self, hwnd: isize) -> Option<String>;
}
