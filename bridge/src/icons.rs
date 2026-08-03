//! Extract application icons from .exe files via `SHGetFileInfoW`.
//! Returns raw RGBA pixels for Flutter rendering.
//!
//! Uses manual FFI declarations to avoid windows-sys feature-gating issues.

use std::mem;

use windows_sys::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDIBits, GetObjectW,
    SelectObject, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo, ICONINFO};

// ── Manual FFI (shell32) — avoids windows-sys feature hell ──

#[repr(C)]
struct SHFILEINFOW {
    hIcon: *mut std::ffi::c_void,
    iIcon: i32,
    dwAttributes: u32,
    szDisplayName: [u16; 260],
    szTypeName: [u16; 80],
}

const SHGFI_ICON: u32 = 0x0000_0100;
const SHGFI_LARGEICON: u32 = 0x0000_0020;
const SHGFI_USEFILEATTRIBUTES: u32 = 0x0000_0010;

#[link(name = "shell32")]
unsafe extern "system" {
    fn SHGetFileInfoW(
        psz_path: *const u16,
        dw_file_attributes: u32,
        psfi: *mut SHFILEINFOW,
        cb_file_info: u32,
        u_flags: u32,
    ) -> usize;
}

/// Extract an icon for an exe path.
/// Returns (width, height, rgba_bytes).
pub fn extract_icon_rgba(exe_path: &str) -> Option<(i32, i32, Vec<u8>)> {
    unsafe {
        let mut path: Vec<u16> = exe_path.encode_utf16().collect();
        path.push(0);
        let mut info: SHFILEINFOW = mem::zeroed();
        let ret = SHGetFileInfoW(
            path.as_ptr(),
            0,
            &mut info,
            mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON | SHGFI_USEFILEATTRIBUTES,
        );
        if ret == 0 || info.hIcon.is_null() {
            return None;
        }
        let hicon = info.hIcon;

        let mut icon_info: ICONINFO = mem::zeroed();
        if GetIconInfo(hicon, &mut icon_info) == 0 {
            DestroyIcon(hicon);
            return None;
        }
        let hbm = icon_info.hbmColor;
        if hbm.is_null() {
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask); }
            DestroyIcon(hicon);
            return None;
        }

        let mut bm: BITMAP = mem::zeroed();
        let got = GetObjectW(hbm, mem::size_of::<BITMAP>() as i32, &mut bm as *mut _ as *mut _);
        if got == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask); }
            DestroyIcon(hicon);
            return None;
        }

        let w = bm.bmWidth;
        let h = bm.bmHeight;
        if bm.bmBitsPixel != 32 && bm.bmBitsPixel != 24 {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask); }
            DestroyIcon(hicon);
            return None;
        }

        let dc = CreateCompatibleDC(std::ptr::null_mut());
        if dc.is_null() {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask); }
            DestroyIcon(hicon);
            return None;
        }

        let mut bmi: BITMAPINFO = mem::zeroed();
        bmi.bmiHeader = BITMAPINFOHEADER {
            biSize: mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..Default::default()
        };

        let mut pixels: Vec<u8> = vec![0u8; (w * h * 4) as usize];
        let mut dib_bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let dib = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &mut dib_bits, std::ptr::null_mut(), 0);
        if !dib.is_null() {
            let old = SelectObject(dc, dib as HGDIOBJ);
            GetDIBits(dc, hbm, 0, h as u32, dib_bits, &mut bmi, DIB_RGB_COLORS);
            SelectObject(dc, old);
            std::ptr::copy_nonoverlapping(dib_bits as *const u8, pixels.as_mut_ptr(), pixels.len());
            DeleteObject(dib);
        }

        DeleteDC(dc);
        DeleteObject(hbm);
        if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask); }
        DestroyIcon(hicon);

        // BGRA → RGBA premultiplied
        let mut rgba = Vec::with_capacity(pixels.len());
        for px in pixels.chunks_exact(4) {
            let (b, g, r, a) = (px[0], px[1], px[2], px[3]);
            let af = a as f32 / 255.0;
            rgba.push((r as f32 * af) as u8);
            rgba.push((g as f32 * af) as u8);
            rgba.push((b as f32 * af) as u8);
            rgba.push(a);
        }

        Some((w, h, rgba))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_real_icons() {
        let paths = [
            r"C:\Windows\explorer.exe",
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            r"D:\QQ\QQ.exe",
            r"C:\Windows\system32\SecurityHealthSystray.exe",
            r"G:\WeGameApps\英雄联盟\Game\League of Legends.exe",
            r"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.24.11911.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe",
        ];
        let mut ok = 0;
        for p in paths {
            if let Some((w, h, rgba)) = extract_icon_rgba(p) {
                eprintln!("OK   {:50} -> {}x{}", p, w, h);
                assert!(w > 0 && h > 0);
                assert!(!rgba.is_empty());
                ok += 1;
            } else {
                eprintln!("FAIL {:50}", p);
            }
        }
        // explorer.exe must extract
        assert!(ok >= 1, "no icons extracted at all");
    }
}
