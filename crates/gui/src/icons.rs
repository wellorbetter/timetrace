//! Extract application icons from .exe files via `SHGetFileInfoW` (windows-sys).

use std::collections::HashMap;
use std::mem;
use std::sync::Mutex;

use eframe::egui::{self, ColorImage, TextureHandle, TextureOptions};
use windows_sys::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDIBits, GetObjectW,
    SelectObject, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ,
};
use windows_sys::Win32::UI::Shell::{SHGetFileInfoW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON};
use windows_sys::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo, ICONINFO};

pub struct IconCache {
    map: Mutex<HashMap<String, Option<TextureHandle>>>,
}

impl IconCache {
    pub fn new() -> Self { Self { map: Mutex::new(HashMap::new()) } }

    pub fn get(&self, ctx: &egui::Context, exe_path: &str) -> Option<TextureHandle> {
        let mut map = match self.map.lock() {
            Ok(map) => map,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(cached) = map.get(exe_path) { return cached.clone(); }
        let icon = extract_icon(exe_path).filter(|img| img.size[0] > 0 && img.size[1] > 0);
        let handle = icon.map(|img| ctx.load_texture(exe_path, img, TextureOptions::LINEAR));
        map.insert(exe_path.to_string(), handle.clone());
        handle
    }
}

fn extract_icon(exe_path: &str) -> Option<ColorImage> {
    unsafe {
        let mut path: Vec<u16> = exe_path.encode_utf16().collect();
        path.push(0);
        let mut info: SHFILEINFOW = mem::zeroed();
        let ret = SHGetFileInfoW(path.as_ptr(), 0, &mut info, mem::size_of::<SHFILEINFOW>() as u32, SHGFI_ICON | SHGFI_LARGEICON);
        if ret == 0 || info.hIcon.is_null() { return None; }
        let hicon = info.hIcon;

        let mut icon_info: ICONINFO = mem::zeroed();
        if GetIconInfo(hicon, &mut icon_info) == 0 {
            DestroyIcon(hicon);
            return None;
        }
        let hbm = icon_info.hbmColor as *mut std::ffi::c_void;
        if hbm.is_null() {
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask as *mut std::ffi::c_void); }
            DestroyIcon(hicon);
            return None;
        }

        // Get bitmap dimensions
        let mut bm: BITMAP = mem::zeroed();
        let got = GetObjectW(hbm, mem::size_of::<BITMAP>() as i32, &mut bm as *mut _ as *mut _);
        if got == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask as *mut std::ffi::c_void); }
            DestroyIcon(hicon);
            return None;
        }

        let w = bm.bmWidth;
        let h = bm.bmHeight;
        let bpp = bm.bmBitsPixel;
        if bpp != 32 && bpp != 24 {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask as *mut std::ffi::c_void); }
            DestroyIcon(hicon);
            return None;
        }

        let dc = CreateCompatibleDC(std::ptr::null_mut());
        if dc.is_null() {
            DeleteObject(hbm);
            if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask as *mut std::ffi::c_void); }
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
            GetDIBits(dc, hbm as _ , 0, h as u32, dib_bits, &mut bmi, DIB_RGB_COLORS);
            SelectObject(dc, old);
            std::ptr::copy_nonoverlapping(dib_bits as *const u8, pixels.as_mut_ptr(), pixels.len());
            DeleteObject(dib as *mut std::ffi::c_void);
        }

        DeleteDC(dc);
        DeleteObject(hbm);
        if !icon_info.hbmMask.is_null() { DeleteObject(icon_info.hbmMask as *mut std::ffi::c_void); }
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

        Some(ColorImage::from_rgba_unmultiplied([w as usize, h as usize], &rgba))
    }
}
