//! Win32 window resolution via `GetForegroundWindow` + `OpenProcess`.

use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId,
};
use windows::core::PWSTR;

use crate::contracts::events::AppInfo;
use crate::contracts::window::WindowResolver;
use crate::engine::app_identity::display_name_for;

pub struct Win32WindowResolver;

impl Win32WindowResolver {
    pub fn new() -> Self {
        Self
    }
}

impl WindowResolver for Win32WindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.is_invalid() {
                return None;
            }

            let mut pid: u32 = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == 0 {
                return None;
            }

            // A readable absolute executable path is the canonical identity
            // contract. Returning a title-only AppInfo would make historical
            // tracking active while the reminder snapshot is unavailable.
            let mut exe_path = get_process_path(pid)?;
            let exe_stem = exe_path
                .rsplit('\\')
                .next()
                .unwrap_or("")
                .trim_end_matches(".exe")
                .to_lowercase();
            if exe_stem == "applicationframehost" || exe_stem == "shellexperiencehost" {
                if let Some(child_pid) = resolve_child_pid(hwnd, pid) {
                    if let Some(real) = get_process_path(child_pid) {
                        exe_path = real;
                    }
                }
            }

            let title = get_window_title_text(hwnd).unwrap_or_default();
            let display_name = display_name_for(&exe_path, &title);
            Some(AppInfo::new(exe_path, display_name).with_title(title))
        }
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> {
        None
    }
}

struct ChildCtx {
    host_pid: u32,
    child_pid: u32,
}

unsafe extern "system" fn enum_child_proc(hwnd: HWND, lparam: LPARAM) -> windows::core::BOOL {
    let ctx = unsafe { &mut *(lparam.0 as *mut ChildCtx) };
    let mut cpid: u32 = 0;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut cpid)) };
    if cpid != 0 && cpid != ctx.host_pid {
        ctx.child_pid = cpid;
        return windows::core::BOOL(0);
    }
    windows::core::BOOL(1)
}

unsafe fn resolve_child_pid(hwnd: HWND, host_pid: u32) -> Option<u32> {
    let mut ctx = ChildCtx {
        host_pid,
        child_pid: 0,
    };
    let _ = unsafe {
        EnumChildWindows(
            Some(hwnd),
            Some(enum_child_proc),
            LPARAM(&mut ctx as *mut ChildCtx as isize),
        )
    };
    (ctx.child_pid != 0).then_some(ctx.child_pid)
}

unsafe fn get_process_path(pid: u32) -> Option<String> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;
    let _guard = HandleGuard(handle);
    let mut buffer = vec![0u16; 260];
    let mut size: u32 = buffer.len() as u32;
    if unsafe {
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_WIN32,
            PWSTR(buffer.as_mut_ptr()),
            &mut size,
        )
    }
    .is_ok()
        && size > 0
    {
        buffer.truncate(size as usize);
        Some(String::from_utf16_lossy(&buffer))
    } else {
        None
    }
}

unsafe fn get_window_title_text(hwnd: HWND) -> Option<String> {
    let len = unsafe { GetWindowTextLengthW(hwnd) };
    if len == 0 {
        return None;
    }
    let mut buffer = vec![0u16; (len + 1) as usize];
    let copied = unsafe { GetWindowTextW(hwnd, &mut buffer) };
    if copied == 0 {
        return None;
    }
    buffer.truncate(copied as usize);
    Some(String::from_utf16_lossy(&buffer))
}

struct HandleGuard(HANDLE);
impl Drop for HandleGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_resolver_does_not_crash() {
        let _ = Win32WindowResolver::new().get_foreground_app();
    }
}
