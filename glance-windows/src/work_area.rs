// Work Area window for Glance on Windows.
//
// A frosted-glass background window (using Windows 11 Mica/Acrylic backdrop)
// that hosts the focused/main window and optionally one reference window
// pinned to each side. Layout: [ left-ref | main | right-ref ].
// Equivalent of the macOS NSVisualEffectView with `.hudWindow` material.

use crate::types::Rect;

/// Actions that can be triggered from the work area window.
#[derive(Debug, Clone, PartialEq)]
pub enum WorkAreaEvent {
    ExitClicked,
    SwitchClicked,
    UnpinLeftClicked,
    UnpinRightClicked,
    Resized(Rect),
    Moved(Rect),
    LeftSplitRatioChanged(f64),
    RightSplitRatioChanged(f64),
}

// ---------------------------------------------------------------------------
// Padding / layout constants
// ---------------------------------------------------------------------------

const PADDING_TOP: f64 = 8.0;
const PADDING_LEFT: f64 = 8.0;
const PADDING_RIGHT: f64 = 8.0;
const PADDING_BOTTOM: f64 = 28.0;
/// Gap between adjacent panels. Doubles as the divider hit-zone width so the
/// user can grab the split easily.
const SPLIT_GAP: f64 = 20.0;

/// Fraction of total usable width reserved for the LEFT reference panel.
const DEFAULT_LEFT_SPLIT_RATIO: f64 = 0.25;
/// Fraction of total usable width reserved for the RIGHT reference panel.
const DEFAULT_RIGHT_SPLIT_RATIO: f64 = 0.3;

const MIN_REF_RATIO: f64 = 0.15;
const MAX_REF_RATIO: f64 = 0.5;
/// Main panel is never allowed to shrink below this fraction of the available
/// width (available = usable minus active gaps).
const MIN_MAIN_RATIO: f64 = 0.3;

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod platform {
    use super::*;
    use std::mem;
    use std::sync::mpsc::Sender;

    const MIN_WIDTH: i32 = 400;
    const MIN_HEIGHT: i32 = 300;

    use windows::Win32::Foundation::{
        COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
    };
    use windows::Win32::Graphics::Dwm::{
        DwmExtendFrameIntoClientArea, DwmSetWindowAttribute,
        DWMWA_SYSTEMBACKDROP_TYPE, DWMWA_USE_IMMERSIVE_DARK_MODE,
        DWMSBT_TRANSIENTWINDOW, DWM_SYSTEMBACKDROP_TYPE,
    };
    use windows::Win32::Graphics::Gdi::{
        BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW,
        EndPaint, FillRect, InvalidateRect, SelectObject, SetBkMode,
        SetTextColor, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS,
        DEFAULT_CHARSET, DEFAULT_PITCH, DT_CENTER, DT_SINGLELINE,
        DT_VCENTER, FW_NORMAL, OUT_DEFAULT_PRECIS, PAINTSTRUCT, TRANSPARENT,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Controls::MARGINS;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        ReleaseCapture, SetCapture,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, GetClientRect,
        GetWindowLongPtrW, GetWindowRect, LoadCursorW, RegisterClassExW,
        SetCursor, SetWindowLongPtrW, SetWindowPos, ShowWindow, UnregisterClassW,
        GWLP_USERDATA, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT, HTCAPTION,
        HTCLIENT, HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT, HWND_BOTTOM,
        IDC_SIZEWE, MINMAXINFO, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
        SWP_NOZORDER, SW_HIDE, SW_SHOWNOACTIVATE, WNDCLASSEXW,
        WM_ERASEBKGND, WM_GETMINMAXINFO, WM_LBUTTONDOWN, WM_LBUTTONUP,
        WM_MOUSEMOVE, WM_MOVE, WM_NCHITTEST, WM_PAINT, WM_SETCURSOR,
        WM_SIZE, WM_SIZING, WS_EX_TOOLWINDOW,
        WS_POPUP, WS_THICKFRAME,
    };

    /// Wide class name for the work area window, null-terminated.
    const CLASS_NAME: &[u16] = &[
        b'G' as u16, b'l' as u16, b'a' as u16, b'n' as u16, b'c' as u16,
        b'e' as u16, b'W' as u16, b'o' as u16, b'r' as u16, b'k' as u16,
        b'A' as u16, b'r' as u16, b'e' as u16, b'a' as u16, 0,
    ];

    /// Width of the resize border (pixels) for WM_NCHITTEST.
    const RESIZE_BORDER: i32 = 6;

    /// Height of the bottom bar area (pixels) where buttons/label are drawn.
    const BOTTOM_BAR_HEIGHT: i32 = 24;

    /// Button area dimensions in the bottom bar.
    const BUTTON_WIDTH: i32 = 100;
    const BUTTON_HEIGHT: i32 = 20;
    const BUTTON_MARGIN: i32 = 8;

    #[derive(Copy, Clone, PartialEq, Eq, Debug)]
    enum DividerSide {
        Left,
        Right,
    }

    // ------------------------------------------------------------------
    // Per-window state stored via GWLP_USERDATA
    // ------------------------------------------------------------------

    struct WindowState {
        sender: Sender<WorkAreaEvent>,
        left_split_ratio: f64,
        right_split_ratio: f64,
        left_reference_active: bool,
        right_reference_active: bool,
        dragging_divider: Option<DividerSide>,
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn get_x_lparam(lp: LPARAM) -> i32 {
        (lp.0 & 0xFFFF) as i16 as i32
    }

    fn get_y_lparam(lp: LPARAM) -> i32 {
        ((lp.0 >> 16) & 0xFFFF) as i16 as i32
    }

    unsafe fn window_rect(hwnd: HWND) -> Rect {
        let mut rc = RECT::default();
        let _ = GetWindowRect(hwnd, &mut rc);
        Rect::new(
            rc.left as f64,
            rc.top as f64,
            (rc.right - rc.left) as f64,
            (rc.bottom - rc.top) as f64,
        )
    }

    unsafe fn client_rect(hwnd: HWND) -> RECT {
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        rc
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn exit_button_rect(client: &RECT) -> RECT {
        RECT {
            left: BUTTON_MARGIN,
            top: client.bottom - BOTTOM_BAR_HEIGHT + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2,
            right: BUTTON_MARGIN + BUTTON_WIDTH,
            bottom: client.bottom - BOTTOM_BAR_HEIGHT
                + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2
                + BUTTON_HEIGHT,
        }
    }

    fn switch_button_rect(client: &RECT) -> RECT {
        RECT {
            left: client.right - BUTTON_MARGIN - BUTTON_WIDTH,
            top: client.bottom - BOTTOM_BAR_HEIGHT + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2,
            right: client.right - BUTTON_MARGIN,
            bottom: client.bottom - BOTTOM_BAR_HEIGHT
                + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2
                + BUTTON_HEIGHT,
        }
    }

    /// "Unpin Left" button — sits next to the Exit button, bottom-left.
    fn unpin_left_button_rect(client: &RECT) -> RECT {
        RECT {
            left: BUTTON_MARGIN * 2 + BUTTON_WIDTH,
            top: client.bottom - BOTTOM_BAR_HEIGHT + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2,
            right: BUTTON_MARGIN * 2 + BUTTON_WIDTH * 2,
            bottom: client.bottom - BOTTOM_BAR_HEIGHT
                + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2
                + BUTTON_HEIGHT,
        }
    }

    /// "Unpin Right" button — sits to the left of the Switch button.
    fn unpin_right_button_rect(client: &RECT) -> RECT {
        RECT {
            left: client.right - BUTTON_MARGIN * 2 - BUTTON_WIDTH * 2,
            top: client.bottom - BOTTOM_BAR_HEIGHT + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2,
            right: client.right - BUTTON_MARGIN * 2 - BUTTON_WIDTH,
            bottom: client.bottom - BOTTOM_BAR_HEIGHT
                + (BOTTOM_BAR_HEIGHT - BUTTON_HEIGHT) / 2
                + BUTTON_HEIGHT,
        }
    }

    fn point_in_rect(x: i32, y: i32, rc: &RECT) -> bool {
        x >= rc.left && x < rc.right && y >= rc.top && y < rc.bottom
    }

    /// Clamp ratios to keep main panel ≥ MIN_MAIN_RATIO of available width.
    fn clamp_ratios(left_active: bool, right_active: bool, mut left: f64, mut right: f64) -> (f64, f64) {
        let l = if left_active { left.clamp(MIN_REF_RATIO, MAX_REF_RATIO) } else { 0.0 };
        let r = if right_active { right.clamp(MIN_REF_RATIO, MAX_REF_RATIO) } else { 0.0 };
        // Total ref ratio must leave at least MIN_MAIN_RATIO for main.
        let total = l + r;
        let max_total = 1.0 - MIN_MAIN_RATIO;
        if total > max_total && total > 0.0 {
            let scale = max_total / total;
            left = if left_active { (l * scale).max(MIN_REF_RATIO) } else { left };
            right = if right_active { (r * scale).max(MIN_REF_RATIO) } else { right };
        } else {
            left = l;
            right = r;
        }
        (left, right)
    }

    /// Returns (available_width, left_gap_active, right_gap_active).
    fn available_panel_width(
        usable_w: f64,
        left_active: bool,
        right_active: bool,
    ) -> f64 {
        let active_gaps = (left_active as i32 + right_active as i32) as f64;
        (usable_w - active_gaps * SPLIT_GAP).max(0.0)
    }

    /// Horizontal center (client-x) of a divider in px.
    unsafe fn divider_center_x(hwnd: HWND, state: &WindowState, side: DividerSide) -> Option<i32> {
        let active = match side {
            DividerSide::Left => state.left_reference_active,
            DividerSide::Right => state.right_reference_active,
        };
        if !active { return None; }
        let cr = client_rect(hwnd);
        let w = (cr.right - cr.left) as f64;
        let usable_w = (w - PADDING_LEFT - PADDING_RIGHT).max(0.0);
        let avail = available_panel_width(
            usable_w,
            state.left_reference_active,
            state.right_reference_active,
        );
        let (l_r, r_r) = clamp_ratios(
            state.left_reference_active,
            state.right_reference_active,
            state.left_split_ratio,
            state.right_split_ratio,
        );
        match side {
            DividerSide::Left => {
                let left_w = avail * l_r;
                // Center lies in the gap between left panel and main.
                let x = PADDING_LEFT + left_w + SPLIT_GAP / 2.0;
                Some(x.round() as i32)
            }
            DividerSide::Right => {
                let right_w = avail * r_r;
                let x = PADDING_LEFT + usable_w - right_w - SPLIT_GAP / 2.0;
                Some(x.round() as i32)
            }
        }
    }

    /// Divider hit zone (inclusive-exclusive client-x range).
    unsafe fn divider_hit_zone(hwnd: HWND, state: &WindowState, side: DividerSide) -> Option<(i32, i32)> {
        let cx = divider_center_x(hwnd, state, side)?;
        let half = (SPLIT_GAP as i32) / 2;
        Some((cx - half, cx + half))
    }

    /// Determine which divider (if any) the point is on.
    unsafe fn divider_at_point(hwnd: HWND, state: &WindowState, x: i32, y: i32) -> Option<DividerSide> {
        let cr = client_rect(hwnd);
        let top = PADDING_TOP as i32;
        let bottom = cr.bottom - PADDING_BOTTOM as i32;
        if y < top || y >= bottom { return None; }
        for side in [DividerSide::Left, DividerSide::Right] {
            if let Some((l, r)) = divider_hit_zone(hwnd, state, side) {
                if x >= l && x < r { return Some(side); }
            }
        }
        None
    }

    // ------------------------------------------------------------------
    // Window procedure
    // ------------------------------------------------------------------

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut WindowState;

        match msg {
            WM_ERASEBKGND => {
                return LRESULT(1);
            }

            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let cr = client_rect(hwnd);
                    paint_bottom_bar(hwnd, hdc, &cr, state_ptr);
                    paint_dividers(hwnd, hdc, &cr, state_ptr);
                    let _ = EndPaint(hwnd, &ps);
                }
                return LRESULT(0);
            }

            WM_SIZE => {
                if !state_ptr.is_null() {
                    let frame = window_rect(hwnd);
                    let _ = (*state_ptr).sender.send(WorkAreaEvent::Resized(frame));
                    let _ = InvalidateRect(hwnd, None, false);
                }
                return LRESULT(0);
            }

            WM_MOVE => {
                if !state_ptr.is_null() {
                    let frame = window_rect(hwnd);
                    let _ = (*state_ptr).sender.send(WorkAreaEvent::Moved(frame));
                }
                return LRESULT(0);
            }

            WM_SIZING => {
                if lparam.0 == 0 {
                    return LRESULT(0);
                }
                let rc = &mut *(lparam.0 as *mut RECT);
                let w = rc.right - rc.left;
                let h = rc.bottom - rc.top;
                if w < MIN_WIDTH {
                    rc.right = rc.left + MIN_WIDTH;
                }
                if h < MIN_HEIGHT {
                    rc.bottom = rc.top + MIN_HEIGHT;
                }
                return LRESULT(1);
            }

            WM_GETMINMAXINFO => {
                let mmi = &mut *(lparam.0 as *mut MINMAXINFO);
                mmi.ptMinTrackSize = POINT { x: MIN_WIDTH, y: MIN_HEIGHT };
                return LRESULT(0);
            }

            WM_NCHITTEST => {
                let x = get_x_lparam(lparam);
                let y = get_y_lparam(lparam);

                let mut wr = RECT::default();
                let _ = GetWindowRect(hwnd, &mut wr);
                let lx = x - wr.left;
                let ly = y - wr.top;
                let w = wr.right - wr.left;
                let h = wr.bottom - wr.top;

                let on_left = lx < RESIZE_BORDER;
                let on_right = lx >= w - RESIZE_BORDER;
                let on_top = ly < RESIZE_BORDER;
                let on_bottom = ly >= h - RESIZE_BORDER;

                if on_top && on_left { return LRESULT(HTTOPLEFT as isize); }
                if on_top && on_right { return LRESULT(HTTOPRIGHT as isize); }
                if on_bottom && on_left { return LRESULT(HTBOTTOMLEFT as isize); }
                if on_bottom && on_right { return LRESULT(HTBOTTOMRIGHT as isize); }
                if on_left { return LRESULT(HTLEFT as isize); }
                if on_right { return LRESULT(HTRIGHT as isize); }
                if on_top { return LRESULT(HTTOP as isize); }
                if on_bottom { return LRESULT(HTBOTTOM as isize); }

                let cr = client_rect(hwnd);
                if ly >= (cr.bottom - BOTTOM_BAR_HEIGHT) {
                    return LRESULT(HTCLIENT as isize);
                }

                if !state_ptr.is_null() {
                    if divider_at_point(hwnd, &*state_ptr, lx, ly).is_some() {
                        return LRESULT(HTCLIENT as isize);
                    }
                }

                return LRESULT(HTCAPTION as isize);
            }

            WM_SETCURSOR => {
                if !state_ptr.is_null() {
                    let mut pt = POINT::default();
                    let _ = windows::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt);
                    let _ = windows::Win32::Graphics::Gdi::ScreenToClient(hwnd, &mut pt);
                    if divider_at_point(hwnd, &*state_ptr, pt.x, pt.y).is_some() {
                        let cursor = LoadCursorW(None, IDC_SIZEWE).unwrap_or_default();
                        SetCursor(cursor);
                        return LRESULT(1);
                    }
                }
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            WM_LBUTTONDOWN => {
                if !state_ptr.is_null() {
                    let x = get_x_lparam(lparam);
                    let y = get_y_lparam(lparam);
                    let cr = client_rect(hwnd);

                    if let Some(side) = divider_at_point(hwnd, &*state_ptr, x, y) {
                        (*state_ptr).dragging_divider = Some(side);
                        SetCapture(hwnd);
                        return LRESULT(0);
                    }

                    let exit_rc = exit_button_rect(&cr);
                    if point_in_rect(x, y, &exit_rc) {
                        let _ = (*state_ptr).sender.send(WorkAreaEvent::ExitClicked);
                        return LRESULT(0);
                    }

                    let switch_rc = switch_button_rect(&cr);
                    if point_in_rect(x, y, &switch_rc) {
                        let _ = (*state_ptr).sender.send(WorkAreaEvent::SwitchClicked);
                        return LRESULT(0);
                    }

                    if (*state_ptr).left_reference_active {
                        let unpin_rc = unpin_left_button_rect(&cr);
                        if point_in_rect(x, y, &unpin_rc) {
                            let _ = (*state_ptr).sender.send(WorkAreaEvent::UnpinLeftClicked);
                            return LRESULT(0);
                        }
                    }

                    if (*state_ptr).right_reference_active {
                        let unpin_rc = unpin_right_button_rect(&cr);
                        if point_in_rect(x, y, &unpin_rc) {
                            let _ = (*state_ptr).sender.send(WorkAreaEvent::UnpinRightClicked);
                            return LRESULT(0);
                        }
                    }
                }
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            WM_MOUSEMOVE => {
                if !state_ptr.is_null() {
                    if let Some(side) = (*state_ptr).dragging_divider {
                        let x = get_x_lparam(lparam);
                        let cr = client_rect(hwnd);
                        let usable_w = ((cr.right - cr.left) as f64
                            - PADDING_LEFT - PADDING_RIGHT).max(1.0);
                        let avail = available_panel_width(
                            usable_w,
                            (*state_ptr).left_reference_active,
                            (*state_ptr).right_reference_active,
                        ).max(1.0);
                        match side {
                            DividerSide::Left => {
                                let rel = (x as f64 - PADDING_LEFT).max(0.0);
                                let new_ratio = (rel / avail).clamp(MIN_REF_RATIO, MAX_REF_RATIO);
                                (*state_ptr).left_split_ratio = new_ratio;
                                let (lc, _) = clamp_ratios(
                                    (*state_ptr).left_reference_active,
                                    (*state_ptr).right_reference_active,
                                    new_ratio,
                                    (*state_ptr).right_split_ratio,
                                );
                                (*state_ptr).left_split_ratio = lc;
                                let _ = (*state_ptr).sender.send(
                                    WorkAreaEvent::LeftSplitRatioChanged(lc),
                                );
                            }
                            DividerSide::Right => {
                                // Distance from right padding edge back to cursor.
                                let rel = ((PADDING_LEFT + usable_w) - x as f64).max(0.0);
                                let new_ratio = (rel / avail).clamp(MIN_REF_RATIO, MAX_REF_RATIO);
                                (*state_ptr).right_split_ratio = new_ratio;
                                let (_, rc2) = clamp_ratios(
                                    (*state_ptr).left_reference_active,
                                    (*state_ptr).right_reference_active,
                                    (*state_ptr).left_split_ratio,
                                    new_ratio,
                                );
                                (*state_ptr).right_split_ratio = rc2;
                                let _ = (*state_ptr).sender.send(
                                    WorkAreaEvent::RightSplitRatioChanged(rc2),
                                );
                            }
                        }
                        let _ = InvalidateRect(hwnd, None, false);
                        return LRESULT(0);
                    }
                }
            }

            WM_LBUTTONUP => {
                if !state_ptr.is_null() && (*state_ptr).dragging_divider.is_some() {
                    (*state_ptr).dragging_divider = None;
                    let _ = ReleaseCapture();
                    return LRESULT(0);
                }
            }

            0x001F /* WM_CANCELMODE */ => {
                if !state_ptr.is_null() && (*state_ptr).dragging_divider.is_some() {
                    (*state_ptr).dragging_divider = None;
                    let _ = ReleaseCapture();
                }
            }

            _ => {}
        }

        DefWindowProcW(hwnd, msg, wparam, lparam)
    }

    // ------------------------------------------------------------------
    // Painting
    // ------------------------------------------------------------------

    unsafe fn paint_dividers(
        hwnd: HWND,
        hdc: windows::Win32::Graphics::Gdi::HDC,
        client: &RECT,
        state_ptr: *const WindowState,
    ) {
        if state_ptr.is_null() { return; }
        let state = &*state_ptr;
        let brush = CreateSolidBrush(COLORREF(0x00555555));
        for side in [DividerSide::Left, DividerSide::Right] {
            if let Some(cx) = divider_center_x(hwnd, state, side) {
                let line = RECT {
                    left: cx - 1,
                    top: PADDING_TOP as i32,
                    right: cx + 1,
                    bottom: client.bottom - PADDING_BOTTOM as i32,
                };
                FillRect(hdc, &line, brush);
            }
        }
        let _ = DeleteObject(brush);
    }

    unsafe fn paint_bottom_bar(
        _hwnd: HWND,
        hdc: windows::Win32::Graphics::Gdi::HDC,
        client: &RECT,
        state_ptr: *const WindowState,
    ) {
        let bar_rect = RECT {
            left: 0,
            top: client.bottom - BOTTOM_BAR_HEIGHT,
            right: client.right,
            bottom: client.bottom,
        };
        let bar_brush = CreateSolidBrush(COLORREF(0x00201010));
        FillRect(hdc, &bar_rect, bar_brush);
        let _ = DeleteObject(bar_brush);

        let face = wide("Segoe UI");
        let font = CreateFontW(
            14, 0, 0, 0,
            FW_NORMAL.0 as i32,
            0, 0, 0,
            DEFAULT_CHARSET.0 as u32,
            OUT_DEFAULT_PRECIS.0 as u32,
            CLIP_DEFAULT_PRECIS.0 as u32,
            CLEARTYPE_QUALITY.0 as u32,
            DEFAULT_PITCH.0 as u32,
            windows::core::PCWSTR(face.as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, COLORREF(0x00CCCCCC));

        let mut exit_rc = exit_button_rect(client);
        let mut exit_text = wide("\u{2715} Exit");
        DrawTextW(hdc, &mut exit_text, &mut exit_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        let mut switch_rc = switch_button_rect(client);
        let mut switch_text = wide("\u{21E5} Switch (Alt)");
        DrawTextW(hdc, &mut switch_text, &mut switch_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        if !state_ptr.is_null() {
            if (*state_ptr).left_reference_active {
                let mut rc = unpin_left_button_rect(client);
                let mut t = wide("\u{2715} Unpin L");
                DrawTextW(hdc, &mut t, &mut rc,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            }
            if (*state_ptr).right_reference_active {
                let mut rc = unpin_right_button_rect(client);
                let mut t = wide("\u{2715} Unpin R");
                DrawTextW(hdc, &mut t, &mut rc,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            }
        }

        let mut label_rc = RECT {
            left: client.left,
            top: client.bottom - BOTTOM_BAR_HEIGHT,
            right: client.right,
            bottom: client.bottom,
        };
        let mut label_text = wide("Work Area");
        DrawTextW(hdc, &mut label_text, &mut label_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        SelectObject(hdc, old_font);
        let _ = DeleteObject(font);
    }

    // ------------------------------------------------------------------
    // Apply Mica backdrop (Windows 11)
    // ------------------------------------------------------------------

    unsafe fn apply_mica_backdrop(hwnd: HWND) {
        let dark: u32 = 1;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark as *const u32 as *const core::ffi::c_void,
            mem::size_of::<u32>() as u32,
        );

        let margins = MARGINS {
            cxLeftWidth: -1, cxRightWidth: -1,
            cyTopHeight: -1, cyBottomHeight: -1,
        };
        let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

        let backdrop_type: DWM_SYSTEMBACKDROP_TYPE = DWMSBT_TRANSIENTWINDOW;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &backdrop_type as *const DWM_SYSTEMBACKDROP_TYPE as *const core::ffi::c_void,
            mem::size_of::<DWM_SYSTEMBACKDROP_TYPE>() as u32,
        );
    }

    // ------------------------------------------------------------------
    // Public struct
    // ------------------------------------------------------------------

    pub struct WorkAreaWindow {
        hwnd: HWND,
        class_atom: u16,
        state: *mut WindowState,
    }

    unsafe impl Send for WorkAreaWindow {}

    impl WorkAreaWindow {
        pub fn new(
            frame: &Rect,
            sender: Sender<WorkAreaEvent>,
        ) -> Result<Self, String> {
            unsafe {
                let hinstance = GetModuleHandleW(None)
                    .map_err(|e| format!("GetModuleHandleW failed: {e}"))?;

                let wc = WNDCLASSEXW {
                    cbSize: mem::size_of::<WNDCLASSEXW>() as u32,
                    lpfnWndProc: Some(wnd_proc),
                    hInstance: hinstance.into(),
                    lpszClassName: windows::core::PCWSTR(CLASS_NAME.as_ptr()),
                    ..Default::default()
                };

                let class_atom = RegisterClassExW(&wc);
                if class_atom == 0 {
                    return Err("RegisterClassExW failed for GlanceWorkArea".to_string());
                }

                let ex_style = WS_EX_TOOLWINDOW;
                let style = WS_POPUP | WS_THICKFRAME;

                let hwnd = CreateWindowExW(
                    ex_style,
                    windows::core::PCWSTR(CLASS_NAME.as_ptr()),
                    windows::core::PCWSTR::null(),
                    style,
                    frame.x.round() as i32,
                    frame.y.round() as i32,
                    frame.width.round() as i32,
                    frame.height.round() as i32,
                    None, None,
                    hinstance,
                    None,
                )
                .map_err(|e| format!("CreateWindowExW failed: {e}"))?;

                let state = Box::into_raw(Box::new(WindowState {
                    sender,
                    left_split_ratio: DEFAULT_LEFT_SPLIT_RATIO,
                    right_split_ratio: DEFAULT_RIGHT_SPLIT_RATIO,
                    left_reference_active: false,
                    right_reference_active: false,
                    dragging_divider: None,
                }));
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as isize);

                apply_mica_backdrop(hwnd);

                let _ = SetWindowPos(
                    hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );

                log::info!("WorkArea window created (hwnd={:?})", hwnd);

                Ok(WorkAreaWindow { hwnd, class_atom, state })
            }
        }

        pub fn hwnd(&self) -> isize { self.hwnd.0 as isize }

        pub fn frame(&self) -> Rect { unsafe { window_rect(self.hwnd) } }

        pub fn set_frame(&self, frame: &Rect) {
            unsafe {
                let _ = SetWindowPos(
                    self.hwnd, None,
                    frame.x.round() as i32,
                    frame.y.round() as i32,
                    frame.width.round() as i32,
                    frame.height.round() as i32,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
        }

        pub fn usable_frame(&self) -> Rect {
            let f = self.frame();
            Rect::new(
                f.x + PADDING_LEFT,
                f.y + PADDING_TOP,
                (f.width - PADDING_LEFT - PADDING_RIGHT).max(0.0),
                (f.height - PADDING_TOP - PADDING_BOTTOM).max(0.0),
            )
        }

        fn state_ref(&self) -> Option<&WindowState> {
            unsafe { self.state.as_ref() }
        }

        pub fn left_split_ratio(&self) -> f64 {
            self.state_ref().map(|s| s.left_split_ratio).unwrap_or(DEFAULT_LEFT_SPLIT_RATIO)
        }

        pub fn right_split_ratio(&self) -> f64 {
            self.state_ref().map(|s| s.right_split_ratio).unwrap_or(DEFAULT_RIGHT_SPLIT_RATIO)
        }

        pub fn set_left_split_ratio(&mut self, ratio: f64) {
            unsafe {
                if !self.state.is_null() {
                    (*self.state).left_split_ratio = ratio.clamp(MIN_REF_RATIO, MAX_REF_RATIO);
                    let _ = InvalidateRect(self.hwnd, None, false);
                }
            }
        }

        pub fn set_right_split_ratio(&mut self, ratio: f64) {
            unsafe {
                if !self.state.is_null() {
                    (*self.state).right_split_ratio = ratio.clamp(MIN_REF_RATIO, MAX_REF_RATIO);
                    let _ = InvalidateRect(self.hwnd, None, false);
                }
            }
        }

        pub fn left_reference_active(&self) -> bool {
            self.state_ref().map(|s| s.left_reference_active).unwrap_or(false)
        }

        pub fn right_reference_active(&self) -> bool {
            self.state_ref().map(|s| s.right_reference_active).unwrap_or(false)
        }

        pub fn set_left_reference_active(&mut self, active: bool) {
            unsafe {
                if !self.state.is_null() {
                    (*self.state).left_reference_active = active;
                    let _ = InvalidateRect(self.hwnd, None, false);
                }
            }
        }

        pub fn set_right_reference_active(&mut self, active: bool) {
            unsafe {
                if !self.state.is_null() {
                    (*self.state).right_reference_active = active;
                    let _ = InvalidateRect(self.hwnd, None, false);
                }
            }
        }

        /// Compute panel frames: (main, left_ref_opt, right_ref_opt).
        fn compute_panels(&self) -> (Rect, Option<Rect>, Option<Rect>) {
            let uf = self.usable_frame();
            let s = match self.state_ref() {
                Some(s) => s,
                None => return (uf, None, None),
            };
            let left_active = s.left_reference_active;
            let right_active = s.right_reference_active;
            let avail = available_panel_width(uf.width, left_active, right_active);
            let (lr, rr) = clamp_ratios(left_active, right_active, s.left_split_ratio, s.right_split_ratio);
            let left_w = avail * lr;
            let right_w = avail * rr;
            let main_w = (avail - left_w - right_w).max(0.0);

            let mut cursor_x = uf.x;
            let left_rect = if left_active {
                let r = Rect::new(cursor_x, uf.y, left_w, uf.height);
                cursor_x += left_w + SPLIT_GAP;
                Some(r)
            } else {
                None
            };
            let main_rect = Rect::new(cursor_x, uf.y, main_w, uf.height);
            cursor_x += main_w;
            let right_rect = if right_active {
                cursor_x += SPLIT_GAP;
                Some(Rect::new(cursor_x, uf.y, right_w, uf.height))
            } else {
                None
            };
            (main_rect, left_rect, right_rect)
        }

        pub fn main_panel_frame(&self) -> Rect {
            self.compute_panels().0
        }

        pub fn left_reference_panel_frame(&self) -> Option<Rect> {
            self.compute_panels().1
        }

        pub fn right_reference_panel_frame(&self) -> Option<Rect> {
            self.compute_panels().2
        }

        pub fn show(&self) {
            unsafe {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                let _ = SetWindowPos(
                    self.hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );
            }
        }

        pub fn hide(&self) {
            unsafe { let _ = ShowWindow(self.hwnd, SW_HIDE); }
        }

        pub fn destroy(&mut self) {
            unsafe {
                if !self.hwnd.is_invalid() {
                    SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
                    let _ = DestroyWindow(self.hwnd);
                    self.hwnd = HWND::default();
                }
                if !self.state.is_null() {
                    let _ = Box::from_raw(self.state);
                    self.state = std::ptr::null_mut();
                }
                if self.class_atom != 0 {
                    if let Ok(hinstance) = GetModuleHandleW(None) {
                        let _ = UnregisterClassW(
                            windows::core::PCWSTR(CLASS_NAME.as_ptr()),
                            hinstance,
                        );
                    }
                    self.class_atom = 0;
                }
            }
            log::info!("WorkArea window destroyed");
        }
    }

    impl Drop for WorkAreaWindow {
        fn drop(&mut self) { self.destroy(); }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stub
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
mod platform {
    use super::*;
    #[allow(unused_imports)]
    use std::sync::mpsc::Sender;

    pub struct WorkAreaWindow {
        frame: Rect,
        left_split_ratio: f64,
        right_split_ratio: f64,
        left_reference_active: bool,
        right_reference_active: bool,
    }

    fn clamp_ratios(left_active: bool, right_active: bool, mut left: f64, mut right: f64) -> (f64, f64) {
        let l = if left_active { left.clamp(MIN_REF_RATIO, MAX_REF_RATIO) } else { 0.0 };
        let r = if right_active { right.clamp(MIN_REF_RATIO, MAX_REF_RATIO) } else { 0.0 };
        let total = l + r;
        let max_total = 1.0 - MIN_MAIN_RATIO;
        if total > max_total && total > 0.0 {
            let scale = max_total / total;
            left = if left_active { (l * scale).max(MIN_REF_RATIO) } else { left };
            right = if right_active { (r * scale).max(MIN_REF_RATIO) } else { right };
        } else {
            left = l;
            right = r;
        }
        (left, right)
    }

    fn available_panel_width(usable_w: f64, left_active: bool, right_active: bool) -> f64 {
        let active_gaps = (left_active as i32 + right_active as i32) as f64;
        (usable_w - active_gaps * SPLIT_GAP).max(0.0)
    }

    impl WorkAreaWindow {
        pub fn new(
            frame: &Rect,
            _sender: Sender<WorkAreaEvent>,
        ) -> Result<Self, String> {
            Ok(WorkAreaWindow {
                frame: *frame,
                left_split_ratio: DEFAULT_LEFT_SPLIT_RATIO,
                right_split_ratio: DEFAULT_RIGHT_SPLIT_RATIO,
                left_reference_active: false,
                right_reference_active: false,
            })
        }

        pub fn hwnd(&self) -> isize { 0 }
        pub fn frame(&self) -> Rect { self.frame }
        pub fn set_frame(&self, _frame: &Rect) {}

        pub fn usable_frame(&self) -> Rect {
            let f = self.frame;
            Rect::new(
                f.x + PADDING_LEFT,
                f.y + PADDING_TOP,
                (f.width - PADDING_LEFT - PADDING_RIGHT).max(0.0),
                (f.height - PADDING_TOP - PADDING_BOTTOM).max(0.0),
            )
        }

        pub fn left_split_ratio(&self) -> f64 { self.left_split_ratio }
        pub fn right_split_ratio(&self) -> f64 { self.right_split_ratio }

        pub fn set_left_split_ratio(&mut self, ratio: f64) {
            self.left_split_ratio = ratio.clamp(MIN_REF_RATIO, MAX_REF_RATIO);
        }
        pub fn set_right_split_ratio(&mut self, ratio: f64) {
            self.right_split_ratio = ratio.clamp(MIN_REF_RATIO, MAX_REF_RATIO);
        }

        pub fn left_reference_active(&self) -> bool { self.left_reference_active }
        pub fn right_reference_active(&self) -> bool { self.right_reference_active }

        pub fn set_left_reference_active(&mut self, active: bool) {
            self.left_reference_active = active;
        }
        pub fn set_right_reference_active(&mut self, active: bool) {
            self.right_reference_active = active;
        }

        fn compute_panels(&self) -> (Rect, Option<Rect>, Option<Rect>) {
            let uf = self.usable_frame();
            let avail = available_panel_width(uf.width, self.left_reference_active, self.right_reference_active);
            let (lr, rr) = clamp_ratios(
                self.left_reference_active, self.right_reference_active,
                self.left_split_ratio, self.right_split_ratio,
            );
            let left_w = avail * lr;
            let right_w = avail * rr;
            let main_w = (avail - left_w - right_w).max(0.0);

            let mut cursor_x = uf.x;
            let left_rect = if self.left_reference_active {
                let r = Rect::new(cursor_x, uf.y, left_w, uf.height);
                cursor_x += left_w + SPLIT_GAP;
                Some(r)
            } else { None };
            let main_rect = Rect::new(cursor_x, uf.y, main_w, uf.height);
            cursor_x += main_w;
            let right_rect = if self.right_reference_active {
                cursor_x += SPLIT_GAP;
                Some(Rect::new(cursor_x, uf.y, right_w, uf.height))
            } else { None };
            (main_rect, left_rect, right_rect)
        }

        pub fn main_panel_frame(&self) -> Rect { self.compute_panels().0 }
        pub fn left_reference_panel_frame(&self) -> Option<Rect> { self.compute_panels().1 }
        pub fn right_reference_panel_frame(&self) -> Option<Rect> { self.compute_panels().2 }

        pub fn show(&self) {}
        pub fn hide(&self) {}
        pub fn destroy(&mut self) {}
    }
}

pub use platform::WorkAreaWindow;
