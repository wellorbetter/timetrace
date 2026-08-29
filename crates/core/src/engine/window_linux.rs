//! Linux/X11 foreground window resolution.
//!
//! Reads EWMH properties directly through X11 so TimeTrace does not depend on
//! helper binaries such as `xprop` or `xdotool`. Works on X11 and XWayland.

use std::path::Path;

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{Atom, AtomEnum, ConnectionExt as _, Window};

use crate::contracts::events::AppInfo;
use crate::contracts::window::WindowResolver;

pub struct LinuxWindowResolver;

impl LinuxWindowResolver {
    pub fn new() -> Self {
        Self
    }

    fn resolve() -> Option<AppInfo> {
        let (conn, screen_num) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen_num)?.root;
        let active_atom = intern(&conn, b"_NET_ACTIVE_WINDOW")?;
        let active = conn
            .get_property(false, root, active_atom, AtomEnum::WINDOW, 0, 1)
            .ok()?
            .reply()
            .ok()?
            .value32()?
            .next()?;
        if active == 0 {
            return None;
        }

        let pid = window_pid(&conn, active);
        let exe_path = pid
            .and_then(|pid| std::fs::read_link(format!("/proc/{pid}/exe")).ok())
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default();
        let title = window_title(&conn, active).unwrap_or_default();
        let display_name = if !exe_path.is_empty() {
            Path::new(&exe_path)
                .file_stem()
                .and_then(|value| value.to_str())
                .filter(|value| !value.is_empty())
                .unwrap_or("应用")
                .to_string()
        } else if !title.is_empty() {
            title.clone()
        } else {
            "应用".to_string()
        };

        let identity = if exe_path.is_empty() {
            display_name.clone()
        } else {
            exe_path.clone()
        };
        let mut app = AppInfo::new(identity, display_name);
        if !title.is_empty() {
            app = app.with_title(title);
        }
        Some(app)
    }
}

impl WindowResolver for LinuxWindowResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        Self::resolve()
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> {
        None
    }
}

fn intern<C: Connection>(conn: &C, name: &[u8]) -> Option<Atom> {
    conn.intern_atom(false, name).ok()?.reply().ok().map(|reply| reply.atom)
}

fn window_pid<C: Connection>(conn: &C, window: Window) -> Option<u32> {
    let atom = intern(conn, b"_NET_WM_PID")?;
    conn.get_property(false, window, atom, AtomEnum::CARDINAL, 0, 1)
        .ok()?
        .reply()
        .ok()?
        .value32()?
        .next()
}

fn window_title<C: Connection>(conn: &C, window: Window) -> Option<String> {
    let net_wm_name = intern(conn, b"_NET_WM_NAME")?;
    let utf8 = intern(conn, b"UTF8_STRING")?;
    if let Some(value) = property_string(conn, window, net_wm_name, utf8) {
        return Some(value);
    }
    property_string(conn, window, AtomEnum::WM_NAME.into(), AtomEnum::STRING.into())
}

fn property_string<C: Connection>(
    conn: &C,
    window: Window,
    property: Atom,
    property_type: Atom,
) -> Option<String> {
    let reply = conn
        .get_property(false, window, property, property_type, 0, 2048)
        .ok()?
        .reply()
        .ok()?;
    let value = String::from_utf8_lossy(&reply.value)
        .trim_matches(char::from(0))
        .trim()
        .to_string();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolver_is_infallible_without_display() {
        let resolver = LinuxWindowResolver::new();
        let _ = resolver.get_foreground_app();
    }
}
