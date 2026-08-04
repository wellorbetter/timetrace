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

            let exe_path = get_process_path(pid).unwrap_or_else(|| format!("pid:{}", pid));
            let display_name = display_name_for(&exe_path);
            let title = get_window_title_text(hwnd);

            Some(AppInfo::new(exe_path, display_name).with_title(title.unwrap_or_default()))
        }
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

/// Friendly display name for a process.
/// Generic runtimes (java/javaw/python/node/…) all share the SAME exe name,
/// so we fall back to the exe path's parent directory (like ActivityWatch /
/// RescueTime do) — e.g. `…\JetBrains\IntelliJ IDEA 2024.1\bin\java.exe`
/// becomes `IntelliJ IDEA 2024.1`, distinguishing multiple Java apps.
fn display_name_for(exe_path: &str) -> String {
    let file = exe_path.rsplit('\\').next().unwrap_or(exe_path);
    let stem = file.trim_end_matches(".exe");
    let lower = stem.to_lowercase();
    let generic = [
        "java", "javaw", "javaws", "python", "pythonw", "python3", "node",
        "dotnet", "electron", "chrome", "ruby", "php", "go", "cargo",
    ];
    if generic.contains(&lower.as_str()) {
        let parts: Vec<&str> = exe_path.rsplit('\\').collect();
        // exe_path\<maybe bin>\<app dir>
        for p in parts.iter().skip(1) {
            if !p.eq_ignore_ascii_case("bin") && !p.eq_ignore_ascii_case("bin64") {
                return (*p).to_string();
            }
        }
        return stem.to_string();
    }
    stem.to_string()
}

unsafe fn get_process_path(pid: u32) -> Option<String> {
    let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
    let _guard = HandleGuard(handle);
    let mut buffer = vec![0u16; 260];
    let mut size: u32 = buffer.len() as u32;
    if QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut size).is_ok() {
        buffer.truncate(size as usize);
        Some(String::from_utf16_lossy(&buffer))
    } else {
        Some(format!("process-{}", pid))
    }
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
