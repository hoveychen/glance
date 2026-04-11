// On Windows, pull in the real Win32 types. On other platforms (for
// cross-compilation / CI), provide lightweight stand-ins so the layout
// engine and core types still compile.

#[cfg(windows)]
use windows::Win32::Foundation::RECT as WinRECT;
#[cfg(windows)]
pub use windows::Win32::UI::WindowsAndMessaging::HICON;

/// Lightweight stand-in for Win32 `RECT` on non-Windows platforms.
#[cfg(not(windows))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WinRECT {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

/// Lightweight stand-in for Win32 `HICON` on non-Windows platforms.
#[cfg(not(windows))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HICON(pub isize);

// ---------------------------------------------------------------------------
// Rect — f64 rectangle for layout math
// ---------------------------------------------------------------------------

/// A rectangle with f64 fields for precise layout calculations.
/// Windows RECT uses i32 (left, top, right, bottom) which is too imprecise
/// for layout math. This struct uses (x, y, width, height) like CGRect.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }

    pub fn min_y(&self) -> f64 {
        self.y
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn width(&self) -> f64 {
        self.width
    }

    pub fn height(&self) -> f64 {
        self.height
    }

    /// Inset the rect by (dx, dy) on each side.
    pub fn inset_by(&self, dx: f64, dy: f64) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            width: (self.width - 2.0 * dx).max(0.0),
            height: (self.height - 2.0 * dy).max(0.0),
        }
    }

    /// Compute the intersection of two rectangles.
    /// Returns `None` if they do not overlap.
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x1 = self.min_x().max(other.min_x());
        let y1 = self.min_y().max(other.min_y());
        let x2 = self.max_x().min(other.max_x());
        let y2 = self.max_y().min(other.max_y());

        let w = x2 - x1;
        let h = y2 - y1;

        if w > 0.0 && h > 0.0 {
            Some(Rect::new(x1, y1, w, h))
        } else {
            None
        }
    }

    /// Check if a point lies within this rect.
    pub fn contains_point(&self, px: f64, py: f64) -> bool {
        px >= self.min_x() && px <= self.max_x() && py >= self.min_y() && py <= self.max_y()
    }

    /// Convert to a Win32 RECT (i32, left/top/right/bottom).
    pub fn to_win_rect(&self) -> WinRECT {
        WinRECT {
            left: self.x.round() as i32,
            top: self.y.round() as i32,
            right: self.max_x().round() as i32,
            bottom: self.max_y().round() as i32,
        }
    }
}

// ---------------------------------------------------------------------------
// WindowClassification
// ---------------------------------------------------------------------------

/// Classification of a window based on its Win32 style flags.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WindowClassification {
    /// Regular application window.
    Normal,
    /// Dialog or preference window.
    Dialog,
    /// Floating panel, tooltip, or popup.
    Popup,
    /// System UI element.
    System,
    /// Could not be classified.
    Unknown,
}

// ---------------------------------------------------------------------------
// WindowInfo — per-window snapshot
// ---------------------------------------------------------------------------

/// A snapshot of a visible window, analogous to the macOS `WindowInfo`.
///
/// Key differences from the macOS version:
/// - `hwnd` replaces `windowID` (CGWindowID), stored as raw `isize`.
/// - No `latestImage` — the DWM Thumbnail API handles rendering directly.
/// - `classification` replaces the AX subrole string.
/// - `app_icon` is `Option<HICON>` instead of `CGImage`.
#[derive(Debug, Clone)]
pub struct WindowInfo {
    /// The Win32 window handle (raw isize for hashing/equality).
    pub hwnd: isize,
    /// Owner process ID.
    pub owner_pid: u32,
    /// Name of the owning process (e.g. "chrome.exe").
    pub owner_name: String,
    /// Window title text.
    pub title: String,
    /// Window frame in screen coordinates.
    pub frame: Rect,
    /// Whether the window is currently visible on-screen.
    pub is_on_screen: bool,
    /// Index of the monitor the window was originally on.
    pub original_screen_index: Option<usize>,
    /// Classification derived from window style flags.
    pub classification: WindowClassification,
    /// Window z-order / level.
    pub window_level: i32,
    /// Application icon handle.
    pub app_icon: Option<HICON>,
}

// ---------------------------------------------------------------------------
// WindowSlot — layout output
// ---------------------------------------------------------------------------

/// A positioned thumbnail slot produced by the layout engine.
#[derive(Debug, Clone)]
pub struct WindowSlot {
    /// Handle value that identifies the window.
    pub window_id: isize,
    /// Destination rectangle for this thumbnail.
    pub rect: Rect,
    /// Index of the screen this slot belongs to.
    pub screen_index: usize,
}

// ---------------------------------------------------------------------------
// ScreenRegion — layout input
// ---------------------------------------------------------------------------

/// Describes a monitor's usable area and optionally the main window to exclude.
#[derive(Debug, Clone)]
pub struct ScreenRegion {
    /// Index identifying this screen.
    pub screen_index: usize,
    /// The screen's visible/work-area frame.
    pub screen_frame: Rect,
    /// The main window frame to exclude, if it is on this screen.
    pub excluded_rect: Option<Rect>,
}

// ---------------------------------------------------------------------------
// WindowMetrics — layout input per window
// ---------------------------------------------------------------------------

/// Per-window metrics consumed by the layout engine.
#[derive(Debug, Clone)]
pub struct WindowMetrics {
    /// Handle value that identifies the window.
    pub window_id: isize,
    /// Aspect ratio (width / height).
    pub aspect_ratio: f64,
    /// Preferred screen index (the screen the window was originally on).
    pub original_screen_index: Option<usize>,
    /// Original window height in pixels (used to cap upscaling).
    pub original_height: f64,
    /// Whether the user manually assigned this window to a screen.
    pub is_manually_assigned: bool,
}
