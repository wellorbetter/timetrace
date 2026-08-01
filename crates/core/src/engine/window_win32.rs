//! Win32 implementation of `WindowResolver`.
//!
//! Uses `GetForegroundWindow`, `GetWindowThreadProcessId`, `OpenProcess`,
//! and `QueryFullProcessImageNameW` to resolve windows to applications.

use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::mem;

use windows::core::PWSTR;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::ProcessStatus::QueryFullProcessImageNameW;
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_FORMAT, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
};

use crate::contracts::window::WindowResolver;
use crate::contracts::events::AppInfo;

pub struct Win32WindowResolver;

impl WindowResolver for Win32WindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        // SAFETY: Win32 FFI calls. All handles are checked.
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.0 == 0 {
                return None;
            }

            // Get process ID from window
            let mut pid: u32 = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == 0 {
                return None;
            }

            // Get executable path
            let exe_path = get_process_path(pid)?;

            // Derive display name from exe path
            let display_name = exe_path
                .rsplit('\\')
                .next()
                .unwrap_or(&exe_path)
                .trim_end_matches(".exe")
                .to_string();

            // Get window title
            let title = get_window_title_text(hwnd);

            Some(AppInfo::new(exe_path, display_name).with_title(title.unwrap_or_default()))
        }
    }

    fn get_window_title(&self, hwnd: isize) -> Option<String> {
        unsafe {
            let hwnd = windows::Win32::Foundation::HWND(hwnd as *mut _);
            get_window_title_text(hwnd)
        }
    }
}

/// Get the full executable path for a process ID.
unsafe fn get_process_path(pid: u32) -> Option<String> {
    let handle: HANDLE = OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION,
        false,
        pid,
    )
    .ok()?;

    // Ensure we close the handle
    let _guard = HandleGuard(handle);

    let mut buffer = vec![0u16; 260]; // MAX_PATH
    let mut size: u32 = buffer.len() as u32;

    let result = QueryFullProcessImageNameW(
        handle,
        PROCESS_NAME_FORMAT(0), // PROCESS_NAME_WIN32
        PWSTR(buffer.as_mut_ptr()),
        &mut size,
    );

    if result.is_err() {
        // Fallback: try without extension or use a placeholder
        return Some(format!("Process(PID:{})", pid));
    }

    buffer.truncate(size as usize);
    Some(String::from_utf16_lossy(&buffer))
}

/// Get the window title text for a window handle.
unsafe fn get_window_title_text(hwnd: windows::Win32::Foundation::HWND) -> Option<String> {
    let len = GetWindowTextLengthW(hwnd);
    if len == 0 {
        return None;
    }

    let mut buffer = vec![0u16; (len + 1) as usize];
    let copied = GetWindowTextW(hwnd, &mut buffer);
    if copied == 0 {
        return None;
    }

    buffer.truncate(copied as usize);
    Some(String::from_utf16_lossy(&buffer))
}

/// RAII guard to close a Win32 handle on drop.
struct HandleGuard(HANDLE);

impl Drop for HandleGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = windows::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolver_does_not_crash() {
        let resolver = Win32WindowResolver;
        // This will return None in CI (no GUI), but must not crash
        let _app = resolver.get_foreground_app();
    }
}
