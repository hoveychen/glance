//! Overlay window management for Glance thumbnail windows.
//!
//! Each tracked window gets its own Win32 overlay window that displays a DWM
//! thumbnail. This module handles creation, positioning, painting (header with
//! icon + title, hint badges, active/pinned borders), and mouse interaction
//! (click, drag, hover) for those overlay windows.

use crate::types::{WindowInfo, WindowSlot};
use std::collections::HashMap;
use std::sync::mpsc::Sender;

// ---------------------------------------------------------------------------
// OverlayEvent — events from overlay windows back to the app
// ---------------------------------------------------------------------------

/// Which side of the work area a window should be pinned to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinSide {
    Left,
    Right,
}

/// Events delivered from overlay windows to the main application loop.
#[derive(Debug, Clone, PartialEq)]
pub enum OverlayEvent {
    /// The user clicked on a thumbnail (source window hwnd).
    ThumbnailClicked(isize),
    /// The user started dragging a thumbnail.
    ThumbnailDragStarted(isize),
    /// The user is dragging a thumbnail (hwnd, screen x, screen y).
    ThumbnailDragMoved(isize, f64, f64),
    /// The user released a dragged thumbnail.
    ThumbnailDragCompleted(isize),
    /// The mouse entered a thumbnail overlay.
    ThumbnailHoverStart(isize),
    /// The mouse left a thumbnail overlay.
    ThumbnailHoverEnd(isize),
    /// Spring-load activation: file dragged over thumbnail for 2 seconds.
    SpringLoadActivated(isize),
    /// The user clicked a pin button on a thumbnail: (hwnd, side).
    PinClicked(isize, PinSide),
}

// ===========================================================================
// Windows implementation
// ===========================================================================

#[cfg(windows)]
mod platform {
    use super::*;
    use std::mem;

    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::{
        BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW,
        EndPaint, FillRect, FrameRect, InvalidateRect, SelectObject, SetBkMode, SetTextColor,
        PAINTSTRUCT, TRANSPARENT, DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE,
        DT_VCENTER, DT_CENTER, FW_BOLD, FW_NORMAL,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        ReleaseCapture, SetCapture, TrackMouseEvent, TME_HOVER, TME_LEAVE, TRACKMOUSEEVENT,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DrawIconEx, GetClientRect, GetCursorPos,
        GetWindowLongPtrW, RegisterClassExW, SetWindowLongPtrW, SetWindowPos, ShowWindow,
        GWLP_USERDATA, HTCLIENT, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOSIZE,
        SWP_SHOWWINDOW, SW_HIDE, SW_SHOWNOACTIVATE, WM_ERASEBKGND, WM_LBUTTONDOWN, WM_LBUTTONUP,
        WM_MOUSEMOVE, WM_NCHITTEST, WM_PAINT, WNDCLASSEXW, WS_EX_LAYERED,
        WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, DI_NORMAL,
        SetLayeredWindowAttributes, LWA_ALPHA,
    };

    /// WM_MOUSEHOVER (0x02A1) — from Win32 Controls, defined as raw constant
    /// to avoid adding a Win32_UI_Controls feature dependency.
    const WM_MOUSEHOVER: u32 = 0x02A1;
    /// WM_MOUSELEAVE (0x02A3) — from Win32 Controls.
    const WM_MOUSELEAVE: u32 = 0x02A3;

    use windows::Win32::System::Ole::{
        OleInitialize, RegisterDragDrop, RevokeDragDrop,
        DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
        IDropTarget, IDropTarget_Impl,
    };
    use windows::Win32::System::Com::IDataObject;
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::Foundation::POINTL;

    /// Delay before spring-load activates (2 seconds).
    const SPRING_LOAD_DELAY: std::time::Duration = std::time::Duration::from_secs(2);

    /// Height of the header area in pixels (matches layout engine's header_height).
    const HEADER_HEIGHT: i32 = 32;
    /// Minimum mouse movement (pixels) to distinguish a drag from a click.
    const DRAG_THRESHOLD: i32 = 5;
    /// Size (square) of each pin button in the header.
    const PIN_BUTTON_SIZE: i32 = 22;
    /// Margin between pin buttons and from the right edge.
    const PIN_BUTTON_MARGIN: i32 = 4;

    /// Rect for the "pin left" button — leftmost of the two, only visible when hovered.
    fn pin_left_button_rect(width: i32) -> RECT {
        let right = width - PIN_BUTTON_MARGIN - PIN_BUTTON_SIZE - PIN_BUTTON_MARGIN;
        let left = right - PIN_BUTTON_SIZE;
        let top = (HEADER_HEIGHT - PIN_BUTTON_SIZE) / 2;
        RECT { left, top, right, bottom: top + PIN_BUTTON_SIZE }
    }

    /// Rect for the "pin right" button — rightmost of the two.
    fn pin_right_button_rect(width: i32) -> RECT {
        let right = width - PIN_BUTTON_MARGIN;
        let left = right - PIN_BUTTON_SIZE;
        let top = (HEADER_HEIGHT - PIN_BUTTON_SIZE) / 2;
        RECT { left, top, right, bottom: top + PIN_BUTTON_SIZE }
    }

    fn point_in_rect(x: i32, y: i32, rc: &RECT) -> bool {
        x >= rc.left && x < rc.right && y >= rc.top && y < rc.bottom
    }

    /// Wide class name for overlay windows, null-terminated.
    const CLASS_NAME: &[u16] = &[
        b'G' as u16, b'l' as u16, b'a' as u16, b'n' as u16, b'c' as u16, b'e' as u16,
        b'T' as u16, b'h' as u16, b'u' as u16, b'm' as u16, b'b' as u16, b'n' as u16,
        b'a' as u16, b'i' as u16, b'l' as u16, b'O' as u16, b'v' as u16, b'e' as u16,
        b'r' as u16, b'l' as u16, b'a' as u16, b'y' as u16, 0,
    ];

    /// COLORREF helper: RGB(r, g, b).
    const fn rgb(r: u8, g: u8, b: u8) -> u32 {
        r as u32 | ((g as u32) << 8) | ((b as u32) << 16)
    }

    // Colors
    const COLOR_HEADER_BG: u32 = rgb(30, 30, 30);        // dark background
    const COLOR_TEXT_WHITE: u32 = rgb(255, 255, 255);
    const COLOR_BORDER_ACTIVE: u32 = rgb(76, 175, 80);    // green
    const COLOR_BORDER_PINNED: u32 = rgb(33, 150, 243);   // blue
    const COLOR_BORDER_HOVER: u32 = rgb(33, 150, 243);    // blue
    const COLOR_HINT_BG: u32 = rgb(255, 235, 59);         // yellow
    const COLOR_DIM_OVERLAY: u32 = rgb(0, 0, 0);          // dim overlay (semi-transparent black)

    // -----------------------------------------------------------------------
    // Per-window state stored via GWLP_USERDATA
    // -----------------------------------------------------------------------

    /// Visual state for an overlay (active, pinned, hint, hover).
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum OverlayVisualState {
        Normal,
        Active,
        Pinned,
        Hovered,
    }

    /// Per-overlay-window state, heap-allocated and stored in GWLP_USERDATA.
    struct OverlayWindowState {
        source_hwnd: isize,
        title: String,
        icon: Option<windows::Win32::UI::WindowsAndMessaging::HICON>,
        /// Sender for overlay events (cloned from the shared sender).
        sender: Sender<OverlayEvent>,
        // Mouse tracking state
        mouse_down: bool,
        mouse_down_pos: POINT,
        dragging: bool,
        mouse_tracked: bool,
        /// True while the cursor is within the overlay (between HOVER and LEAVE).
        /// Used to toggle pin-button visibility.
        is_mouse_inside: bool,
        // Visual state
        visual_state: OverlayVisualState,
        hint_char: Option<String>,
    }

    // -----------------------------------------------------------------------
    // Window class registration
    // -----------------------------------------------------------------------

    /// Track whether the class has been registered.
    static CLASS_REGISTERED: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);

    fn ensure_class_registered() {
        if CLASS_REGISTERED.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }

        unsafe {
            // Initialize OLE for drag-drop support (idempotent, returns S_FALSE
            // if COM/OLE is already initialised on this thread as STA).
            match OleInitialize(None) {
                Ok(()) => log::info!("OLE initialized for drag-drop support"),
                Err(e) => log::warn!("OleInitialize failed: {e} — spring-loading will be disabled"),
            }

            let hinstance = GetModuleHandleW(None).unwrap_or_default();

            // No class background brush: we want DWM to keep compositing the
            // registered thumbnail without an intervening erase cycle. WM_PAINT
            // redraws only the header region; the thumbnail area stays owned
            // by the DWM composition.
            let wc = WNDCLASSEXW {
                cbSize: mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(overlay_wnd_proc),
                hInstance: hinstance.into(),
                lpszClassName: PCWSTR(CLASS_NAME.as_ptr()),
                ..Default::default()
            };

            let atom = RegisterClassExW(&wc);
            if atom != 0 {
                CLASS_REGISTERED.store(true, std::sync::atomic::Ordering::SeqCst);
                log::info!("Registered overlay window class");
            } else {
                log::error!("Failed to register overlay window class");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Spring-load drop target (OLE IDropTarget)
    // -----------------------------------------------------------------------

    /// COM object implementing IDropTarget for spring-load behaviour.
    /// When a file is dragged over an overlay for SPRING_LOAD_DELAY, the
    /// corresponding window is activated (like macOS spring-loading).
    #[windows::core::implement(IDropTarget)]
    struct OverlayDropTarget {
        source_hwnd: isize,
        sender: Sender<OverlayEvent>,
        enter_time: std::cell::Cell<Option<std::time::Instant>>,
        triggered: std::cell::Cell<bool>,
    }

    impl IDropTarget_Impl for OverlayDropTarget_Impl {
        fn DragEnter(
            &self,
            _pdataobj: Option<&IDataObject>,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            self.enter_time.set(Some(std::time::Instant::now()));
            self.triggered.set(false);
            unsafe { *pdweffect = DROPEFFECT_COPY; }
            Ok(())
        }

        fn DragOver(
            &self,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            unsafe { *pdweffect = DROPEFFECT_COPY; }
            // Check if the spring-load delay has elapsed.
            if !self.triggered.get() {
                if let Some(enter) = self.enter_time.get() {
                    if enter.elapsed() >= SPRING_LOAD_DELAY {
                        self.triggered.set(true);
                        let _ = self
                            .sender
                            .send(OverlayEvent::SpringLoadActivated(self.source_hwnd));
                        log::debug!(
                            "Spring-load activated for {:#x}",
                            self.source_hwnd
                        );
                    }
                }
            }
            Ok(())
        }

        fn DragLeave(&self) -> windows::core::Result<()> {
            self.enter_time.set(None);
            self.triggered.set(false);
            Ok(())
        }

        fn Drop(
            &self,
            _pdataobj: Option<&IDataObject>,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            // We don't handle the actual drop; just clear state.
            self.enter_time.set(None);
            self.triggered.set(false);
            unsafe { *pdweffect = DROPEFFECT_NONE; }
            Ok(())
        }
    }

    // -----------------------------------------------------------------------
    // Window procedure
    // -----------------------------------------------------------------------

    unsafe extern "system" fn overlay_wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        // Retrieve per-window state.
        let state_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut OverlayWindowState;
        if state_ptr.is_null() {
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        }
        let state = &mut *state_ptr;

        match msg {
            WM_NCHITTEST => {
                // Always return HTCLIENT so the window receives mouse events.
                LRESULT(HTCLIENT as isize)
            }

            WM_ERASEBKGND => {
                // Skip the default erase to prevent flicker: the thumbnail
                // area is owned by DWM composition, and WM_PAINT redraws the
                // header region itself.
                LRESULT(1)
            }

            WM_LBUTTONDOWN => {
                // Check pin buttons first (only when hovered).
                let lx = (lparam.0 & 0xFFFF) as i16 as i32;
                let ly = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                if state.is_mouse_inside {
                    let mut client_rect = RECT::default();
                    let _ = GetClientRect(hwnd, &mut client_rect);
                    let w = client_rect.right - client_rect.left;
                    let pin_l = pin_left_button_rect(w);
                    let pin_r = pin_right_button_rect(w);
                    if point_in_rect(lx, ly, &pin_l) {
                        let _ = state.sender.send(OverlayEvent::PinClicked(
                            state.source_hwnd,
                            PinSide::Left,
                        ));
                        return LRESULT(0);
                    }
                    if point_in_rect(lx, ly, &pin_r) {
                        let _ = state.sender.send(OverlayEvent::PinClicked(
                            state.source_hwnd,
                            PinSide::Right,
                        ));
                        return LRESULT(0);
                    }
                }

                // Record position for click vs drag detection.
                state.mouse_down = true;
                state.dragging = false;
                let mut pt = POINT::default();
                let _ = GetCursorPos(&mut pt);
                state.mouse_down_pos = pt;

                // Capture the mouse so we get WM_MOUSEMOVE/UP even outside the window.
                SetCapture(hwnd);

                LRESULT(0)
            }

            WM_MOUSEMOVE => {
                // Ensure hover/leave tracking is set up.
                if !state.mouse_tracked {
                    let mut tme = TRACKMOUSEEVENT {
                        cbSize: mem::size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_HOVER | TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 200, // ms
                    };
                    let _ = TrackMouseEvent(&mut tme);
                    state.mouse_tracked = true;
                }

                if state.mouse_down {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);

                    let dx = (pt.x - state.mouse_down_pos.x).abs();
                    let dy = (pt.y - state.mouse_down_pos.y).abs();

                    if !state.dragging && (dx > DRAG_THRESHOLD || dy > DRAG_THRESHOLD) {
                        // Start drag
                        state.dragging = true;
                        let _ = state
                            .sender
                            .send(OverlayEvent::ThumbnailDragStarted(state.source_hwnd));
                    }

                    if state.dragging {
                        // Move the overlay window to follow the cursor.
                        let mut client_rect = RECT::default();
                        let _ = GetClientRect(hwnd, &mut client_rect);
                        let w = client_rect.right - client_rect.left;
                        let h = client_rect.bottom - client_rect.top;
                        let _ = SetWindowPos(
                            hwnd,
                            HWND_TOPMOST,
                            pt.x - w / 2,
                            pt.y - h / 2,
                            0,
                            0,
                            SWP_NOACTIVATE | SWP_NOSIZE,
                        );

                        let _ = state.sender.send(OverlayEvent::ThumbnailDragMoved(
                            state.source_hwnd,
                            pt.x as f64,
                            pt.y as f64,
                        ));
                    }
                }

                LRESULT(0)
            }

            WM_LBUTTONUP => {
                let was_dragging = state.dragging;
                state.mouse_down = false;
                state.dragging = false;

                // Release capture.
                let _ = ReleaseCapture();

                if was_dragging {
                    let _ = state
                        .sender
                        .send(OverlayEvent::ThumbnailDragCompleted(state.source_hwnd));
                } else {
                    let _ = state
                        .sender
                        .send(OverlayEvent::ThumbnailClicked(state.source_hwnd));
                }

                LRESULT(0)
            }

            WM_MOUSEHOVER => {
                let _ = state
                    .sender
                    .send(OverlayEvent::ThumbnailHoverStart(state.source_hwnd));
                state.is_mouse_inside = true;
                let _ = InvalidateRect(hwnd, None, false);
                // Re-arm tracking for leave events.
                state.mouse_tracked = false;
                LRESULT(0)
            }

            WM_MOUSELEAVE => {
                let _ = state
                    .sender
                    .send(OverlayEvent::ThumbnailHoverEnd(state.source_hwnd));
                state.is_mouse_inside = false;
                let _ = InvalidateRect(hwnd, None, false);
                state.mouse_tracked = false;
                LRESULT(0)
            }

            WM_PAINT => {
                paint_overlay(hwnd, state);
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    // -----------------------------------------------------------------------
    // Painting
    // -----------------------------------------------------------------------

    unsafe fn paint_overlay(hwnd: HWND, state: &OverlayWindowState) {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);

        let mut client_rect = RECT::default();
        let _ = GetClientRect(hwnd, &mut client_rect);
        let width = client_rect.right - client_rect.left;

        // --- Header background ---
        // Do not fill the thumbnail area: DWM composites the registered
        // thumbnail on top of this window, and any fill there would flicker
        // during repaint before the composition frame runs.
        let header_rect = RECT {
            left: 0,
            top: 0,
            right: width,
            bottom: HEADER_HEIGHT,
        };
        let header_brush =
            CreateSolidBrush(windows::Win32::Foundation::COLORREF(COLOR_HEADER_BG));
        FillRect(hdc, &header_rect, header_brush);
        let _ = DeleteObject(header_brush);

        // --- App icon (16x16) in the header ---
        let icon_x = 8;
        let icon_y = (HEADER_HEIGHT - 16) / 2;
        if let Some(ref icon) = state.icon {
            let _ = DrawIconEx(
                hdc,
                icon_x,
                icon_y,
                *icon,
                16,
                16,
                0,
                None,
                DI_NORMAL,
            );
        }

        // --- Title text ---
        let text_left = if state.icon.is_some() { 28 } else { 8 };
        let mut text_rect = RECT {
            left: text_left,
            top: 0,
            right: width - 8,
            bottom: HEADER_HEIGHT,
        };

        let font = CreateFontW(
            14,                  // height
            0,                   // width (auto)
            0,                   // escapement
            0,                   // orientation
            FW_NORMAL.0 as i32,  // weight
            0,                   // italic
            0,                   // underline
            0,                   // strikeout
            0,                   // charset (DEFAULT_CHARSET)
            0,                   // out precision
            0,                   // clip precision
            0,                   // quality
            0,                   // pitch and family
            PCWSTR(encode_wide("Segoe UI\0").as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        SetTextColor(hdc, windows::Win32::Foundation::COLORREF(COLOR_TEXT_WHITE));
        SetBkMode(hdc, TRANSPARENT);

        let title_wide = encode_wide_no_null(&state.title);
        DrawTextW(
            hdc,
            &mut title_wide.clone(),
            &mut text_rect,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
        );

        SelectObject(hdc, old_font);
        let _ = DeleteObject(font);

        // --- Active/Pinned dim overlay + label ---
        match state.visual_state {
            OverlayVisualState::Active => {
                paint_dim_overlay(hdc, &client_rect, "Active", COLOR_BORDER_ACTIVE);
            }
            OverlayVisualState::Pinned => {
                paint_dim_overlay(hdc, &client_rect, "Pinned", COLOR_BORDER_PINNED);
            }
            _ => {}
        }

        // --- Border ---
        match state.visual_state {
            OverlayVisualState::Active => {
                paint_border(hdc, &client_rect, COLOR_BORDER_ACTIVE, 2);
            }
            OverlayVisualState::Pinned => {
                paint_border(hdc, &client_rect, COLOR_BORDER_PINNED, 2);
            }
            OverlayVisualState::Hovered => {
                paint_border(hdc, &client_rect, COLOR_BORDER_HOVER, 3);
            }
            OverlayVisualState::Normal => {}
        }

        // --- Pin buttons (visible on hover, hidden in hint mode) ---
        if state.is_mouse_inside && state.hint_char.is_none() {
            paint_pin_buttons(hdc, width);
        }

        // --- Hint badge ---
        if let Some(ref hint) = state.hint_char {
            paint_hint_badge(hdc, &client_rect, hint);
        }

        let _ = EndPaint(hwnd, &ps);
    }

    /// Paint the two pin buttons (left/right) in the header.
    unsafe fn paint_pin_buttons(
        hdc: windows::Win32::Graphics::Gdi::HDC,
        width: i32,
    ) {
        let btn_bg = CreateSolidBrush(windows::Win32::Foundation::COLORREF(rgb(60, 60, 60)));
        let left = pin_left_button_rect(width);
        let right = pin_right_button_rect(width);
        FillRect(hdc, &left, btn_bg);
        FillRect(hdc, &right, btn_bg);
        let _ = DeleteObject(btn_bg);

        // Icon: half-filled rectangle (filled on the side of the pin).
        // Use two colored rects: an outline (white) and a filled half (white).
        let white = CreateSolidBrush(windows::Win32::Foundation::COLORREF(COLOR_TEXT_WHITE));
        // Left-pin: fill the LEFT half of the button.
        let half_l_w = (left.right - left.left) / 2;
        let left_fill = RECT {
            left: left.left + 3,
            top: left.top + 5,
            right: left.left + 3 + half_l_w - 3,
            bottom: left.bottom - 5,
        };
        FillRect(hdc, &left_fill, white);
        // Right-pin: fill the RIGHT half of the button.
        let half_r_w = (right.right - right.left) / 2;
        let right_fill = RECT {
            left: right.left + half_r_w,
            top: right.top + 5,
            right: right.right - 3,
            bottom: right.bottom - 5,
        };
        FillRect(hdc, &right_fill, white);
        let _ = DeleteObject(white);

        // Outline both buttons.
        let outline = CreateSolidBrush(windows::Win32::Foundation::COLORREF(COLOR_TEXT_WHITE));
        FrameRect(hdc, &RECT {
            left: left.left + 3, top: left.top + 5,
            right: left.right - 3, bottom: left.bottom - 5,
        }, outline);
        FrameRect(hdc, &RECT {
            left: right.left + 3, top: right.top + 5,
            right: right.right - 3, bottom: right.bottom - 5,
        }, outline);
        let _ = DeleteObject(outline);
    }

    /// Paint a semi-transparent dim overlay with a centered label.
    unsafe fn paint_dim_overlay(
        hdc: windows::Win32::Graphics::Gdi::HDC,
        rect: &RECT,
        label: &str,
        _border_color: u32,
    ) {
        // Paint a dark overlay over the thumbnail area (below header).
        let dim_rect = RECT {
            left: rect.left,
            top: HEADER_HEIGHT,
            right: rect.right,
            bottom: rect.bottom,
        };
        let dim_brush =
            CreateSolidBrush(windows::Win32::Foundation::COLORREF(COLOR_DIM_OVERLAY));
        FillRect(hdc, &dim_rect, dim_brush);
        let _ = DeleteObject(dim_brush);

        // Draw the label text centered in the thumbnail area.
        let font = CreateFontW(
            18,
            0, 0, 0,
            FW_BOLD.0 as i32,
            0, 0, 0, 0, 0, 0, 0, 0,
            PCWSTR(encode_wide("Segoe UI\0").as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        SetTextColor(hdc, windows::Win32::Foundation::COLORREF(COLOR_TEXT_WHITE));
        SetBkMode(hdc, TRANSPARENT);

        let mut label_rect = dim_rect;
        let label_wide = encode_wide_no_null(label);
        DrawTextW(
            hdc,
            &mut label_wide.clone(),
            &mut label_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        );

        SelectObject(hdc, old_font);
        let _ = DeleteObject(font);
    }

    /// Paint a border of the given color and thickness around the window.
    unsafe fn paint_border(
        hdc: windows::Win32::Graphics::Gdi::HDC,
        rect: &RECT,
        color: u32,
        thickness: i32,
    ) {
        let brush = CreateSolidBrush(windows::Win32::Foundation::COLORREF(color));
        for i in 0..thickness {
            let border_rect = RECT {
                left: rect.left + i,
                top: rect.top + i,
                right: rect.right - i,
                bottom: rect.bottom - i,
            };
            FrameRect(hdc, &border_rect, brush);
        }
        let _ = DeleteObject(brush);
    }

    /// Paint a hint badge centered in the overlay.
    unsafe fn paint_hint_badge(
        hdc: windows::Win32::Graphics::Gdi::HDC,
        rect: &RECT,
        hint: &str,
    ) {
        let badge_w = 40;
        let badge_h = 40;
        let cx = (rect.left + rect.right) / 2;
        let cy = (rect.top + rect.bottom) / 2;

        let badge_rect = RECT {
            left: cx - badge_w / 2,
            top: cy - badge_h / 2,
            right: cx + badge_w / 2,
            bottom: cy + badge_h / 2,
        };

        // Yellow background
        let bg_brush =
            CreateSolidBrush(windows::Win32::Foundation::COLORREF(COLOR_HINT_BG));
        FillRect(hdc, &badge_rect, bg_brush);
        let _ = DeleteObject(bg_brush);

        // White bold text
        let font = CreateFontW(
            24,
            0, 0, 0,
            FW_BOLD.0 as i32,
            0, 0, 0, 0, 0, 0, 0, 0,
            PCWSTR(encode_wide("Segoe UI\0").as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        SetTextColor(hdc, windows::Win32::Foundation::COLORREF(COLOR_TEXT_WHITE));
        SetBkMode(hdc, TRANSPARENT);

        let hint_wide = encode_wide_no_null(hint);
        let mut text_rect = badge_rect;
        DrawTextW(
            hdc,
            &mut hint_wide.clone(),
            &mut text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        );

        SelectObject(hdc, old_font);
        let _ = DeleteObject(font);
    }

    // -----------------------------------------------------------------------
    // String encoding helpers
    // -----------------------------------------------------------------------

    /// Encode a Rust string to a null-terminated Vec<u16>.
    fn encode_wide(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    /// Encode a Rust string to a Vec<u16> without null terminator
    /// (for use with DrawTextW which takes a length).
    fn encode_wide_no_null(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    // -----------------------------------------------------------------------
    // ThumbnailOverlayWindow
    // -----------------------------------------------------------------------

    /// Represents a single thumbnail overlay window.
    pub struct ThumbnailOverlayWindow {
        /// This overlay window's handle (raw isize).
        pub hwnd: isize,
        /// The source window being thumbnailed.
        pub source_hwnd: isize,
        /// The screen index this overlay is on.
        pub screen_index: usize,
        /// Pointer to the heap-allocated state (owned; freed on drop).
        state_ptr: *mut OverlayWindowState,
    }

    // SAFETY: The HWND and state_ptr are only accessed from the thread that
    // created them (the UI thread). We need Send to store in collections
    // that may be moved, but actual access is single-threaded.
    unsafe impl Send for ThumbnailOverlayWindow {}

    impl ThumbnailOverlayWindow {
        /// Create a new overlay window for the given source window.
        pub fn create(
            source_hwnd: isize,
            title: &str,
            icon: Option<windows::Win32::UI::WindowsAndMessaging::HICON>,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            screen_index: usize,
            sender: Sender<OverlayEvent>,
        ) -> Result<Self, String> {
            ensure_class_registered();

            unsafe {
                let hinstance = GetModuleHandleW(None)
                    .map_err(|e| format!("GetModuleHandleW failed: {e}"))?;

                let ex_style = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW;

                let hwnd = CreateWindowExW(
                    ex_style,
                    PCWSTR(CLASS_NAME.as_ptr()),
                    PCWSTR::null(),
                    WS_POPUP,
                    x,
                    y,
                    width,
                    height,
                    None,
                    None,
                    hinstance,
                    None,
                )
                .map_err(|e| format!("CreateWindowExW failed: {e}"))?;

                // For WS_EX_LAYERED windows, we need to set the layered window
                // attributes so the window is visible. Use per-pixel alpha = 255
                // (fully opaque) via SetLayeredWindowAttributes.
                let _ = SetLayeredWindowAttributes(
                    hwnd,
                    windows::Win32::Foundation::COLORREF(0),
                    255, // fully opaque
                    LWA_ALPHA,
                );

                // Clone sender for the drop target before consuming it.
                let drop_sender = sender.clone();

                // Allocate per-window state on the heap.
                let state = Box::new(OverlayWindowState {
                    source_hwnd,
                    title: title.to_string(),
                    icon,
                    sender,
                    mouse_down: false,
                    mouse_down_pos: POINT::default(),
                    dragging: false,
                    mouse_tracked: false,
                    is_mouse_inside: false,
                    visual_state: OverlayVisualState::Normal,
                    hint_char: None,
                });
                let state_ptr = Box::into_raw(state);

                // Store the pointer in GWLP_USERDATA.
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, state_ptr as isize);

                // Register OLE drop target for spring-loading.
                let drop_target: IDropTarget = OverlayDropTarget {
                    source_hwnd,
                    sender: drop_sender,
                    enter_time: std::cell::Cell::new(None),
                    triggered: std::cell::Cell::new(false),
                }
                .into();
                if let Err(e) = RegisterDragDrop(hwnd, &drop_target) {
                    log::warn!("RegisterDragDrop failed for overlay {:#x}: {e}", source_hwnd);
                }

                // Show the window without activating it.
                let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);

                let raw_hwnd = hwnd.0 as isize;
                Ok(ThumbnailOverlayWindow {
                    hwnd: raw_hwnd,
                    source_hwnd,
                    screen_index,
                    state_ptr,
                })
            }
        }

        /// Reposition and resize the overlay window.
        pub fn set_position(&self, x: i32, y: i32, width: i32, height: i32) {
            unsafe {
                let hwnd = HWND(self.hwnd as *mut _);
                let _ = SetWindowPos(
                    hwnd,
                    HWND_TOPMOST,
                    x,
                    y,
                    width,
                    height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW,
                );
            }
        }

        /// Update the title text displayed in the header.
        pub fn set_title(&mut self, title: &str) {
            if self.state_ptr.is_null() {
                return;
            }
            unsafe {
                if (*self.state_ptr).title == title {
                    return;
                }
                (*self.state_ptr).title = title.to_string();
                self.invalidate();
            }
        }

        /// Update the icon displayed in the header.
        pub fn set_icon(&mut self, icon: Option<windows::Win32::UI::WindowsAndMessaging::HICON>) {
            if self.state_ptr.is_null() {
                return;
            }
            unsafe {
                if (*self.state_ptr).icon == icon {
                    return;
                }
                (*self.state_ptr).icon = icon;
                self.invalidate();
            }
        }

        /// Set the visual state (normal, active, pinned, hovered).
        pub fn set_visual_state(&mut self, visual_state: OverlayVisualState) {
            if self.state_ptr.is_null() {
                return;
            }
            unsafe {
                if (*self.state_ptr).visual_state == visual_state {
                    return;
                }
                (*self.state_ptr).visual_state = visual_state;
                self.invalidate();
            }
        }

        /// Set or clear the hint badge character.
        pub fn set_hint(&mut self, hint: Option<String>) {
            if self.state_ptr.is_null() {
                return;
            }
            unsafe {
                if (*self.state_ptr).hint_char == hint {
                    return;
                }
                (*self.state_ptr).hint_char = hint;
                self.invalidate();
            }
        }

        /// Hide this overlay window.
        pub fn hide(&self) {
            unsafe {
                let hwnd = HWND(self.hwnd as *mut _);
                let _ = ShowWindow(hwnd, SW_HIDE);
            }
        }

        /// Show this overlay window.
        pub fn show(&self) {
            unsafe {
                let hwnd = HWND(self.hwnd as *mut _);
                let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            }
        }

        /// Trigger a repaint without erasing the background. Erasing would
        /// briefly clear the region that DWM uses to composite the registered
        /// thumbnail, causing a visible flicker.
        fn invalidate(&self) {
            unsafe {
                let hwnd = HWND(self.hwnd as *mut _);
                let _ = InvalidateRect(hwnd, None, false);
            }
        }

        /// Destroy the overlay window.
        pub fn destroy(&mut self) {
            if self.hwnd != 0 {
                unsafe {
                    let hwnd = HWND(self.hwnd as *mut _);
                    // Revoke OLE drop target before destroying.
                    let _ = RevokeDragDrop(hwnd);
                    // Clear GWLP_USERDATA before destroying to prevent the
                    // wndproc from using a dangling pointer.
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                    let _ = DestroyWindow(hwnd);
                }
                self.hwnd = 0;
            }

            // Free the heap-allocated state.
            if !self.state_ptr.is_null() {
                unsafe {
                    let _ = Box::from_raw(self.state_ptr);
                }
                self.state_ptr = std::ptr::null_mut();
            }
        }
    }

    impl Drop for ThumbnailOverlayWindow {
        fn drop(&mut self) {
            self.destroy();
        }
    }

    // -----------------------------------------------------------------------
    // OverlayManager
    // -----------------------------------------------------------------------

    /// Manages all thumbnail overlay windows.
    pub struct OverlayManager {
        sender: Sender<OverlayEvent>,
        overlays: HashMap<isize, ThumbnailOverlayWindow>,
        active_hwnd: Option<isize>,
        pinned_hwnd: Option<isize>,
        hovered_hwnd: Option<isize>,
    }

    impl OverlayManager {
        /// Create a new overlay manager.
        pub fn new(sender: Sender<OverlayEvent>) -> Self {
            Self {
                sender,
                overlays: HashMap::new(),
                active_hwnd: None,
                pinned_hwnd: None,
                hovered_hwnd: None,
            }
        }

        /// Update overlay windows to match the given layout slots.
        ///
        /// Creates new overlays for new slots, removes overlays for slots that
        /// no longer exist, and repositions existing ones.
        pub fn update_slots(&mut self, slots: &[WindowSlot], windows: &[WindowInfo]) {
            let window_map: HashMap<isize, &WindowInfo> =
                windows.iter().map(|w| (w.hwnd, w)).collect();

            // Determine which source hwnds are in the new slot set.
            let new_ids: std::collections::HashSet<isize> =
                slots.iter().map(|s| s.window_id).collect();

            // Remove overlays whose source window is no longer in the slot set.
            let to_remove: Vec<isize> = self
                .overlays
                .keys()
                .copied()
                .filter(|id| !new_ids.contains(id))
                .collect();
            for id in to_remove {
                if let Some(mut overlay) = self.overlays.remove(&id) {
                    overlay.destroy();
                }
            }

            // Create or reposition overlays.
            for slot in slots {
                let x = slot.rect.x.round() as i32;
                let y = slot.rect.y.round() as i32;
                let w = slot.rect.width.round() as i32;
                let h = slot.rect.height.round() as i32;

                if let Some(existing) = self.overlays.get_mut(&slot.window_id) {
                    // Reposition the existing overlay.
                    existing.set_position(x, y, w, h);
                    existing.screen_index = slot.screen_index;

                    // Update title/icon if the window info changed.
                    if let Some(info) = window_map.get(&slot.window_id) {
                        existing.set_title(&info.title);
                        existing.set_icon(info.app_icon);
                    }
                } else {
                    // Create a new overlay window.
                    let (title, icon) = if let Some(info) = window_map.get(&slot.window_id) {
                        (info.title.as_str(), info.app_icon)
                    } else {
                        ("", None)
                    };

                    match ThumbnailOverlayWindow::create(
                        slot.window_id,
                        title,
                        icon,
                        x,
                        y,
                        w,
                        h,
                        slot.screen_index,
                        self.sender.clone(),
                    ) {
                        Ok(mut overlay) => {
                            // Apply visual state if this window is active or pinned.
                            self.apply_visual_state_to(&mut overlay);
                            self.overlays.insert(slot.window_id, overlay);
                        }
                        Err(e) => {
                            log::error!(
                                "Failed to create overlay for hwnd {:#x}: {e}",
                                slot.window_id
                            );
                        }
                    }
                }
            }

            // Refresh visual states for all existing overlays.
            let active = self.active_hwnd;
            let pinned = self.pinned_hwnd;
            let hovered = self.hovered_hwnd;
            for overlay in self.overlays.values_mut() {
                let vs = if Some(overlay.source_hwnd) == active {
                    OverlayVisualState::Active
                } else if Some(overlay.source_hwnd) == pinned {
                    OverlayVisualState::Pinned
                } else if Some(overlay.source_hwnd) == hovered {
                    OverlayVisualState::Hovered
                } else {
                    OverlayVisualState::Normal
                };
                overlay.set_visual_state(vs);
            }
        }

        /// Set which window is the active (foreground) window.
        pub fn set_active_window(&mut self, hwnd: Option<isize>) {
            let old = self.active_hwnd;
            self.active_hwnd = hwnd;

            // Update visual state for the old and new active windows.
            if let Some(old_hwnd) = old {
                if let Some(overlay) = self.overlays.get_mut(&old_hwnd) {
                    let vs = if Some(old_hwnd) == self.pinned_hwnd {
                        OverlayVisualState::Pinned
                    } else {
                        OverlayVisualState::Normal
                    };
                    overlay.set_visual_state(vs);
                }
            }
            if let Some(new_hwnd) = hwnd {
                if let Some(overlay) = self.overlays.get_mut(&new_hwnd) {
                    overlay.set_visual_state(OverlayVisualState::Active);
                }
            }
        }

        /// Set which window is the pinned reference window.
        pub fn set_pinned_reference(&mut self, hwnd: Option<isize>) {
            let old = self.pinned_hwnd;
            self.pinned_hwnd = hwnd;

            // Update visual state for the old and new pinned windows.
            if let Some(old_hwnd) = old {
                if let Some(overlay) = self.overlays.get_mut(&old_hwnd) {
                    let vs = if Some(old_hwnd) == self.active_hwnd {
                        OverlayVisualState::Active
                    } else {
                        OverlayVisualState::Normal
                    };
                    overlay.set_visual_state(vs);
                }
            }
            if let Some(new_hwnd) = hwnd {
                if let Some(overlay) = self.overlays.get_mut(&new_hwnd) {
                    // Active takes precedence over pinned.
                    if Some(new_hwnd) != self.active_hwnd {
                        overlay.set_visual_state(OverlayVisualState::Pinned);
                    }
                }
            }
        }

        /// Show hint badges on overlays, returning a mapping of hint key -> source hwnd.
        pub fn show_hints(&mut self, hint_keys: &[String]) -> HashMap<String, isize> {
            let mut mapping: HashMap<String, isize> = HashMap::new();
            let mut overlays_sorted: Vec<&mut ThumbnailOverlayWindow> =
                self.overlays.values_mut().collect();

            // Sort by screen index then by position (top-to-bottom, left-to-right)
            // for deterministic hint assignment.
            overlays_sorted.sort_by(|a, b| {
                a.screen_index
                    .cmp(&b.screen_index)
                    .then_with(|| a.hwnd.cmp(&b.hwnd))
            });

            for (i, overlay) in overlays_sorted.iter_mut().enumerate() {
                if let Some(key) = hint_keys.get(i) {
                    overlay.set_hint(Some(key.clone()));
                    mapping.insert(key.clone(), overlay.source_hwnd);
                }
            }

            mapping
        }

        /// Hide all hint badges.
        pub fn hide_hints(&mut self) {
            for overlay in self.overlays.values_mut() {
                overlay.set_hint(None);
            }
        }

        /// Hide all overlay windows (but don't destroy them).
        pub fn hide_all(&mut self) {
            for overlay in self.overlays.values() {
                overlay.hide();
            }
        }

        /// Destroy all overlay windows and clear the collection.
        pub fn destroy_all(&mut self) {
            for (_, mut overlay) in self.overlays.drain() {
                overlay.destroy();
            }
        }

        /// Return the mapping of source_hwnd → overlay_hwnd for DWM thumbnail registration.
        pub fn overlay_hwnds(&self) -> HashMap<isize, isize> {
            self.overlays
                .iter()
                .map(|(&source, overlay)| (source, overlay.hwnd))
                .collect()
        }

        /// Set hover visual state on the given source window's overlay.
        pub fn set_hovered(&mut self, hwnd: isize) {
            // Clear previous hover.
            if let Some(old) = self.hovered_hwnd {
                if old != hwnd {
                    if let Some(overlay) = self.overlays.get_mut(&old) {
                        let vs = if Some(old) == self.active_hwnd {
                            OverlayVisualState::Active
                        } else if Some(old) == self.pinned_hwnd {
                            OverlayVisualState::Pinned
                        } else {
                            OverlayVisualState::Normal
                        };
                        overlay.set_visual_state(vs);
                    }
                }
            }
            self.hovered_hwnd = Some(hwnd);
            // Only show hover if the window is not active or pinned.
            if Some(hwnd) != self.active_hwnd && Some(hwnd) != self.pinned_hwnd {
                if let Some(overlay) = self.overlays.get_mut(&hwnd) {
                    overlay.set_visual_state(OverlayVisualState::Hovered);
                }
            }
        }

        /// Clear hover visual state on the given source window's overlay.
        pub fn clear_hover(&mut self, hwnd: isize) {
            if self.hovered_hwnd == Some(hwnd) {
                self.hovered_hwnd = None;
            }
            if let Some(overlay) = self.overlays.get_mut(&hwnd) {
                let vs = if Some(hwnd) == self.active_hwnd {
                    OverlayVisualState::Active
                } else if Some(hwnd) == self.pinned_hwnd {
                    OverlayVisualState::Pinned
                } else {
                    OverlayVisualState::Normal
                };
                overlay.set_visual_state(vs);
            }
        }

        /// Find which source window's overlay contains the given screen point.
        /// Optionally exclude a specific source hwnd (e.g., the window being dragged).
        pub fn source_hwnd_at_point(&self, x: i32, y: i32, exclude: Option<isize>) -> Option<isize> {
            self.source_hwnd_and_rect_at_point(x, y, exclude)
                .map(|(h, _)| h)
        }

        /// Same as `source_hwnd_at_point` but also returns the overlay's screen
        /// rect (left, top, right, bottom) so callers can decide insertion side.
        pub fn source_hwnd_and_rect_at_point(
            &self,
            x: i32,
            y: i32,
            exclude: Option<isize>,
        ) -> Option<(isize, (i32, i32, i32, i32))> {
            for (&source_hwnd, overlay) in &self.overlays {
                if exclude == Some(source_hwnd) {
                    continue;
                }
                unsafe {
                    let hwnd = HWND(overlay.hwnd as *mut _);
                    let mut rc = RECT::default();
                    let _ = windows::Win32::UI::WindowsAndMessaging::GetWindowRect(hwnd, &mut rc);
                    if x >= rc.left && x < rc.right && y >= rc.top && y < rc.bottom {
                        return Some((source_hwnd, (rc.left, rc.top, rc.right, rc.bottom)));
                    }
                }
            }
            None
        }

        /// Apply the correct visual state to a single overlay based on
        /// active/pinned state.
        fn apply_visual_state_to(&self, overlay: &mut ThumbnailOverlayWindow) {
            let vs = if Some(overlay.source_hwnd) == self.active_hwnd {
                OverlayVisualState::Active
            } else if Some(overlay.source_hwnd) == self.pinned_hwnd {
                OverlayVisualState::Pinned
            } else {
                OverlayVisualState::Normal
            };
            overlay.set_visual_state(vs);
        }
    }

    impl Drop for OverlayManager {
        fn drop(&mut self) {
            self.destroy_all();
        }
    }
}

// ===========================================================================
// Non-Windows stubs (for cross-compilation / CI)
// ===========================================================================

#[cfg(not(windows))]
mod platform {
    use super::*;

    /// Stub visual state for non-Windows.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum OverlayVisualState {
        Normal,
        Active,
        Pinned,
        Hovered,
    }

    /// Stub thumbnail overlay window.
    pub struct ThumbnailOverlayWindow {
        pub hwnd: isize,
        pub source_hwnd: isize,
        pub screen_index: usize,
    }

    impl ThumbnailOverlayWindow {
        pub fn set_position(&self, _x: i32, _y: i32, _w: i32, _h: i32) {}
        pub fn set_title(&mut self, _title: &str) {}
        pub fn set_visual_state(&mut self, _state: OverlayVisualState) {}
        pub fn set_hint(&mut self, _hint: Option<String>) {}
        pub fn hide(&self) {}
        pub fn show(&self) {}
        pub fn destroy(&mut self) {}
    }

    /// Stub overlay manager.
    pub struct OverlayManager {
        _sender: Sender<OverlayEvent>,
    }

    impl OverlayManager {
        pub fn new(sender: Sender<OverlayEvent>) -> Self {
            Self { _sender: sender }
        }

        pub fn update_slots(&mut self, _slots: &[WindowSlot], _windows: &[WindowInfo]) {}

        pub fn set_active_window(&mut self, _hwnd: Option<isize>) {}

        pub fn set_pinned_reference(&mut self, _hwnd: Option<isize>) {}

        pub fn set_hovered(&mut self, _hwnd: isize) {}

        pub fn clear_hover(&mut self, _hwnd: isize) {}

        pub fn source_hwnd_at_point(&self, _x: i32, _y: i32, _exclude: Option<isize>) -> Option<isize> {
            None
        }

        pub fn source_hwnd_and_rect_at_point(
            &self,
            _x: i32,
            _y: i32,
            _exclude: Option<isize>,
        ) -> Option<(isize, (i32, i32, i32, i32))> {
            None
        }

        pub fn show_hints(&mut self, _hint_keys: &[String]) -> HashMap<String, isize> {
            HashMap::new()
        }

        pub fn hide_hints(&mut self) {}

        pub fn hide_all(&mut self) {}

        pub fn destroy_all(&mut self) {}

        pub fn overlay_hwnds(&self) -> HashMap<isize, isize> {
            HashMap::new()
        }
    }
}

// ===========================================================================
// Re-exports
// ===========================================================================

pub use platform::{OverlayManager, OverlayVisualState, ThumbnailOverlayWindow};
