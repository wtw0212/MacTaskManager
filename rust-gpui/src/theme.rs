//! Colors, sizes and number formatting, matching the Swift version's design system
//! (Windows 11 Task Manager).

use gpui::{Hsla, Pixels, Rgba, WindowAppearance, px, rgb, rgba};

pub mod space {
    pub const XXS: f32 = 2.;
    pub const XS: f32 = 4.;
    pub const S: f32 = 8.;
    pub const M: f32 = 12.;
    pub const L: f32 = 16.;
    pub const XL: f32 = 24.;
}

pub mod size {
    pub const TITLE_BAR: f32 = 52.;
    pub const PAGE_HEADER: f32 = 52.;
    pub const NAV_ROW: f32 = 36.;
    pub const NAV_EXPANDED: f32 = 220.;
    pub const LIST_ROW: f32 = 28.;
    pub const VALUE_COLUMN: f32 = 96.;
    pub const STATUS_COLUMN: f32 = 140.;
    pub const TILE_GRAPH_W: f32 = 72.;
    pub const TILE_GRAPH_H: f32 = 48.;
    pub const RESOURCE_LIST: f32 = 248.;
    pub const COMMAND_BUTTON: f32 = 32.;
}

pub fn p(value: f32) -> Pixels {
    px(value)
}

/// Resource colors, as in Windows Task Manager.
pub mod resource {
    use gpui::{Rgba, rgb};
    pub fn cpu() -> Rgba {
        rgb(0x127DBA)
    }
    pub fn memory() -> Rgba {
        rgb(0x8C12AD)
    }
    pub fn disk() -> Rgba {
        rgb(0x4DA60D)
    }
    pub fn network() -> Rgba {
        rgb(0xA64F00)
    }
    pub fn gpu() -> Rgba {
        rgb(0x00859E)
    }
}

#[derive(Clone, Copy)]
pub struct Palette {
    pub dark: bool,
    pub window_background: Rgba,
    pub card_background: Rgba,
    pub stroke: Rgba,
    pub hover: Rgba,
    pub selected: Rgba,
    pub text: Rgba,
    pub secondary_text: Rgba,
    pub accent: Rgba,
}

impl Palette {
    pub fn for_appearance(appearance: WindowAppearance) -> Self {
        let dark = matches!(
            appearance,
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        );
        if dark {
            Palette {
                dark,
                window_background: rgb(0x202020),
                card_background: rgb(0x272727),
                stroke: rgb(0x383838),
                hover: rgba(0xFFFFFF0A),
                selected: rgba(0xFFFFFF12),
                text: rgb(0xFFFFFF),
                secondary_text: rgba(0xFFFFFFA0),
                accent: rgb(0x4CC2FF),
            }
        } else {
            Palette {
                dark,
                window_background: rgb(0xF3F3F3),
                card_background: rgb(0xFBFBFB),
                stroke: rgb(0xE3E3E3),
                hover: rgba(0x0000000A),
                selected: rgba(0x00000012),
                text: rgb(0x1A1A1A),
                secondary_text: rgba(0x0000009E),
                accent: rgb(0x005FB8),
            }
        }
    }

    /// Heat shading for process value cells: light cyan for idle, deeper teal for busy.
    pub fn heat(&self, level: f64) -> Hsla {
        let level = level.clamp(0., 1.) as f32;
        let (alpha, g, b) = if self.dark {
            (0.16 + 0.45 * level, 0.55, 0.70)
        } else {
            (0.12 + 0.50 * level, 0.67, 0.80)
        };
        Rgba {
            r: 0.,
            g,
            b,
            a: alpha,
        }
        .into()
    }
}

pub fn with_alpha(color: Rgba, alpha: f32) -> Rgba {
    Rgba { a: alpha, ..color }
}

// MARK: - Formatting

pub fn percent(value: Option<f64>) -> String {
    match value {
        Some(v) if v >= 0. => format!("{}%", (v * 100.).round() as i64),
        _ => "N/A".into(),
    }
}

pub fn precise_percent(value: f64) -> String {
    format!("{:.1}%", value * 100.)
}

pub fn uptime(seconds: u64) -> String {
    format!(
        "{}:{:02}:{:02}:{:02}",
        seconds / 86_400,
        seconds / 3_600 % 24,
        seconds / 60 % 60,
        seconds % 60
    )
}

/// Binary units like ByteCountFormatter's `.memory` style ("12.3 MB", "1.2 GB").
pub fn bytes(value: Option<u64>) -> String {
    let Some(value) = value else {
        return "N/A".into();
    };
    scaled(value as f64, 1024., &["bytes", "KB", "MB", "GB", "TB"])
}

/// Decimal units like ByteCountFormatter's `.file` style.
pub fn file_bytes(value: u64) -> String {
    scaled(value as f64, 1000., &["bytes", "KB", "MB", "GB", "TB"])
}

fn scaled(mut value: f64, base: f64, units: &[&str]) -> String {
    let mut unit = 0;
    while value >= base && unit < units.len() - 1 {
        value /= base;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", value as u64, units[0])
    } else {
        format!("{:.1} {}", value, units[unit])
    }
}

pub fn gigabytes(value: u64, unit: bool) -> String {
    let gb = value as f64 / 1_073_741_824.;
    if unit {
        format!("{gb:.1} GB")
    } else {
        format!("{gb:.1}")
    }
}

pub fn megabytes(value: u64) -> String {
    format!("{:.1} MB", value as f64 / 1_048_576.)
}

pub fn megabyte_rate(value: f64) -> String {
    format!("{:.1} MB/s", value.max(0.) / 1_048_576.)
}

/// Bytes per second, e.g. "12.3 MB/s".
pub fn byte_rate(value: f64) -> String {
    format!("{}/s", file_bytes(value.max(0.) as u64))
}

/// Bytes per second shown as bits, e.g. "4.2 Mbps", like Windows does for networks.
pub fn bit_rate(bytes_per_second: f64) -> String {
    let mut value = bytes_per_second.max(0.) * 8.;
    let units = ["bps", "Kbps", "Mbps", "Gbps"];
    let mut unit = 0;
    while value >= 1000. && unit < units.len() - 1 {
        value /= 1000.;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", value as u64, units[0])
    } else {
        format!("{:.1} {}", value, units[unit])
    }
}

pub fn temperature(celsius: Option<f64>) -> String {
    celsius.map_or_else(|| "N/A".into(), |c| format!("{c:.0} °C"))
}

/// Rounds a graph's top value up to 1, 2 or 5 times a power of ten.
pub fn nice_scale(value: f64, minimum: f64) -> f64 {
    let value = value.max(minimum);
    let magnitude = 10f64.powf(value.log10().floor());
    for step in [1., 2., 5., 10.] {
        if step * magnitude >= value {
            return step * magnitude;
        }
    }
    10. * magnitude
}
