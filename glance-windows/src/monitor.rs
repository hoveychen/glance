use crate::types::{Rect, ScreenRegion};

// ---------------------------------------------------------------------------
// MonitorInfo
// ---------------------------------------------------------------------------

/// Snapshot of a single display/monitor.
#[derive(Debug, Clone)]
pub struct MonitorInfo {
    /// Raw `HMONITOR` handle (as `isize` for hashing/equality).
    pub handle: isize,
    /// Device name (e.g. `\\.\DISPLAY1`).
    pub name: String,
    /// Full monitor bounds in virtual-screen coordinates.
    pub frame: Rect,
    /// Usable area excluding the taskbar and other app bars.
    pub work_area: Rect,
    /// Whether this is the primary monitor (top-left at 0,0).
    pub is_primary: bool,
    /// DPI scale factor (1.0 = 96 DPI, 1.25 = 120 DPI, 1.5 = 144 DPI, …).
    pub dpi_scale: f64,
    /// Sequential index assigned after sorting left-to-right, top-to-bottom.
    pub index: usize,
}

// ---------------------------------------------------------------------------
// MonitorManager
// ---------------------------------------------------------------------------

/// Manages a cached list of monitors and provides lookup helpers.
pub struct MonitorManager {
    monitors: Vec<MonitorInfo>,
}

impl MonitorManager {
    /// Create a new `MonitorManager`, enumerating all connected monitors.
    pub fn new() -> Self {
        Self {
            monitors: enumerate_monitors(),
        }
    }

    /// Re-enumerate monitors (call after a display-change event).
    pub fn refresh(&mut self) {
        self.monitors = enumerate_monitors();
    }

    /// All monitors, sorted left-to-right then top-to-bottom.
    pub fn monitors(&self) -> &[MonitorInfo] {
        &self.monitors
    }

    /// The primary monitor, if any.
    pub fn primary(&self) -> Option<&MonitorInfo> {
        self.monitors.iter().find(|m| m.is_primary)
    }

    /// Look up a monitor by its sequential `index`.
    pub fn monitor_at(&self, index: usize) -> Option<&MonitorInfo> {
        self.monitors.iter().find(|m| m.index == index)
    }

    /// Convert the monitor list into `ScreenRegion`s for the layout engine.
    ///
    /// * `excluded_rect` — the main window frame to carve out (if any).
    /// * `main_screen_index` — the screen the main window is on; the
    ///   `excluded_rect` is only applied to that screen.
    pub fn to_screen_regions(
        &self,
        excluded_rect: Option<&Rect>,
        main_screen_index: Option<usize>,
    ) -> Vec<ScreenRegion> {
        self.monitors
            .iter()
            .map(|m| {
                let excluded = match (excluded_rect, main_screen_index) {
                    (Some(rect), Some(idx)) if idx == m.index => Some(*rect),
                    _ => None,
                };
                ScreenRegion {
                    screen_index: m.index,
                    screen_frame: m.work_area,
                    excluded_rect: excluded,
                }
            })
            .collect()
    }
}

// ===========================================================================
// Windows implementation
// ===========================================================================

#[cfg(windows)]
mod platform {
    use super::*;
    use std::mem;
    use windows::Win32::Foundation::{BOOL, LPARAM, POINT, RECT};
    use windows::Win32::Graphics::Gdi::{
        EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFOEXW,
    };
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    use windows::Win32::UI::WindowsAndMessaging::{
        MONITORINFOF_PRIMARY, MONITOR_DEFAULTTONEAREST,
    };

    /// Convert a Win32 `RECT` (left/top/right/bottom, i32) to our `Rect`
    /// (x/y/width/height, f64).
    fn rect_from_win(r: &RECT) -> Rect {
        Rect::new(
            r.left as f64,
            r.top as f64,
            (r.right - r.left) as f64,
            (r.bottom - r.top) as f64,
        )
    }

    /// Callback for `EnumDisplayMonitors`. Collects monitor data into the
    /// `Vec<MonitorInfo>` whose pointer is carried in `lparam`.
    unsafe extern "system" fn enum_callback(
        hmonitor: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        lparam: LPARAM,
    ) -> BOOL {
        let monitors = &mut *(lparam.0 as *mut Vec<MonitorInfo>);

        let mut info: MONITORINFOEXW = mem::zeroed();
        info.monitorInfo.cbSize = mem::size_of::<MONITORINFOEXW>() as u32;

        if GetMonitorInfoW(hmonitor, &mut info as *mut MONITORINFOEXW as *mut _).as_bool() {
            let frame = rect_from_win(&info.monitorInfo.rcMonitor);
            let work_area = rect_from_win(&info.monitorInfo.rcWork);
            let is_primary = (info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY) != 0;

            // Device name — null-terminated UTF-16.
            let name_len = info
                .szDevice
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(info.szDevice.len());
            let name = String::from_utf16_lossy(&info.szDevice[..name_len]);

            // DPI — GetDpiForMonitor returns the effective DPI.
            let mut dpi_x: u32 = 96;
            let mut dpi_y: u32 = 96;
            let _ = GetDpiForMonitor(hmonitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y);
            let dpi_scale = dpi_x as f64 / 96.0;

            monitors.push(MonitorInfo {
                handle: hmonitor.0 as isize,
                name,
                frame,
                work_area,
                is_primary,
                dpi_scale,
                index: 0, // assigned after sorting
            });
        }

        BOOL(1) // continue enumeration
    }

    /// Enumerate all connected monitors, sorted left-to-right then
    /// top-to-bottom, with sequential `index` values.
    pub fn enumerate_monitors_impl() -> Vec<MonitorInfo> {
        let mut monitors: Vec<MonitorInfo> = Vec::new();

        unsafe {
            let _ = EnumDisplayMonitors(
                None,
                None,
                Some(enum_callback),
                LPARAM(&mut monitors as *mut Vec<MonitorInfo> as isize),
            );
        }

        // Sort: primary key = left edge (ascending), secondary = top edge (ascending).
        monitors.sort_by(|a, b| {
            let x_cmp = a
                .frame
                .x
                .partial_cmp(&b.frame.x)
                .unwrap_or(std::cmp::Ordering::Equal);
            if x_cmp != std::cmp::Ordering::Equal {
                return x_cmp;
            }
            a.frame
                .y
                .partial_cmp(&b.frame.y)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Assign sequential indices.
        for (i, m) in monitors.iter_mut().enumerate() {
            m.index = i;
        }

        monitors
    }

    /// Find the monitor index for a given screen-coordinate point.
    pub fn monitor_from_point_impl(monitors: &[MonitorInfo], x: f64, y: f64) -> Option<usize> {
        use windows::Win32::Graphics::Gdi::MonitorFromPoint;

        let point = POINT {
            x: x.round() as i32,
            y: y.round() as i32,
        };
        let hmon = unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) };
        let handle = hmon.0 as isize;
        monitors.iter().find(|m| m.handle == handle).map(|m| m.index)
    }

    /// Find the monitor index for the monitor containing the given window.
    pub fn monitor_from_window_impl(monitors: &[MonitorInfo], hwnd: isize) -> Option<usize> {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Graphics::Gdi::MonitorFromWindow;

        let hmon =
            unsafe { MonitorFromWindow(HWND(hwnd as *mut _), MONITOR_DEFAULTTONEAREST) };
        let handle = hmon.0 as isize;
        monitors.iter().find(|m| m.handle == handle).map(|m| m.index)
    }
}

// ===========================================================================
// Non-Windows stubs (for cross-compilation / CI)
// ===========================================================================

#[cfg(not(windows))]
mod platform {
    use super::*;

    pub fn enumerate_monitors_impl() -> Vec<MonitorInfo> {
        // Return a single fake primary monitor for testing on non-Windows.
        vec![MonitorInfo {
            handle: 0,
            name: String::from("\\\\.\\DISPLAY1"),
            frame: Rect::new(0.0, 0.0, 1920.0, 1080.0),
            work_area: Rect::new(0.0, 0.0, 1920.0, 1040.0),
            is_primary: true,
            dpi_scale: 1.0,
            index: 0,
        }]
    }

    pub fn monitor_from_point_impl(monitors: &[MonitorInfo], x: f64, y: f64) -> Option<usize> {
        // Simple hit-test against monitor frames.
        monitors
            .iter()
            .find(|m| m.frame.contains_point(x, y))
            .map(|m| m.index)
    }

    pub fn monitor_from_window_impl(_monitors: &[MonitorInfo], _hwnd: isize) -> Option<usize> {
        // No real implementation on non-Windows; return primary (index 0).
        Some(0)
    }
}

// ---------------------------------------------------------------------------
// Public API (delegates to the platform module)
// ---------------------------------------------------------------------------

/// Enumerate all connected monitors.
pub fn enumerate_monitors() -> Vec<MonitorInfo> {
    platform::enumerate_monitors_impl()
}

/// Find the monitor index for a screen-coordinate point.
///
/// Uses the current `MonitorManager`'s cached list; for a one-shot query,
/// prefer `MonitorManager::monitor_at` or call this after `enumerate_monitors`.
pub fn monitor_from_point(x: f64, y: f64) -> Option<usize> {
    let monitors = enumerate_monitors();
    platform::monitor_from_point_impl(&monitors, x, y)
}

/// Find the monitor index for the monitor a window is on.
pub fn monitor_from_window(hwnd: isize) -> Option<usize> {
    let monitors = enumerate_monitors();
    platform::monitor_from_window_impl(&monitors, hwnd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enumerate_returns_at_least_one() {
        let monitors = enumerate_monitors();
        assert!(!monitors.is_empty(), "should enumerate at least one monitor");
    }

    #[test]
    fn indices_are_sequential() {
        let monitors = enumerate_monitors();
        for (i, m) in monitors.iter().enumerate() {
            assert_eq!(m.index, i, "monitor index should match position");
        }
    }

    #[test]
    fn has_primary() {
        let monitors = enumerate_monitors();
        assert!(
            monitors.iter().any(|m| m.is_primary),
            "should have a primary monitor"
        );
    }

    #[test]
    fn manager_basics() {
        let mgr = MonitorManager::new();
        assert!(!mgr.monitors().is_empty());
        assert!(mgr.primary().is_some());
        assert!(mgr.monitor_at(0).is_some());
    }

    #[test]
    fn to_screen_regions_no_exclusion() {
        let mgr = MonitorManager::new();
        let regions = mgr.to_screen_regions(None, None);
        assert_eq!(regions.len(), mgr.monitors().len());
        for r in &regions {
            assert!(r.excluded_rect.is_none());
        }
    }

    #[test]
    fn to_screen_regions_with_exclusion() {
        let mgr = MonitorManager::new();
        let excl = Rect::new(100.0, 100.0, 800.0, 600.0);
        let regions = mgr.to_screen_regions(Some(&excl), Some(0));
        // The primary screen (index 0) should have the exclusion.
        let primary_region = regions.iter().find(|r| r.screen_index == 0).unwrap();
        assert!(primary_region.excluded_rect.is_some());
        // Other screens should not.
        for r in regions.iter().filter(|r| r.screen_index != 0) {
            assert!(r.excluded_rect.is_none());
        }
    }

    #[test]
    fn monitor_from_point_finds_primary() {
        // The primary monitor always contains (0, 0) in Windows coordinate space.
        // On non-Windows stubs, the fake monitor covers (0,0)–(1920,1080).
        let result = monitor_from_point(100.0, 100.0);
        assert!(result.is_some());
    }

    #[test]
    fn dpi_scale_is_positive() {
        let monitors = enumerate_monitors();
        for m in &monitors {
            assert!(m.dpi_scale > 0.0, "DPI scale should be positive");
        }
    }
}
