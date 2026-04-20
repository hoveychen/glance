//! Swap-into-work-area resize policy.
//!
//! When a window is moved into Glance's work area, its size needs to be
//! reconciled with the work area's dimensions. Two policies are supported,
//! selectable from the system tray menu:
//!
//! * `PreserveAspectRatio` — uniform scale-down so the window fits without
//!   distortion (default; matches macOS).
//! * `ClampMax` — clip width and height independently to the work area.
//!
//! In both modes a window already smaller than the work area is left at its
//! native size; only over-sized windows are touched. The resulting frame is
//! always centered inside the work area.

use serde::{Deserialize, Serialize};

use crate::types::Rect;

/// Strategy for fitting a swapped-in window into the work area.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SwapResizeMode {
    /// Scale down uniformly to fit, keeping the original aspect ratio.
    PreserveAspectRatio,
    /// Clamp width and height independently to the work area's bounds.
    /// May distort the aspect ratio.
    ClampMax,
}

impl Default for SwapResizeMode {
    fn default() -> Self {
        Self::PreserveAspectRatio
    }
}

/// Pure geometry: fit a window of `(win_w, win_h)` into `work_area` according
/// to `mode`. The returned rect is always centered inside `work_area` and is
/// clamped to never exceed it.
pub fn compute_swap_target_frame(
    window_size: (f64, f64),
    work_area: Rect,
    mode: SwapResizeMode,
) -> Rect {
    let (mut w, mut h) = window_size;

    match mode {
        SwapResizeMode::PreserveAspectRatio => {
            if w > work_area.width {
                let s = work_area.width / w;
                w *= s;
                h *= s;
            }
            if h > work_area.height {
                let s = work_area.height / h;
                w *= s;
                h *= s;
            }
        }
        SwapResizeMode::ClampMax => {
            w = w.min(work_area.width);
            h = h.min(work_area.height);
        }
    }

    let x = work_area.x + (work_area.width  - w) / 2.0;
    let y = work_area.y + (work_area.height - h) / 2.0;
    Rect::new(x, y, w, h)
}

/// Decide where the main window should be moved when swapped into the work
/// area.
///
/// * In pinned mode (one or both reference panels active), the main window
///   fills the supplied `work_target` exactly — the panel is sized for the
///   intended slot, so further fitting would just leave gaps.
/// * In non-pinned mode, `mode` controls how an oversized window is fitted
///   into `work_target`.
pub fn decide_main_window_target(
    window_size: (f64, f64),
    work_target: Rect,
    pinned: bool,
    mode: SwapResizeMode,
) -> Rect {
    if pinned {
        // Pinned mode: reference windows occupy the side panels; the main
        // panel was sized for the main window, so just fill the slot.
        return work_target;
    }

    compute_swap_target_frame(window_size, work_target, mode)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    fn rect_eq(a: Rect, b: Rect) -> bool {
        approx_eq(a.x, b.x) && approx_eq(a.y, b.y)
            && approx_eq(a.width, b.width) && approx_eq(a.height, b.height)
    }

    // ---- compute_swap_target_frame ----

    #[test]
    fn preserve_fits_unchanged_centered() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = compute_swap_target_frame((500.0, 400.0), area, SwapResizeMode::PreserveAspectRatio);
        assert!(rect_eq(r, Rect::new(250.0, 200.0, 500.0, 400.0)), "got {:?}", r);
    }

    #[test]
    fn preserve_too_wide_scales_uniformly() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = compute_swap_target_frame((2000.0, 800.0), area, SwapResizeMode::PreserveAspectRatio);
        // scale factor 0.5 -> 1000x400, centered (0, 200).
        assert!(rect_eq(r, Rect::new(0.0, 200.0, 1000.0, 400.0)), "got {:?}", r);
    }

    #[test]
    fn preserve_too_tall_scales_uniformly() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = compute_swap_target_frame((500.0, 1600.0), area, SwapResizeMode::PreserveAspectRatio);
        // scale factor 0.5 -> 250x800, centered (375, 0).
        assert!(rect_eq(r, Rect::new(375.0, 0.0, 250.0, 800.0)), "got {:?}", r);
    }

    #[test]
    fn clamp_fits_unchanged_centered() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = compute_swap_target_frame((500.0, 400.0), area, SwapResizeMode::ClampMax);
        assert!(rect_eq(r, Rect::new(250.0, 200.0, 500.0, 400.0)), "got {:?}", r);
    }

    #[test]
    fn clamp_oversized_distorts_ratio() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = compute_swap_target_frame((1500.0, 1200.0), area, SwapResizeMode::ClampMax);
        // both dims clamped to area; ratio is now 1000/800 instead of 1500/1200.
        assert!(rect_eq(r, Rect::new(0.0, 0.0, 1000.0, 800.0)), "got {:?}", r);
    }

    // ---- decide_main_window_target ----

    /// Regression test: the prior bug was that a small window
    /// (e.g. 400x300) swapped into a larger work area (e.g. 1000x800)
    /// got *stretched* to fill the work area instead of staying at its
    /// native size centered.
    #[test]
    fn small_window_in_large_work_area_is_not_stretched() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = decide_main_window_target(
            (400.0, 300.0),
            area,
            false,
            SwapResizeMode::PreserveAspectRatio,
        );
        assert!(rect_eq(r, Rect::new(300.0, 250.0, 400.0, 300.0)), "got {:?}", r);
    }

    /// Pinned mode keeps the legacy "fill the slot" behavior intentionally —
    /// reference windows occupy the side panels and the main panel was sized
    /// for the main window.
    #[test]
    fn pinned_mode_fills_supplied_panel_exactly() {
        let panel = Rect::new(50.0, 50.0, 600.0, 500.0);
        let r = decide_main_window_target(
            (200.0, 200.0),
            panel,
            true,
            SwapResizeMode::PreserveAspectRatio,
        );
        assert!(rect_eq(r, panel), "got {:?}", r);
    }

    #[test]
    fn clamp_mode_propagates_through_decide() {
        let area = Rect::new(0.0, 0.0, 1000.0, 800.0);
        let r = decide_main_window_target(
            (1500.0, 1200.0),
            area,
            false,
            SwapResizeMode::ClampMax,
        );
        assert!(rect_eq(r, Rect::new(0.0, 0.0, 1000.0, 800.0)), "got {:?}", r);
    }
}
