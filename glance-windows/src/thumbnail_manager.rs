//! DWM Thumbnail management for live window previews.
//!
//! Uses `DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` to create
//! hardware-accelerated, real-time thumbnails that DWM composites directly —
//! no polling or image capture needed.

use std::collections::HashMap;

/// Default header height in pixels (space reserved for the title bar overlay).
const DEFAULT_HEADER_HEIGHT: i32 = 32;

// ---------------------------------------------------------------------------
// ThumbnailRegistration
// ---------------------------------------------------------------------------

/// Tracks a single DWM thumbnail registration.
pub struct ThumbnailRegistration {
    /// DWM thumbnail handle (`HTHUMBNAIL` is `isize` in windows-rs 0.58).
    pub handle: isize,
    /// Window being thumbnailed.
    pub source_hwnd: isize,
    /// Overlay window showing the thumbnail.
    pub destination_hwnd: isize,
}

// ===========================================================================
// Windows implementation
// ===========================================================================
#[cfg(windows)]
mod platform {
    use super::*;
    use windows::Win32::Foundation::{BOOL, HWND, RECT};
    use windows::Win32::Graphics::Dwm::{
        DwmQueryThumbnailSourceSize, DwmRegisterThumbnail, DwmUnregisterThumbnail,
        DwmUpdateThumbnailProperties, DWM_THUMBNAIL_PROPERTIES, DWM_TNP_RECTDESTINATION,
        DWM_TNP_SOURCECLIENTAREAONLY, DWM_TNP_VISIBLE,
    };

    /// Convert a raw `isize` handle to an `HWND`.
    fn hwnd_from_isize(raw: isize) -> HWND {
        HWND(raw as *mut core::ffi::c_void)
    }

    /// Register a DWM thumbnail from source window into destination window.
    /// Returns `Some(ThumbnailRegistration)` on success.
    pub fn register(
        source_hwnd: isize,
        destination_hwnd: isize,
        dest_width: i32,
        dest_height: i32,
    ) -> Option<ThumbnailRegistration> {
        let dest = hwnd_from_isize(destination_hwnd);
        let src = hwnd_from_isize(source_hwnd);

        let handle = unsafe { DwmRegisterThumbnail(dest, src) };
        let handle = match handle {
            Ok(h) => h,
            Err(e) => {
                log::warn!(
                    "DwmRegisterThumbnail failed for source={source_hwnd:#x} dest={destination_hwnd:#x}: {e}"
                );
                return None;
            }
        };

        // Set initial thumbnail properties — image fills the area below the
        // default header.
        let props = DWM_THUMBNAIL_PROPERTIES {
            dwFlags: DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_SOURCECLIENTAREAONLY,
            rcDestination: RECT {
                left: 0,
                top: DEFAULT_HEADER_HEIGHT,
                right: dest_width,
                bottom: dest_height,
            },
            fVisible: BOOL::from(true),
            fSourceClientAreaOnly: BOOL::from(true),
            ..Default::default()
        };

        let result = unsafe { DwmUpdateThumbnailProperties(handle, &props) };
        if let Err(e) = result {
            log::warn!(
                "DwmUpdateThumbnailProperties failed for source={source_hwnd:#x}: {e}"
            );
            // Clean up the handle we just registered.
            let _ = unsafe { DwmUnregisterThumbnail(handle) };
            return None;
        }

        Some(ThumbnailRegistration {
            handle,
            source_hwnd,
            destination_hwnd,
        })
    }

    /// Update the destination rectangle for an existing thumbnail.
    pub fn update_position(
        reg: &ThumbnailRegistration,
        dest_width: i32,
        dest_height: i32,
        header_height: i32,
    ) {
        let props = DWM_THUMBNAIL_PROPERTIES {
            dwFlags: DWM_TNP_RECTDESTINATION,
            rcDestination: RECT {
                left: 0,
                top: header_height,
                right: dest_width,
                bottom: dest_height,
            },
            ..Default::default()
        };

        if let Err(e) = unsafe { DwmUpdateThumbnailProperties(reg.handle, &props) } {
            log::warn!(
                "DwmUpdateThumbnailProperties failed for source={:#x}: {e}",
                reg.source_hwnd
            );
        }
    }

    /// Unregister a DWM thumbnail.
    pub fn unregister(handle: isize) {
        if let Err(e) = unsafe { DwmUnregisterThumbnail(handle) } {
            log::warn!("DwmUnregisterThumbnail failed for handle={handle:#x}: {e}");
        }
    }

    /// Query the source window dimensions for a registered thumbnail.
    pub fn get_source_size(handle: isize) -> Option<(i32, i32)> {
        match unsafe { DwmQueryThumbnailSourceSize(handle) } {
            Ok(size) => Some((size.cx, size.cy)),
            Err(e) => {
                log::warn!(
                    "DwmQueryThumbnailSourceSize failed for handle={handle:#x}: {e}"
                );
                None
            }
        }
    }
}

// ===========================================================================
// Non-Windows stubs (for cross-compilation / CI)
// ===========================================================================
#[cfg(not(windows))]
mod platform {
    use super::*;

    pub fn register(
        _source_hwnd: isize,
        _destination_hwnd: isize,
        _dest_width: i32,
        _dest_height: i32,
    ) -> Option<ThumbnailRegistration> {
        None
    }

    pub fn update_position(
        _reg: &ThumbnailRegistration,
        _dest_width: i32,
        _dest_height: i32,
        _header_height: i32,
    ) {
    }

    pub fn unregister(_handle: isize) {}

    pub fn get_source_size(_handle: isize) -> Option<(i32, i32)> {
        None
    }
}

// ===========================================================================
// ThumbnailManager — public API
// ===========================================================================

/// Manages DWM thumbnail registrations for all tracked windows.
///
/// Each thumbnail maps a source window into a destination overlay window.
/// DWM composites the live content automatically — no polling required.
pub struct ThumbnailManager {
    /// Active registrations keyed by source window handle.
    registrations: HashMap<isize, ThumbnailRegistration>,
}

impl ThumbnailManager {
    pub fn new() -> Self {
        Self {
            registrations: HashMap::new(),
        }
    }

    /// Register a DWM thumbnail from source window into destination overlay
    /// window. The thumbnail renders in the area below the 32px header.
    ///
    /// Returns `true` if registration succeeded.
    pub fn register(
        &mut self,
        source_hwnd: isize,
        destination_hwnd: isize,
        dest_width: i32,
        dest_height: i32,
    ) -> bool {
        // Unregister any existing thumbnail for this source first.
        if self.registrations.contains_key(&source_hwnd) {
            self.unregister(source_hwnd);
        }

        match platform::register(source_hwnd, destination_hwnd, dest_width, dest_height) {
            Some(reg) => {
                self.registrations.insert(source_hwnd, reg);
                true
            }
            None => false,
        }
    }

    /// Update the destination rectangle for an existing thumbnail
    /// (called when overlay window is repositioned/resized).
    /// `header_height` is the space reserved at top for the title (32px).
    pub fn update_position(
        &self,
        source_hwnd: isize,
        dest_width: i32,
        dest_height: i32,
        header_height: i32,
    ) {
        if let Some(reg) = self.registrations.get(&source_hwnd) {
            platform::update_position(reg, dest_width, dest_height, header_height);
        }
    }

    /// Unregister a single thumbnail.
    pub fn unregister(&mut self, source_hwnd: isize) {
        if let Some(reg) = self.registrations.remove(&source_hwnd) {
            platform::unregister(reg.handle);
        }
    }

    /// Unregister all thumbnails.
    pub fn unregister_all(&mut self) {
        let handles: Vec<isize> = self
            .registrations
            .values()
            .map(|r| r.handle)
            .collect();
        for handle in handles {
            platform::unregister(handle);
        }
        self.registrations.clear();
    }

    /// Check if a source window has a registered thumbnail.
    pub fn is_registered(&self, source_hwnd: isize) -> bool {
        self.registrations.contains_key(&source_hwnd)
    }

    /// Get the source size of a thumbnailed window (useful for aspect ratio).
    /// Uses `DwmQueryThumbnailSourceSize` to get the source window dimensions.
    pub fn get_source_size(&self, source_hwnd: isize) -> Option<(i32, i32)> {
        self.registrations
            .get(&source_hwnd)
            .and_then(|reg| platform::get_source_size(reg.handle))
    }
}

impl Drop for ThumbnailManager {
    fn drop(&mut self) {
        self.unregister_all();
    }
}
