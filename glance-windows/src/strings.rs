//! Lightweight i18n for the Windows build.
//!
//! Detects the system locale once at startup (via `sys-locale`) and resolves
//! string keys through a pair of `match` tables. Keeps the tray menu and
//! work-area surface readable in Simplified Chinese on zh-CN systems while
//! staying English on everything else.
//!
//! Runtime-switching is intentionally not supported — Windows popup menus are
//! rebuilt on every right-click, but the work-area overlay draws once per
//! paint, and tray tooltip text is set at creation. Matching macOS, a language
//! change would require a restart if we later add an override field.

use std::sync::OnceLock;

use sys_locale::get_locale;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Lang {
    En,
    ZhHans,
}

static LANG: OnceLock<Lang> = OnceLock::new();

fn lang() -> Lang {
    *LANG.get_or_init(|| {
        let raw = get_locale().unwrap_or_else(|| "en-US".to_string());
        let lower = raw.to_lowercase();
        // Match zh, zh-CN, zh-Hans, zh-Hans-CN, zh-SG, zh-MY...
        // Traditional Chinese locales (zh-TW / zh-HK / zh-Hant-*) fall through to English
        // since we don't have a Traditional translation yet.
        if lower == "zh"
            || lower.starts_with("zh-cn")
            || lower.starts_with("zh-hans")
            || lower.starts_with("zh-sg")
            || lower.starts_with("zh-my")
        {
            Lang::ZhHans
        } else {
            Lang::En
        }
    })
}

/// Look up a localized string by key. Falls back to the key itself if unknown,
/// which makes missing entries visible during development.
pub fn t(key: &str) -> &'static str {
    match lang() {
        Lang::En => en(key),
        Lang::ZhHans => zh_hans(key),
    }
}

fn en(key: &str) -> &'static str {
    match key {
        // Tray menu
        "tray.toggle"              => "Toggle Glance",
        "tray.resize_mode"         => "Resize Mode",
        "tray.resize.preserve"     => "Preserve Aspect Ratio",
        "tray.resize.clamp"        => "Clamp Max Width / Height",
        "tray.mru_glow"            => "Highlight recent thumbnails",
        "tray.quit"                => "Quit",

        // Work area surface
        "work_area.label"          => "Work Area",
        "work_area.exit"           => "\u{2715} Exit",
        "work_area.switch"         => "\u{21E5} Switch (Alt)",
        "work_area.unpin_left"     => "\u{2715} Unpin L",
        "work_area.unpin_right"    => "\u{2715} Unpin R",

        // Thumbnail overlay
        "overlay.active"           => "Active",
        "overlay.pinned"           => "Pinned",

        // Unknown keys render blank so regressions surface visibly in the UI.
        _ => "",
    }
}

fn zh_hans(key: &str) -> &'static str {
    match key {
        // Tray menu
        "tray.toggle"              => "切换 Glance",
        "tray.resize_mode"         => "缩放模式",
        "tray.resize.preserve"     => "保持宽高比",
        "tray.resize.clamp"        => "分别限制最大宽/高",
        "tray.mru_glow"            => "高亮最近使用的缩略图",
        "tray.quit"                => "退出",

        // Work area surface
        "work_area.label"          => "工作区",
        "work_area.exit"           => "\u{2715} 退出",
        "work_area.switch"         => "\u{21E5} 切换 (Alt)",
        "work_area.unpin_left"     => "\u{2715} 取消左固",
        "work_area.unpin_right"    => "\u{2715} 取消右固",

        // Thumbnail overlay
        "overlay.active"           => "当前",
        "overlay.pinned"           => "已固定",

        // Unknown keys fall back to English so nothing renders blank.
        other => en(other),
    }
}
