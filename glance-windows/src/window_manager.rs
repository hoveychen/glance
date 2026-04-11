//! Window manipulation helpers wrapping Win32 APIs.
//!
//! Provides move, resize, focus, show/hide, topmost, icon retrieval, and
//! process-name lookup — the equivalent of macOS `AccessibilityManager` but
//! without needing special permissions.

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod platform {
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, WPARAM};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        BringWindowToTop, GetClassLongPtrW, GetForegroundWindow, IsIconic, SendMessageTimeoutW,
        SetForegroundWindow, SetWindowPos, ShowWindow, GCLP_HICON, HWND_NOTOPMOST, HWND_TOPMOST,
        ICON_BIG, ICON_SMALL, SMTO_ABORTIFHUNG, SW_HIDE, SW_RESTORE, SW_SHOW, SWP_NOACTIVATE,
        SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, WM_GETICON,
    };
    use windows::Win32::UI::WindowsAndMessaging::HICON;

    /// Convert a raw `isize` handle to an `HWND`.
    fn hwnd_from_isize(raw: isize) -> HWND {
        HWND(raw as *mut core::ffi::c_void)
    }

    /// Move and resize a window.
    ///
    /// Uses `SetWindowPos` with `SWP_NOZORDER | SWP_NOACTIVATE` so the
    /// window's z-order and activation state are not disturbed.
    pub fn move_window(hwnd: isize, x: i32, y: i32, width: i32, height: i32) -> bool {
        let h = hwnd_from_isize(hwnd);
        unsafe {
            SetWindowPos(h, HWND::default(), x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE)
                .is_ok()
        }
    }

    /// Bring a window to the foreground.
    ///
    /// If the window is minimized it is restored first.  Falls back to
    /// `BringWindowToTop` when `SetForegroundWindow` reports failure.
    pub fn focus_window(hwnd: isize) -> bool {
        let h = hwnd_from_isize(hwnd);
        unsafe {
            // Restore minimized windows first.
            if IsIconic(h).as_bool() {
                let _ = ShowWindow(h, SW_RESTORE);
            }

            if SetForegroundWindow(h).as_bool() {
                return true;
            }

            // Fallback.
            BringWindowToTop(h).is_ok()
        }
    }

    /// Set or clear the always-on-top flag for a window.
    pub fn set_window_topmost(hwnd: isize, topmost: bool) -> bool {
        let h = hwnd_from_isize(hwnd);
        let insert_after = if topmost { HWND_TOPMOST } else { HWND_NOTOPMOST };
        unsafe {
            SetWindowPos(h, insert_after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
                .is_ok()
        }
    }

    /// Hide a window (`SW_HIDE`).
    pub fn hide_window(hwnd: isize) {
        let h = hwnd_from_isize(hwnd);
        unsafe {
            let _ = ShowWindow(h, SW_HIDE);
        }
    }

    /// Show a window (`SW_SHOW`).
    pub fn show_window(hwnd: isize) {
        let h = hwnd_from_isize(hwnd);
        unsafe {
            let _ = ShowWindow(h, SW_SHOW);
        }
    }

    /// Return the handle of the current foreground window, if any.
    pub fn get_foreground_window() -> Option<isize> {
        let h = unsafe { GetForegroundWindow() };
        if h.is_invalid() || h.0.is_null() {
            None
        } else {
            Some(h.0 as isize)
        }
    }

    /// Try to obtain the application icon for a window.
    ///
    /// Attempts, in order:
    /// 1. `WM_GETICON` with `ICON_BIG`
    /// 2. `GetClassLongPtrW(GCLP_HICON)`
    /// 3. `WM_GETICON` with `ICON_SMALL`
    pub fn get_window_icon(hwnd: isize) -> Option<HICON> {
        let h = hwnd_from_isize(hwnd);
        const TIMEOUT_MS: u32 = 100;

        // Helper: send WM_GETICON and return an HICON if non-null.
        let send_get_icon = |icon_type: u32| -> Option<HICON> {
            let mut result: usize = 0;
            unsafe {
                SendMessageTimeoutW(
                    h,
                    WM_GETICON,
                    WPARAM(icon_type as usize),
                    LPARAM(0),
                    SMTO_ABORTIFHUNG,
                    TIMEOUT_MS,
                    Some(&mut result),
                );
            }
            if result != 0 {
                Some(HICON(result as *mut core::ffi::c_void))
            } else {
                None
            }
        };

        // 1. Big icon via WM_GETICON.
        if let Some(icon) = send_get_icon(ICON_BIG) {
            return Some(icon);
        }

        // 2. Class icon.
        let class_icon = unsafe { GetClassLongPtrW(h, GCLP_HICON) };
        if class_icon != 0 {
            return Some(HICON(class_icon as *mut core::ffi::c_void));
        }

        // 3. Small icon via WM_GETICON.
        send_get_icon(ICON_SMALL)
    }

    /// Retrieve the executable filename (e.g. `"chrome.exe"`) for a process.
    pub fn get_process_name(pid: u32) -> Option<String> {
        unsafe {
            let handle =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;

            let mut buf = [0u16; 1024];
            let mut size = buf.len() as u32;
            let result = QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                windows::core::PWSTR(buf.as_mut_ptr()),
                &mut size,
            );
            let _ = CloseHandle(handle);

            result.ok()?;

            let full_path = String::from_utf16_lossy(&buf[..size as usize]);
            // Extract filename from the full path.
            full_path
                .rsplit('\\')
                .next()
                .map(|s| s.to_string())
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stubs (for cross-compilation / CI)
// ---------------------------------------------------------------------------
#[cfg(not(windows))]
mod platform {
    use crate::types::HICON;

    pub fn move_window(_hwnd: isize, _x: i32, _y: i32, _width: i32, _height: i32) -> bool {
        false
    }

    pub fn focus_window(_hwnd: isize) -> bool {
        false
    }

    pub fn set_window_topmost(_hwnd: isize, _topmost: bool) -> bool {
        false
    }

    pub fn hide_window(_hwnd: isize) {}

    pub fn show_window(_hwnd: isize) {}

    pub fn get_foreground_window() -> Option<isize> {
        None
    }

    pub fn get_window_icon(_hwnd: isize) -> Option<HICON> {
        None
    }

    pub fn get_process_name(_pid: u32) -> Option<String> {
        None
    }
}

// ---------------------------------------------------------------------------
// Re-export the platform-appropriate HICON for the public API
// ---------------------------------------------------------------------------
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::HICON;
#[cfg(not(windows))]
use crate::types::HICON;

// ---------------------------------------------------------------------------
// Public API — thin wrapper struct for future extensibility
// ---------------------------------------------------------------------------

/// High-level handle to the window manipulation subsystem.
///
/// Currently stateless — all methods delegate to free functions — but the
/// struct exists so callers can pass it around and we can add caching or
/// configuration later without changing call sites.
pub struct WindowManager;

impl WindowManager {
    pub fn new() -> Self {
        Self
    }

    /// Move and resize a window to the given screen coordinates.
    pub fn move_window(&self, hwnd: isize, x: i32, y: i32, width: i32, height: i32) -> bool {
        platform::move_window(hwnd, x, y, width, height)
    }

    /// Bring a window to the foreground (restoring it if minimized).
    pub fn focus_window(&self, hwnd: isize) -> bool {
        platform::focus_window(hwnd)
    }

    /// Set or clear the always-on-top flag.
    pub fn set_window_topmost(&self, hwnd: isize, topmost: bool) -> bool {
        platform::set_window_topmost(hwnd, topmost)
    }

    /// Hide a window.
    pub fn hide_window(&self, hwnd: isize) {
        platform::hide_window(hwnd)
    }

    /// Show a previously hidden window.
    pub fn show_window(&self, hwnd: isize) {
        platform::show_window(hwnd)
    }

    /// Return the handle of the current foreground window, if any.
    pub fn get_foreground_window(&self) -> Option<isize> {
        platform::get_foreground_window()
    }

    /// Obtain the application icon for a window.
    pub fn get_window_icon(&self, hwnd: isize) -> Option<HICON> {
        platform::get_window_icon(hwnd)
    }

    /// Get the executable filename for a process ID.
    pub fn get_process_name(&self, pid: u32) -> Option<String> {
        platform::get_process_name(pid)
    }
}

// Also expose the free functions at module level for callers that don't need
// the struct.
pub use platform::focus_window;
pub use platform::get_foreground_window;
pub use platform::get_process_name;
pub use platform::get_window_icon;
pub use platform::hide_window;
pub use platform::move_window;
pub use platform::set_window_topmost;
pub use platform::show_window;
