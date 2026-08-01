//! Win32 window resolution via `GetForegroundWindow` + `OpenProcess`.

use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
};

use crate::contracts::window::WindowResolver;
use crate::contracts::events::AppInfo;

pub struct Win32WindowResolver;

impl WindowResolver for Win32WindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.is_invalid() { return None; }

            let mut pid: u32 = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == 0 { return None; }

            let exe_path = get_process_path(pid)?;
            let display_name = exe_path.rsplit('\\').next().unwrap_or(&exe_path)
                .trim_end_matches(".exe").to_string();
            let title = get_window_title_text(hwnd);

            Some(AppInfo::new(exe_path, display_name).with_title(title.unwrap_or_default()))
        }
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

unsafe fn get_process_path(pid: u32) -> Option<String> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()? };
    let _guard = HandleGuard(handle);

    let mut buffer = vec![0u16; 260];
    let mut size: u32 = buffer.len() as u32;

    let result = unsafe { QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut size) };
    if result.is_err() {
        return Some(format!("Process(PID:{})", pid));
    }

    buffer.truncate(size as usize);
    Some(String::from_utf16_lossy(&buffer))
}

unsafe fn get_window_title_text(hwnd: HWND) -> Option<String> {
    let len = unsafe { GetWindowTextLengthW(hwnd) };
    if len == 0 { return None; }

    let mut buffer = vec![0u16; (len + 1) as usize];
    let copied = unsafe { GetWindowTextW(hwnd, &mut buffer) };
    if copied == 0 { return None; }

    buffer.truncate(copied as usize);
    Some(String::from_utf16_lossy(&buffer))
}

struct HandleGuard(HANDLE);
impl Drop for HandleGuard {
    fn drop(&mut self) { unsafe { let _ = CloseHandle(self.0); }; }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_resolver_does_not_crash() { let _ = Win32WindowResolver.get_foreground_app(); }
}
