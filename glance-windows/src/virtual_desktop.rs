use crate::types::Rect;
use std::collections::HashSet;

// ---------------------------------------------------------------------------
// VirtualDesktopManager — thin wrapper around IVirtualDesktopManager COM
// ---------------------------------------------------------------------------

/// Wraps the `IVirtualDesktopManager` COM interface for virtual desktop
/// operations.  Only the documented (stable) API surface is used:
///
/// - Check if a window is on the current virtual desktop
/// - Get the desktop GUID for a window
/// - Move a window to a specific desktop
///
/// Creating / enumerating / switching desktops requires the undocumented
/// `IVirtualDesktopManagerInternal` which changes between Windows builds —
/// that is intentionally left out.
#[cfg(windows)]
pub struct VirtualDesktopManager {
    manager: windows::Win32::UI::Shell::IVirtualDesktopManager,
}

#[cfg(windows)]
impl VirtualDesktopManager {
    /// Initialise COM (apartment-threaded) and create the manager instance.
    pub fn new() -> Result<Self, String> {
        unsafe {
            use windows::Win32::System::Com::{
                CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_APARTMENTTHREADED,
            };
            use windows::Win32::UI::Shell::{IVirtualDesktopManager, VirtualDesktopManager};

            let hr = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            // S_OK (0) or S_FALSE (1, already initialised) are both acceptable.
            if hr.is_err() {
                return Err(format!("CoInitializeEx failed: {hr:?}"));
            }

            let mgr: IVirtualDesktopManager =
                CoCreateInstance(&VirtualDesktopManager, None, CLSCTX_ALL)
                    .map_err(|e| format!("CoCreateInstance(VirtualDesktopManager) failed: {e}"))?;

            Ok(Self { manager: mgr })
        }
    }

    /// Returns `true` if the window is on the currently active virtual desktop.
    pub fn is_on_current_desktop(&self, hwnd: isize) -> bool {
        unsafe {
            use windows::Win32::Foundation::HWND;
            let hwnd = HWND(hwnd as *mut _);
            self.manager
                .IsWindowOnCurrentVirtualDesktop(hwnd)
                .map(|b| b.0 != 0)
                .unwrap_or(false)
        }
    }

    /// Returns the GUID of the virtual desktop the window belongs to, or
    /// `None` if the call fails (e.g. invalid handle).
    pub fn get_window_desktop_id(&self, hwnd: isize) -> Option<windows::core::GUID> {
        unsafe {
            use windows::Win32::Foundation::HWND;
            let hwnd = HWND(hwnd as *mut _);
            self.manager.GetWindowDesktopId(hwnd).ok()
        }
    }

    /// Move a window to the desktop identified by `desktop_id`.
    /// Returns `true` on success.
    pub fn move_window_to_desktop(&self, hwnd: isize, desktop_id: &windows::core::GUID) -> bool {
        unsafe {
            use windows::Win32::Foundation::HWND;
            let hwnd = HWND(hwnd as *mut _);
            self.manager
                .MoveWindowToDesktop(hwnd, desktop_id as *const _)
                .is_ok()
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stub — allows the rest of the crate to compile on macOS / CI.
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
pub struct VirtualDesktopManager;

#[cfg(not(windows))]
impl VirtualDesktopManager {
    pub fn new() -> Result<Self, String> {
        Err("VirtualDesktopManager is only available on Windows".into())
    }

    pub fn is_on_current_desktop(&self, _hwnd: isize) -> bool {
        false
    }

    pub fn get_window_desktop_id(&self, _hwnd: isize) -> Option<GuidStub> {
        None
    }

    pub fn move_window_to_desktop(&self, _hwnd: isize, _desktop_id: &GuidStub) -> bool {
        false
    }
}

/// Lightweight stand-in for `windows::core::GUID` on non-Windows platforms.
#[cfg(not(windows))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GuidStub {
    pub data1: u32,
    pub data2: u16,
    pub data3: u16,
    pub data4: [u8; 8],
}

// Re-export the GUID type so callers can be platform-agnostic.
#[cfg(windows)]
pub type DesktopId = windows::core::GUID;
#[cfg(not(windows))]
pub type DesktopId = GuidStub;

// ---------------------------------------------------------------------------
// Off-screen positioning helpers
// ---------------------------------------------------------------------------

/// Move a window to a unique off-screen position.
///
/// Each slot gets a distinct X offset so windows don't stack at the exact same
/// coordinate (some apps behave badly when fully overlapping off-screen).
///
/// Position formula: `(-32000 + slot * 100, -32000)`.
#[cfg(windows)]
pub fn park_window_offscreen(hwnd: isize, slot: usize) {
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            SetWindowPos, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER,
        };

        let x = -32000 + (slot as i32) * 100;
        let y = -32000i32;
        let hwnd = HWND(hwnd as *mut _);
        let flags = SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE;
        let _ = SetWindowPos(hwnd, None, x, y, 0, 0, flags);
    }
}

#[cfg(not(windows))]
pub fn park_window_offscreen(_hwnd: isize, _slot: usize) {}

/// Restore a window from off-screen to its original position and size.
#[cfg(windows)]
pub fn unpark_window_from_offscreen(hwnd: isize, original_rect: &Rect) {
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER};

        let hwnd = HWND(hwnd as *mut _);
        let flags = SWP_NOZORDER | SWP_NOACTIVATE;
        let _ = SetWindowPos(
            hwnd,
            None,
            original_rect.x.round() as i32,
            original_rect.y.round() as i32,
            original_rect.width.round() as i32,
            original_rect.height.round() as i32,
            flags,
        );
    }
}

#[cfg(not(windows))]
pub fn unpark_window_from_offscreen(_hwnd: isize, _original_rect: &Rect) {}

// ---------------------------------------------------------------------------
// ParkingManager — high-level window-parking abstraction
// ---------------------------------------------------------------------------

/// Higher-level manager that parks (hides) windows by moving them to a
/// secondary virtual desktop, falling back to off-screen positioning when
/// the COM interface is unavailable.
///
/// # Usage
///
/// The user must have at least **two** virtual desktops configured in Windows
/// (Win+Tab → "New desktop"). The manager detects the current desktop as
/// "main" and uses the desktop ID of the first parked window's *target* as
/// the parking desktop.
///
/// If COM initialisation fails (e.g. running on an older Windows version or
/// in a restricted environment), parking transparently falls back to moving
/// windows off-screen at `(-32000 + slot*100, -32000)`.
pub struct ParkingManager {
    /// `None` when COM init failed — triggers the off-screen fallback.
    vdm: Option<VirtualDesktopManager>,
    /// Desktop GUID of the "main" (visible) desktop, lazily detected.
    main_desktop_id: Option<DesktopId>,
    /// Desktop GUID used as the parking destination.
    /// Must be set by the caller via `set_parking_desktop` or auto-detected.
    parking_desktop_id: Option<DesktopId>,
    /// Set of window handles currently parked.
    parked: HashSet<isize>,
    /// Original rects for windows parked via the off-screen fallback, keyed
    /// by hwnd. Used to restore position on unpark.
    offscreen_originals: std::collections::HashMap<isize, Rect>,
    /// Monotonically increasing slot counter for off-screen parking positions.
    next_slot: usize,
}

impl ParkingManager {
    /// Create a new parking manager.
    ///
    /// If the `VirtualDesktopManager` COM object cannot be created the manager
    /// will silently fall back to off-screen positioning.
    pub fn new() -> Result<Self, String> {
        let vdm = VirtualDesktopManager::new().ok();
        Ok(Self {
            vdm,
            main_desktop_id: None,
            parking_desktop_id: None,
            parked: HashSet::new(),
            offscreen_originals: std::collections::HashMap::new(),
            next_slot: 0,
        })
    }

    /// Explicitly set the parking desktop GUID.
    ///
    /// Call this if you know the target desktop ID ahead of time (e.g. read
    /// from config).
    pub fn set_parking_desktop(&mut self, id: DesktopId) {
        self.parking_desktop_id = Some(id);
    }

    /// Park a window — move it to the parking desktop (or off-screen).
    ///
    /// Returns `true` if the window was successfully parked.
    pub fn park_window(&mut self, hwnd: isize) -> bool {
        if self.parked.contains(&hwnd) {
            return true; // already parked
        }

        if let Some(ref vdm) = self.vdm {
            // Lazily detect the main desktop from the first window we see.
            if self.main_desktop_id.is_none() {
                if let Some(id) = vdm.get_window_desktop_id(hwnd) {
                    self.main_desktop_id = Some(id);
                }
            }

            if let Some(ref parking_id) = self.parking_desktop_id {
                if vdm.move_window_to_desktop(hwnd, parking_id) {
                    self.parked.insert(hwnd);
                    return true;
                }
            }

            // No parking desktop set or move failed — fall through to
            // off-screen fallback.
            log::warn!(
                "Virtual desktop move failed for hwnd {hwnd:#x}, \
                 falling back to off-screen positioning"
            );
        }

        // Off-screen fallback
        self.park_offscreen(hwnd)
    }

    /// Unpark a window — move it back to the main desktop (or restore from
    /// off-screen).
    ///
    /// Returns `true` if the window was successfully unparked.
    pub fn unpark_window(&mut self, hwnd: isize) -> bool {
        if !self.parked.contains(&hwnd) {
            return false; // not parked
        }

        // Try restoring from off-screen first (covers the fallback case).
        if let Some(original) = self.offscreen_originals.remove(&hwnd) {
            unpark_window_from_offscreen(hwnd, &original);
            self.parked.remove(&hwnd);
            return true;
        }

        // Virtual desktop path
        if let Some(ref vdm) = self.vdm {
            if let Some(ref main_id) = self.main_desktop_id {
                if vdm.move_window_to_desktop(hwnd, main_id) {
                    self.parked.remove(&hwnd);
                    return true;
                }
            }
        }

        log::warn!("Failed to unpark hwnd {hwnd:#x}");
        false
    }

    /// Check whether a window is currently parked.
    pub fn is_parked(&self, hwnd: isize) -> bool {
        self.parked.contains(&hwnd)
    }

    /// The set of all currently parked window handles.
    pub fn parked_windows(&self) -> &HashSet<isize> {
        &self.parked
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Fallback: save the window's current rect and move it off-screen.
    fn park_offscreen(&mut self, hwnd: isize) -> bool {
        let original = get_window_rect(hwnd);
        self.next_slot += 1;
        let slot = self.next_slot;
        self.offscreen_originals.insert(hwnd, original);
        park_window_offscreen(hwnd, slot);
        self.parked.insert(hwnd);
        true
    }
}

// ---------------------------------------------------------------------------
// Helper: read the current RECT for a window
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn get_window_rect(hwnd: isize) -> Rect {
    unsafe {
        use windows::Win32::Foundation::{HWND, RECT};
        use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;

        let hwnd = HWND(hwnd as *mut _);
        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_ok() {
            Rect::new(
                rect.left as f64,
                rect.top as f64,
                (rect.right - rect.left) as f64,
                (rect.bottom - rect.top) as f64,
            )
        } else {
            Rect::new(0.0, 0.0, 800.0, 600.0) // sensible default
        }
    }
}

#[cfg(not(windows))]
fn get_window_rect(_hwnd: isize) -> Rect {
    Rect::new(0.0, 0.0, 800.0, 600.0)
}
