//! Adaptive color theme system.
//!
//! Colors adapt to: system dark/light mode, time of day (warmth), and season.

use chrono::{Datelike, Local, Timelike};
use ratatui::style::Color;

/// Complete color palette for the TUI.
#[derive(Debug, Clone)]
pub struct Palette {
    pub bg: Color,
    pub bg_secondary: Color,
    pub bg_selected: Color,
    pub text: Color,
    pub text_dim: Color,
    pub accent: Color,
    pub accent_warm: Color,
    pub success: Color,
    pub warning: Color,
    pub danger: Color,
    pub border: Color,
    pub idle: Color,
    /// App usage bar colors (generated dynamically per app name).
    pub app_colors: AppColorGenerator,
}

/// Deterministic color generator for application names.
#[derive(Debug, Clone)]
pub struct AppColorGenerator;

impl AppColorGenerator {
    /// Generate a consistent color for an app name.
    /// Same name always returns the same color.
    pub fn color_for(&self, name: &str) -> Color {
        let hue = (seahash::hash(name.as_bytes()) % 360) as f32;
        hsl_to_color(hue, 0.55, 0.60)
    }
}

/// Build the current palette based on system preferences and time/date.
pub fn current_palette() -> Palette {
    let now = chrono::Local::now();
    let hour = now.hour();
    let month = now.month();
    let is_dark = true; // TODO: detect Windows system theme

    let warmth = compute_warmth(hour);
    let seasonal_hue_shift = compute_seasonal_shift(month);

    if is_dark {
        dark_palette(warmth, seasonal_hue_shift)
    } else {
        light_palette(warmth, seasonal_hue_shift)
    }
}

fn dark_palette(warmth: f32, hue_shift: f32) -> Palette {
    let bg = lerp_color((18, 18, 18), (28, 24, 20), warmth);
    let accent = shift_hue((100, 181, 246), hue_shift); // #64B5F6

    Palette {
        bg: Color::Rgb(bg.0, bg.1, bg.2),
        bg_secondary: Color::Rgb(30, 30, 30),
        bg_selected: Color::Rgb(44, 44, 44),
        text: Color::Rgb(224, 224, 224),
        text_dim: Color::Rgb(158, 158, 158),
        accent: Color::Rgb(accent.0, accent.1, accent.2),
        accent_warm: Color::Rgb(255, 183, 77),
        success: Color::Rgb(102, 187, 106),
        warning: Color::Rgb(255, 167, 38),
        danger: Color::Rgb(239, 83, 80),
        border: Color::Rgb(51, 51, 51),
        idle: Color::Rgb(44, 44, 44),
        app_colors: AppColorGenerator,
    }
}

fn light_palette(warmth: f32, hue_shift: f32) -> Palette {
    let bg = lerp_color((250, 250, 250), (255, 250, 242), warmth);
    let accent = shift_hue((25, 118, 210), hue_shift); // #1976D2

    Palette {
        bg: Color::Rgb(bg.0, bg.1, bg.2),
        bg_secondary: Color::Rgb(245, 245, 245),
        bg_selected: Color::Rgb(238, 238, 238),
        text: Color::Rgb(26, 26, 26),
        text_dim: Color::Rgb(97, 97, 97),
        accent: Color::Rgb(accent.0, accent.1, accent.2),
        accent_warm: Color::Rgb(245, 124, 0),
        success: Color::Rgb(46, 125, 50),
        warning: Color::Rgb(245, 127, 23),
        danger: Color::Rgb(198, 40, 40),
        border: Color::Rgb(224, 224, 224),
        idle: Color::Rgb(224, 224, 224),
        app_colors: AppColorGenerator,
    }
}

// ── Helpers ──

fn compute_warmth(hour: u32) -> f32 {
    match hour {
        6..=8 => 0.0,
        9..=15 => 0.05,
        16..=18 => 0.10,
        19..=21 => 0.15,
        _ => 0.20, // 22–5: warmest (night)
    }
}

fn compute_seasonal_shift(month: u32) -> f32 {
    match month {
        3..=5 => 30.0,   // spring → greenish
        6..=8 => 0.0,    // summer → blue (base)
        9..=11 => -20.0, // autumn → amber
        _ => -10.0,      // winter → indigo
    }
}

fn lerp_color(a: (u8, u8, u8), b: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    let t = t.clamp(0.0, 1.0);
    (
        (a.0 as f32 + (b.0 as f32 - a.0 as f32) * t) as u8,
        (a.1 as f32 + (b.1 as f32 - a.1 as f32) * t) as u8,
        (a.2 as f32 + (b.2 as f32 - a.2 as f32) * t) as u8,
    )
}

fn shift_hue(rgb: (u8, u8, u8), shift: f32) -> (u8, u8, u8) {
    // Convert RGB to HSL, shift hue, convert back
    let r = rgb.0 as f32 / 255.0;
    let g = rgb.1 as f32 / 255.0;
    let b = rgb.2 as f32 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;

    if (max - min).abs() < 0.001 {
        return rgb; // grayscale, hue shift has no effect
    }

    let s = if l > 0.5 {
        (max - min) / (2.0 - max - min)
    } else {
        (max - min) / (max + min)
    };

    let h = if (max - r).abs() < 0.001 {
        (g - b) / (max - min) + if g < b { 6.0 } else { 0.0 }
    } else if (max - g).abs() < 0.001 {
        (b - r) / (max - min) + 2.0
    } else {
        (r - g) / (max - min) + 4.0
    };

    let h = ((h * 60.0) + shift) % 360.0;
    hsl_to_rgb(h, s, l)
}

fn hsl_to_color(h: f32, s: f32, l: f32) -> Color {
    let (r, g, b) = hsl_to_rgb(h, s, l);
    Color::Rgb(r, g, b)
}

fn hsl_to_rgb(h: f32, s: f32, l: f32) -> (u8, u8, u8) {
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
    let m = l - c / 2.0;

    let (r, g, b) = match h as u32 {
        0..=59 => (c, x, 0.0),
        60..=119 => (x, c, 0.0),
        120..=179 => (0.0, c, x),
        180..=239 => (0.0, x, c),
        240..=299 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };

    (
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8,
    )
}
