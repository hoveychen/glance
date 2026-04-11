// Work Area window for Glance on Windows.
//
// A frosted-glass background window (using Windows 11 Mica/Acrylic backdrop)
// that hosts the focused/main window. Equivalent of the macOS
// NSVisualEffectView with `.hudWindow` material.

use crate::types::Rect;

/// Actions that can be triggered from the work area window.
#[derive(Debug, Clone, PartialEq)]
pub enum WorkAreaEvent {
    ExitClicked,
    SwitchClicked,
    UnpinClicked,
    Resized(Rect),
    Moved(Rect),
    SplitRatioChanged(f64),
}

// ---------------------------------------------------------------------------
// Padding / layout constants
// ---------------------------------------------------------------------------

const PADDING_TOP: f64 = 8.0;
const PADDING_LEFT: f64 = 8.0;
const PADDING_RIGHT: f64 = 8.0;
const PADDING_BOTTOM: f64 = 28.0;
const SPLIT_GAP: f64 = 8.0;

const DEFAULT_SPLIT_RATIO: f64 = 0.6;
const MIN_SPLIT_RATIO: f64 = 0.3;
const MAX_SPLIT_RATIO: f64 = 0.8;

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
        DWMSBT_TABBEDWINDOW, DWM_SYSTEMBACKDROP_TYPE,
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
        SWP_NOZORDER, SW_HIDE, SW_SHOWNOACTIVATE, WINDOW_EX_STYLE, WNDCLASSEXW,
        WM_ERASEBKGND, WM_GETMINMAXINFO, WM_LBUTTONDOWN, WM_LBUTTONUP,
        WM_MOUSEMOVE, WM_MOVE, WM_NCHITTEST, WM_PAINT, WM_SETCURSOR,
        WM_SIZE, WM_SIZING, WS_EX_NOREDIRECTIONBITMAP, WS_EX_TOOLWINDOW,
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

    // ------------------------------------------------------------------
    // Per-window state stored via GWLP_USERDATA
    // ------------------------------------------------------------------

    struct WindowState {
        sender: Sender<WorkAreaEvent>,
        split_ratio: f64,
        reference_active: bool,
        divider_dragging: bool,
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// Extract the signed x-coordinate from an LPARAM (mouse messages).
    fn get_x_lparam(lp: LPARAM) -> i32 {
        (lp.0 & 0xFFFF) as i16 as i32
    }

    /// Extract the signed y-coordinate from an LPARAM (mouse messages).
    fn get_y_lparam(lp: LPARAM) -> i32 {
        ((lp.0 >> 16) & 0xFFFF) as i16 as i32
    }

    /// Read the current window rect (screen coordinates) and return as `Rect`.
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

    /// Read the client area rect (local coordinates).
    unsafe fn client_rect(hwnd: HWND) -> RECT {
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        rc
    }

    /// Encode a Rust &str as null-terminated UTF-16 Vec.
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Button rectangle definitions (in client coordinates).
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

    fn unpin_button_rect(client: &RECT) -> RECT {
        // Positioned to the left of the switch button.
        RECT {
            left: client.right - BUTTON_MARGIN - BUTTON_WIDTH * 2 - BUTTON_MARGIN,
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

    /// Width of the divider hit zone (wider than visual gap for easier grabbing).
    const DIVIDER_HIT_WIDTH: i32 = 12;

    /// Returns the divider hit zone in client coordinates, or None if
    /// reference is not active. Uses `GetClientRect` so coordinates match
    /// `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` lparam values regardless of DWM
    /// frame extension state.
    unsafe fn divider_hit_zone(hwnd: HWND, state: &WindowState) -> Option<(i32, i32)> {
        if !state.reference_active {
            return None;
        }
        let cr = client_rect(hwnd);
        let w = (cr.right - cr.left) as f64;
        let usable_w = (w - PADDING_LEFT - PADDING_RIGHT).max(0.0);
        let split_x = PADDING_LEFT + (usable_w - SPLIT_GAP) * state.split_ratio;
        let center = split_x as i32 + (SPLIT_GAP as i32) / 2;
        Some((center - DIVIDER_HIT_WIDTH / 2, center + DIVIDER_HIT_WIDTH / 2))
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
        // Retrieve per-window state.
        let state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut WindowState;

        match msg {
            WM_ERASEBKGND => {
                // Prevent flicker; DWM handles the background.
                return LRESULT(1);
            }

            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let cr = client_rect(hwnd);
                    paint_bottom_bar(hwnd, hdc, &cr, state_ptr);
                    EndPaint(hwnd, &ps);
                }
                return LRESULT(0);
            }

            WM_SIZE => {
                if !state_ptr.is_null() {
                    let frame = window_rect(hwnd);
                    let _ = (*state_ptr).sender.send(WorkAreaEvent::Resized(frame));
                    // Repaint the bottom bar after resize.
                    InvalidateRect(hwnd, None, false);
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
                // Enforce minimum size during live resize.
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
                return LRESULT(1); // TRUE = we modified the rect
            }

            WM_GETMINMAXINFO => {
                let mmi = &mut *(lparam.0 as *mut MINMAXINFO);
                mmi.ptMinTrackSize = POINT {
                    x: MIN_WIDTH,
                    y: MIN_HEIGHT,
                };
                return LRESULT(0);
            }

            WM_NCHITTEST => {
                let x = get_x_lparam(lparam);
                let y = get_y_lparam(lparam);

                // Convert screen coordinates to window-relative.
                let mut wr = RECT::default();
                let _ = GetWindowRect(hwnd, &mut wr);
                let lx = x - wr.left;
                let ly = y - wr.top;
                let w = wr.right - wr.left;
                let h = wr.bottom - wr.top;

                // Resize borders (edges).
                let on_left = lx < RESIZE_BORDER;
                let on_right = lx >= w - RESIZE_BORDER;
                let on_top = ly < RESIZE_BORDER;
                let on_bottom = ly >= h - RESIZE_BORDER;

                if on_top && on_left {
                    return LRESULT(HTTOPLEFT as isize);
                }
                if on_top && on_right {
                    return LRESULT(HTTOPRIGHT as isize);
                }
                if on_bottom && on_left {
                    return LRESULT(HTBOTTOMLEFT as isize);
                }
                if on_bottom && on_right {
                    return LRESULT(HTBOTTOMRIGHT as isize);
                }
                if on_left {
                    return LRESULT(HTLEFT as isize);
                }
                if on_right {
                    return LRESULT(HTRIGHT as isize);
                }
                if on_top {
                    return LRESULT(HTTOP as isize);
                }
                if on_bottom {
                    return LRESULT(HTBOTTOM as isize);
                }

                // Bottom bar area — check for button clicks.
                let cr = client_rect(hwnd);
                if ly >= (cr.bottom - BOTTOM_BAR_HEIGHT) {
                    return LRESULT(HTCLIENT as isize);
                }

                // Divider zone — when reference is pinned.
                if !state_ptr.is_null() {
                    if let Some((div_left, div_right)) = divider_hit_zone(hwnd, &*state_ptr) {
                        if lx >= div_left && lx < div_right
                            && ly >= PADDING_TOP as i32
                            && ly < (h - PADDING_BOTTOM as i32)
                        {
                            return LRESULT(HTCLIENT as isize);
                        }
                    }
                }

                // Main area — draggable.
                return LRESULT(HTCAPTION as isize);
            }

            WM_SETCURSOR => {
                // Show resize cursor when hovering the divider zone.
                if !state_ptr.is_null() {
                    if let Some((div_left, div_right)) = divider_hit_zone(hwnd, &*state_ptr) {
                        // Convert screen cursor position to client coordinates.
                        let mut pt = POINT::default();
                        let _ = windows::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt);
                        let _ = windows::Win32::Graphics::Gdi::ScreenToClient(hwnd, &mut pt);
                        let cr = client_rect(hwnd);
                        if pt.x >= div_left && pt.x < div_right
                            && pt.y >= PADDING_TOP as i32
                            && pt.y < (cr.bottom - PADDING_BOTTOM as i32)
                        {
                            let cursor = LoadCursorW(None, IDC_SIZEWE)
                                .unwrap_or_default();
                            SetCursor(cursor);
                            return LRESULT(1); // We handled the cursor.
                        }
                    }
                }
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            WM_LBUTTONDOWN => {
                if !state_ptr.is_null() {
                    let x = get_x_lparam(lparam);
                    let y = get_y_lparam(lparam);
                    let cr = client_rect(hwnd);

                    // Check divider zone first.
                    if let Some((div_left, div_right)) = divider_hit_zone(hwnd, &*state_ptr) {
                        let h = cr.bottom - cr.top;
                        if x >= div_left && x < div_right
                            && y >= PADDING_TOP as i32
                            && y < (h - PADDING_BOTTOM as i32)
                        {
                            (*state_ptr).divider_dragging = true;
                            SetCapture(hwnd);
                            return LRESULT(0);
                        }
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

                    if (*state_ptr).reference_active {
                        let unpin_rc = unpin_button_rect(&cr);
                        if point_in_rect(x, y, &unpin_rc) {
                            let _ = (*state_ptr).sender.send(WorkAreaEvent::UnpinClicked);
                            return LRESULT(0);
                        }
                    }
                }
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            WM_MOUSEMOVE => {
                if !state_ptr.is_null() && (*state_ptr).divider_dragging {
                    let x = get_x_lparam(lparam);
                    // Compute new split ratio from cursor x position.
                    let cr = client_rect(hwnd);
                    let usable_w = ((cr.right - cr.left) as f64
                        - PADDING_LEFT - PADDING_RIGHT).max(1.0);
                    let relative_x = x as f64 - PADDING_LEFT;
                    let new_ratio = (relative_x / usable_w)
                        .clamp(MIN_SPLIT_RATIO, MAX_SPLIT_RATIO);
                    (*state_ptr).split_ratio = new_ratio;
                    let _ = (*state_ptr)
                        .sender
                        .send(WorkAreaEvent::SplitRatioChanged(new_ratio));
                    InvalidateRect(hwnd, None, false);
                    return LRESULT(0);
                }
            }

            WM_LBUTTONUP => {
                if !state_ptr.is_null() && (*state_ptr).divider_dragging {
                    (*state_ptr).divider_dragging = false;
                    let _ = ReleaseCapture();
                    return LRESULT(0);
                }
            }

            // Cancel divider drag on system interruptions (modal dialogs, Alt+Tab, etc.)
            0x001F /* WM_CANCELMODE */ => {
                if !state_ptr.is_null() && (*state_ptr).divider_dragging {
                    (*state_ptr).divider_dragging = false;
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

    unsafe fn paint_bottom_bar(
        _hwnd: HWND,
        hdc: windows::Win32::Graphics::Gdi::HDC,
        client: &RECT,
        state_ptr: *const WindowState,
    ) {
        // Semi-transparent dark bar at the bottom.
        let bar_rect = RECT {
            left: 0,
            top: client.bottom - BOTTOM_BAR_HEIGHT,
            right: client.right,
            bottom: client.bottom,
        };
        let bar_brush = CreateSolidBrush(COLORREF(0x00201010)); // dark
        FillRect(hdc, &bar_rect, bar_brush);
        DeleteObject(bar_brush);

        // Create font for labels.
        let face = wide("Segoe UI");
        let font = CreateFontW(
            14,                                     // height
            0,                                      // width (auto)
            0,                                      // escapement
            0,                                      // orientation
            FW_NORMAL.0 as i32,                     // weight
            0,                                      // italic
            0,                                      // underline
            0,                                      // strikeout
            DEFAULT_CHARSET.0 as u32,               // charset
            OUT_DEFAULT_PRECIS.0 as u32,            // out precision
            CLIP_DEFAULT_PRECIS.0 as u32,           // clip precision
            CLEARTYPE_QUALITY.0 as u32,             // quality
            DEFAULT_PITCH.0 as u32,                 // pitch and family
            windows::core::PCWSTR(face.as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, COLORREF(0x00CCCCCC)); // light gray

        // "Exit" button — bottom-left.
        let mut exit_rc = exit_button_rect(client);
        let mut exit_text = wide("\u{2715} Exit");
        DrawTextW(
            hdc,
            &mut exit_text,
            &mut exit_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );

        // "Switch (Alt)" button — bottom-right.
        let mut switch_rc = switch_button_rect(client);
        let mut switch_text = wide("\u{21E5} Switch (Alt)");
        DrawTextW(
            hdc,
            &mut switch_text,
            &mut switch_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );

        // "Unpin Ref" button — shown only when reference is active.
        if !state_ptr.is_null() && (*state_ptr).reference_active {
            let mut unpin_rc = unpin_button_rect(client);
            let mut unpin_text = wide("\u{2715} Unpin Ref");
            DrawTextW(
                hdc,
                &mut unpin_text,
                &mut unpin_rc,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE,
            );
        }

        // "Work Area" label — centered.
        let mut label_rc = RECT {
            left: client.left,
            top: client.bottom - BOTTOM_BAR_HEIGHT,
            right: client.right,
            bottom: client.bottom,
        };
        let mut label_text = wide("Work Area");
        DrawTextW(
            hdc,
            &mut label_text,
            &mut label_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );

        // Restore old font, delete ours.
        SelectObject(hdc, old_font);
        DeleteObject(font);
    }

    // ------------------------------------------------------------------
    // Apply Mica backdrop (Windows 11)
    // ------------------------------------------------------------------

    unsafe fn apply_mica_backdrop(hwnd: HWND) {
        // Enable immersive dark mode.
        let dark: u32 = 1;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark as *const u32 as *const core::ffi::c_void,
            mem::size_of::<u32>() as u32,
        );

        // Extend frame into entire client area for DWM composition.
        let margins = MARGINS {
            cxLeftWidth: -1,
            cxRightWidth: -1,
            cyTopHeight: -1,
            cyBottomHeight: -1,
        };
        let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

        // Set system backdrop type to Mica Alt (tabbed window).
        let backdrop_type: DWM_SYSTEMBACKDROP_TYPE = DWMSBT_TABBEDWINDOW;
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

    // HWND is Send-safe when properly managed.
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

                let ex_style = WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP;
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
                    None,
                    None,
                    hinstance,
                    None,
                )
                .map_err(|e| format!("CreateWindowExW failed: {e}"))?;

                // Allocate per-window state on the heap.
                let state = Box::into_raw(Box::new(WindowState {
                    sender,
                    split_ratio: DEFAULT_SPLIT_RATIO,
                    reference_active: false,
                    divider_dragging: false,
                }));
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as isize);

                // Apply Mica backdrop (best-effort; fails gracefully on older Windows).
                apply_mica_backdrop(hwnd);

                // Place behind normal windows.
                let _ = SetWindowPos(
                    hwnd,
                    HWND_BOTTOM,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );

                log::info!("WorkArea window created (hwnd={:?})", hwnd);

                Ok(WorkAreaWindow {
                    hwnd,
                    class_atom,
                    state,
                })
            }
        }

        pub fn hwnd(&self) -> isize {
            self.hwnd.0 as isize
        }

        pub fn frame(&self) -> Rect {
            unsafe { window_rect(self.hwnd) }
        }

        pub fn set_frame(&self, frame: &Rect) {
            unsafe {
                let _ = SetWindowPos(
                    self.hwnd,
                    None,
                    frame.x.round() as i32,
                    frame.y.round() as i32,
                    frame.width.round() as i32,
                    frame.height.round() as i32,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
        }

        /// The usable interior, inset by padding.
        pub fn usable_frame(&self) -> Rect {
            let f = self.frame();
            Rect::new(
                f.x + PADDING_LEFT,
                f.y + PADDING_TOP,
                (f.width - PADDING_LEFT - PADDING_RIGHT).max(0.0),
                (f.height - PADDING_TOP - PADDING_BOTTOM).max(0.0),
            )
        }

        pub fn split_ratio(&self) -> f64 {
            unsafe {
                if self.state.is_null() {
                    DEFAULT_SPLIT_RATIO
                } else {
                    (*self.state).split_ratio
                }
            }
        }

        pub fn set_split_ratio(&mut self, ratio: f64) {
            let clamped = ratio.clamp(MIN_SPLIT_RATIO, MAX_SPLIT_RATIO);
            unsafe {
                if !self.state.is_null() {
                    (*self.state).split_ratio = clamped;
                    let _ = (*self.state)
                        .sender
                        .send(WorkAreaEvent::SplitRatioChanged(clamped));
                }
            }
        }

        /// Main panel frame (left side) when a reference is pinned.
        pub fn main_panel_frame(&self) -> Rect {
            let uf = self.usable_frame();
            let ratio = self.split_ratio();
            let main_w = (uf.width - SPLIT_GAP) * ratio;
            Rect::new(uf.x, uf.y, main_w.max(0.0), uf.height)
        }

        /// Reference panel frame (right side) when a reference is pinned.
        pub fn reference_panel_frame(&self) -> Rect {
            let uf = self.usable_frame();
            let ratio = self.split_ratio();
            let main_w = (uf.width - SPLIT_GAP) * ratio;
            let ref_x = uf.x + main_w + SPLIT_GAP;
            let ref_w = (uf.width - main_w - SPLIT_GAP).max(0.0);
            Rect::new(ref_x, uf.y, ref_w, uf.height)
        }

        pub fn set_reference_active(&mut self, active: bool) {
            unsafe {
                if !self.state.is_null() {
                    (*self.state).reference_active = active;
                    // Repaint to show/hide the unpin button.
                    InvalidateRect(self.hwnd, None, false);
                }
            }
        }

        pub fn show(&self) {
            unsafe {
                ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                // Keep behind normal windows.
                let _ = SetWindowPos(
                    self.hwnd,
                    HWND_BOTTOM,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );
            }
        }

        pub fn hide(&self) {
            unsafe {
                ShowWindow(self.hwnd, SW_HIDE);
            }
        }

        pub fn destroy(&mut self) {
            unsafe {
                if !self.hwnd.is_invalid() {
                    // Clear user data before destroying.
                    SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
                    let _ = DestroyWindow(self.hwnd);
                    self.hwnd = HWND::default();
                }

                // Free the heap-allocated state.
                if !self.state.is_null() {
                    let _ = Box::from_raw(self.state);
                    self.state = std::ptr::null_mut();
                }

                // Unregister the window class.
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
        fn drop(&mut self) {
            self.destroy();
        }
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
        split_ratio: f64,
        reference_active: bool,
    }

    impl WorkAreaWindow {
        pub fn new(
            frame: &Rect,
            _sender: Sender<WorkAreaEvent>,
        ) -> Result<Self, String> {
            Ok(WorkAreaWindow {
                frame: *frame,
                split_ratio: DEFAULT_SPLIT_RATIO,
                reference_active: false,
            })
        }

        pub fn hwnd(&self) -> isize {
            0
        }

        pub fn frame(&self) -> Rect {
            self.frame
        }

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

        pub fn split_ratio(&self) -> f64 {
            self.split_ratio
        }

        pub fn set_split_ratio(&mut self, ratio: f64) {
            self.split_ratio = ratio.clamp(MIN_SPLIT_RATIO, MAX_SPLIT_RATIO);
        }

        pub fn main_panel_frame(&self) -> Rect {
            let uf = self.usable_frame();
            let main_w = (uf.width - SPLIT_GAP) * self.split_ratio;
            Rect::new(uf.x, uf.y, main_w.max(0.0), uf.height)
        }

        pub fn reference_panel_frame(&self) -> Rect {
            let uf = self.usable_frame();
            let main_w = (uf.width - SPLIT_GAP) * self.split_ratio;
            let ref_x = uf.x + main_w + SPLIT_GAP;
            let ref_w = (uf.width - main_w - SPLIT_GAP).max(0.0);
            Rect::new(ref_x, uf.y, ref_w, uf.height)
        }

        pub fn set_reference_active(&mut self, active: bool) {
            self.reference_active = active;
        }

        pub fn show(&self) {}
        pub fn hide(&self) {}
        pub fn destroy(&mut self) {}
    }
}

// Re-export the platform-specific implementation.
pub use platform::WorkAreaWindow;
