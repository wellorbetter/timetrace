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
            let title = get_window_title_text(hwnd).unwrap_or_default();
            let display_name = display_name_for(&exe_path, &title);

            Some(AppInfo::new(exe_path, display_name).with_title(title))
        }
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> { None }
}

/// Friendly display name for a process.
/// Priority (matches how ActivityWatch / RescueTime identify apps):
///  1. non-generic exe file name (msedge → Edge via normalize)
///  2. generic runtimes (java/javaw/python/node/…) → exe path parent dir,
///     e.g. `…\JetBrains\IntelliJ IDEA 2024.1\bin\java.exe` → `IntelliJ IDEA 2024.1`
///  3. if the parent dir is meaningless (jre/jdk/…), fall back to the
///     window-title keywords (Minecraft Java is javaw.exe from a random
///     JRE — only the title says “Minecraft”).
fn display_name_for(exe_path: &str, title: &str) -> String {
    let file = exe_path.rsplit('\\').next().unwrap_or(exe_path);
    let stem = file.trim_end_matches(".exe");
    let lower = stem.to_lowercase();
    let generic = [
        "java", "javaw", "javaws", "python", "pythonw", "python3", "node",
        "dotnet", "electron", "chrome", "ruby", "php", "go", "cargo",
    ];
    if generic.contains(&lower.as_str()) {
        let parts: Vec<&str> = exe_path.rsplit('\\').collect();
        for p in parts.iter().skip(1) {
            let pl = p.to_lowercase();
            let meaningless = pl == "bin"
                || pl == "bin64"
                || pl.starts_with("jre")
                || pl.starts_with("jdk")
                || pl.contains("runtime")
                || pl == "openjdk"
                || pl == "windowsapps";
            if !meaningless {
                return (*p).to_string();
            }
        }
        // Nothing meaningful in the path → title keywords (Minecraft, …).
        return app_name_from_title(title).unwrap_or_else(|| stem.to_string());
    }
    stem.to_string()
}

/// Recognize well-known apps from the window title (works for generic
/// runtimes like javaw.exe running Minecraft, or UWP hosts).
fn app_name_from_title(title: &str) -> Option<String> {
    let t = title.to_lowercase();
    if t.contains("minecraft") || t.contains("mc ") || t.contains(" mc") {
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
