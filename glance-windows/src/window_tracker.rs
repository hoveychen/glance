//! Window enumeration, classification, and real-time event tracking.
//!
//! This module is the Windows equivalent of the macOS `WindowTracker.swift`.
//! All Win32 FFI is guarded behind `#[cfg(windows)]` so the crate still
//! compiles (with stub implementations) on macOS / Linux for CI purposes.

use crate::types::{WindowClassification, WindowInfo};

// ---------------------------------------------------------------------------
// WindowEvent — events delivered from the Win32 event hook
// ---------------------------------------------------------------------------

/// Events delivered by the window-event hook to the main application.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowEvent {
    /// A new top-level window was created.
    Created(isize),
    /// A window was destroyed.
    Destroyed(isize),
    /// A window received foreground focus.
    Focused(isize),
    /// A window was moved or resized.
    Moved(isize),
}

// ===========================================================================
// Windows implementation
// ===========================================================================
#[cfg(windows)]
mod platform {
    use super::*;
    use crate::types::{Rect, HICON};
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use std::sync::mpsc::Sender;
    use std::sync::Mutex;

    use windows::Win32::Foundation::{
        CloseHandle, BOOL, HWND, LPARAM, MAX_PATH, RECT, TRUE,
    };
    use windows::Win32::Graphics::Dwm::{
        DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS,
    };
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Accessibility::{
        SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetClassLongPtrW, GetWindowLongW, GetWindowRect,
        GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
        IsIconic, IsWindowVisible, SendMessageTimeoutW, GCLP_HICON,
        GWL_EXSTYLE, GWL_STYLE, SMTO_ABORTIFHUNG, WM_GETICON,
        WS_CHILD, WS_DLGFRAME, WS_EX_APPWINDOW, WS_EX_NOACTIVATE,
        WS_EX_TOOLWINDOW, WS_EX_TOPMOST, ICON_BIG,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EVENT_OBJECT_CREATE, EVENT_OBJECT_DESTROY, EVENT_OBJECT_LOCATIONCHANGE,
        EVENT_SYSTEM_FOREGROUND, OBJID_WINDOW, WINEVENT_OUTOFCONTEXT,
        WINEVENT_SKIPOWNPROCESS,
    };

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    fn get_window_title(hwnd: HWND) -> String {
        unsafe {
            let len = GetWindowTextLengthW(hwnd);
            if len <= 0 {
                return String::new();
            }
            let mut buf = vec![0u16; (len + 1) as usize];
            let copied = GetWindowTextW(hwnd, &mut buf);
            if copied <= 0 {
                return String::new();
            }
            OsString::from_wide(&buf[..copied as usize])
                .to_string_lossy()
                .into_owned()
        }
    }

    fn get_process_name(pid: u32) -> String {
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            let Ok(handle) = handle else {
                return String::new();
            };
            let mut buf = [0u16; MAX_PATH as usize];
            let mut size = buf.len() as u32;
            let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, &mut buf, &mut size);
            let _ = CloseHandle(handle);
            if ok.is_err() || size == 0 {
                return String::new();
            }
            let full = OsString::from_wide(&buf[..size as usize])
                .to_string_lossy()
                .into_owned();
            // Extract just the filename (e.g. "chrome.exe").
            full.rsplit('\\')
                .next()
                .unwrap_or(&full)
                .to_string()
        }
    }

    fn get_window_frame(hwnd: HWND) -> Rect {
        unsafe {
            // Try DWM extended frame bounds first (more accurate).
            let mut rect = RECT::default();
            let hr = DwmGetWindowAttribute(
                hwnd,
                DWMWA_EXTENDED_FRAME_BOUNDS,
                &mut rect as *mut _ as *mut _,
                std::mem::size_of::<RECT>() as u32,
            );
            if hr.is_ok() {
                return Rect::new(
                    rect.left as f64,
                    rect.top as f64,
                    (rect.right - rect.left) as f64,
                    (rect.bottom - rect.top) as f64,
                );
            }
            // Fallback to GetWindowRect.
            let mut rect = RECT::default();
            if GetWindowRect(hwnd, &mut rect).is_ok() {
                Rect::new(
                    rect.left as f64,
                    rect.top as f64,
                    (rect.right - rect.left) as f64,
                    (rect.bottom - rect.top) as f64,
                )
            } else {
                Rect::new(0.0, 0.0, 0.0, 0.0)
            }
        }
    }

    fn get_app_icon(hwnd: HWND) -> Option<HICON> {
        unsafe {
            // Try SendMessageTimeout with WM_GETICON first.
            let mut result = windows::Win32::Foundation::LRESULT::default();
            let ok = SendMessageTimeoutW(
                hwnd,
                WM_GETICON,
                windows::Win32::Foundation::WPARAM(ICON_BIG as usize),
                windows::Win32::Foundation::LPARAM(0),
                SMTO_ABORTIFHUNG,
                100, // ms timeout
                Some(&mut result),
            );
            if ok != windows::Win32::Foundation::LRESULT(0) && result.0 != 0 {
                return Some(HICON(result.0 as *mut _));
            }
            // Fallback: class icon.
            let icon = GetClassLongPtrW(hwnd, GCLP_HICON);
            if icon != 0 {
                Some(HICON(icon as *mut _))
            } else {
                None
            }
        }
    }

    // -----------------------------------------------------------------------
    // Classification
    // -----------------------------------------------------------------------

    pub fn classify_window(hwnd: HWND) -> WindowClassification {
        unsafe {
            let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
            let ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;

            // Child windows are skipped entirely at the enumeration level,
            // but if called standalone, report as Unknown.
            if style & WS_CHILD.0 != 0 {
                return WindowClassification::Unknown;
            }

            // Tool window without app-window flag -> Popup.
            if ex_style & WS_EX_TOOLWINDOW.0 != 0 && ex_style & WS_EX_APPWINDOW.0 == 0 {
                return WindowClassification::Popup;
            }

            // No-activate -> System UI element.
            if ex_style & WS_EX_NOACTIVATE.0 != 0 {
                return WindowClassification::System;
            }

            // Dialog style (without WS_EX_APPWINDOW — apps with WS_DLGFRAME
            // that also set WS_EX_APPWINDOW should be treated as Normal).
            if style & WS_DLGFRAME.0 != 0 && ex_style & WS_EX_APPWINDOW.0 == 0 {
                return WindowClassification::Dialog;
            }

            // Has WS_EX_APPWINDOW -> Normal.
            if ex_style & WS_EX_APPWINDOW.0 != 0 {
                return WindowClassification::Normal;
            }

            // Owner-less top-level visible window -> Normal.
            use windows::Win32::UI::WindowsAndMessaging::GetWindow;
            use windows::Win32::UI::WindowsAndMessaging::GW_OWNER;
            let owner = GetWindow(hwnd, GW_OWNER);
            if owner.is_err() || owner.as_ref().unwrap().0.is_null() {
                return WindowClassification::Normal;
            }

            WindowClassification::Unknown
        }
    }

    // -----------------------------------------------------------------------
    // Enumeration
    // -----------------------------------------------------------------------

    pub fn enumerate_windows() -> Vec<WindowInfo> {
        // Pre-enumerate monitors so we can resolve screen indices inside the
        // callback without re-enumerating for every window.
        let monitors = crate::monitor::enumerate_monitors();

        unsafe extern "system" fn callback(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let ctx = &mut *(lparam.0 as *mut EnumCtx);

            // Skip invisible / minimized windows.
            if !IsWindowVisible(hwnd).as_bool() {
                return TRUE;
            }
            if IsIconic(hwnd).as_bool() {
                return TRUE;
            }

            // Skip child windows.
            let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
            if style & WS_CHILD.0 != 0 {
                return TRUE;
            }

            let classification = classify_window(hwnd);

            // Get PID.
            let mut pid: u32 = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));

            let owner_name = get_process_name(pid);
            let title = get_window_title(hwnd);
            let frame = get_window_frame(hwnd);

            let ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
            let window_level = if ex_style & WS_EX_TOPMOST.0 != 0 {
                1
            } else {
                0
            };

            let app_icon = get_app_icon(hwnd);
            let is_on_screen = frame.width > 0.0 && frame.height > 0.0;

            // Resolve screen index via MonitorFromWindow against our
            // pre-enumerated monitor list.
            let original_screen_index = monitor_index_for_hwnd(hwnd, &ctx.monitors);

            ctx.windows.push(WindowInfo {
                hwnd: hwnd.0 as isize,
                owner_pid: pid,
                owner_name,
                title,
                frame,
                is_on_screen,
                original_screen_index,
                classification,
                window_level,
                app_icon,
            });

            TRUE
        }

        struct EnumCtx {
            monitors: Vec<crate::monitor::MonitorInfo>,
            windows: Vec<WindowInfo>,
        }

        let mut ctx = EnumCtx {
            monitors,
            windows: Vec::new(),
        };

        unsafe {
            let _ = EnumWindows(
                Some(callback),
                LPARAM(&mut ctx as *mut EnumCtx as isize),
            );
        }

        ctx.windows
    }

    /// Resolve which monitor a window is on by comparing the `HMONITOR`
    /// returned by `MonitorFromWindow` against our pre-enumerated list.
    fn monitor_index_for_hwnd(
        hwnd: HWND,
        monitors: &[crate::monitor::MonitorInfo],
    ) -> Option<usize> {
        use windows::Win32::Graphics::Gdi::{MonitorFromWindow, MONITOR_DEFAULTTONEAREST};

        let hmon = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
        let handle = hmon.0 as isize;
        monitors.iter().find(|m| m.handle == handle).map(|m| m.index)
    }

    // -----------------------------------------------------------------------
    // is_real_window
    // -----------------------------------------------------------------------

    /// System processes whose windows should be excluded from thumbnailing.
    const SYSTEM_PROCESS_NAMES: &[&str] = &[
        "ApplicationFrameHost.exe",
        "SystemSettings.exe",
        "ShellExperienceHost.exe",
        "SearchHost.exe",
        "StartMenuExperienceHost.exe",
    ];

    pub fn is_real_window(info: &WindowInfo) -> bool {
        // Must be Normal or Dialog.
        match info.classification {
            WindowClassification::Normal | WindowClassification::Dialog => {}
            _ => return false,
        }

        // Must not be topmost.
        if info.window_level != 0 {
            return false;
        }

        // Reasonable minimum size.
        if info.frame.width < 100.0 || info.frame.height < 100.0 {
            return false;
        }

        // Skip common system processes.
        for name in SYSTEM_PROCESS_NAMES {
            if info.owner_name.eq_ignore_ascii_case(name) {
                return false;
            }
        }

        true
    }

    // -----------------------------------------------------------------------
    // Event hook
    // -----------------------------------------------------------------------

    // Global state for the event hook callback. SetWinEventHook requires a
    // plain `extern "system" fn` so we cannot capture a closure. We use a
    // global Mutex<Option<Sender>> instead.
    static EVENT_SENDER: Mutex<Option<Sender<WindowEvent>>> = Mutex::new(None);

    unsafe extern "system" fn win_event_proc(
        _hook: HWINEVENTHOOK,
        event: u32,
        hwnd: HWND,
        id_object: i32,
        _id_child: i32,
        _event_thread: u32,
        _event_time: u32,
    ) {
        // For CREATE/DESTROY we only care about the window itself, not child
        // objects.
        if event == EVENT_OBJECT_CREATE || event == EVENT_OBJECT_DESTROY {
            if id_object != OBJID_WINDOW.0 {
                return;
            }
        }

        let raw = hwnd.0 as isize;
        let evt = match event {
            e if e == EVENT_OBJECT_CREATE => WindowEvent::Created(raw),
            e if e == EVENT_OBJECT_DESTROY => WindowEvent::Destroyed(raw),
            e if e == EVENT_SYSTEM_FOREGROUND => WindowEvent::Focused(raw),
            e if e == EVENT_OBJECT_LOCATIONCHANGE => WindowEvent::Moved(raw),
            _ => return,
        };

        if let Ok(guard) = EVENT_SENDER.lock() {
            if let Some(sender) = guard.as_ref() {
                let _ = sender.send(evt);
            }
        }
    }

    pub struct HookHandles {
        hooks: Vec<HWINEVENTHOOK>,
    }

    impl HookHandles {
        pub fn unhook(self) {
            for h in self.hooks {
                unsafe {
                    let _ = UnhookWinEvent(h);
                }
            }
            // Clear the global sender.
            if let Ok(mut guard) = EVENT_SENDER.lock() {
                *guard = None;
            }
        }
    }

    pub fn start_event_hooks(sender: Sender<WindowEvent>) -> HookHandles {
        // Store the sender globally.
        if let Ok(mut guard) = EVENT_SENDER.lock() {
            *guard = Some(sender);
        }

        let flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;

        let events: &[(u32, u32)] = &[
            (EVENT_OBJECT_CREATE, EVENT_OBJECT_CREATE),
            (EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY),
            (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
            (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE),
        ];

        let mut hooks = Vec::new();
        for &(min_event, max_event) in events {
            let hook = unsafe {
                SetWinEventHook(min_event, max_event, None, Some(win_event_proc), 0, 0, flags)
            };
            if !hook.is_invalid() {
                hooks.push(hook);
            }
        }

        HookHandles { hooks }
    }

    // -----------------------------------------------------------------------
    // WindowTracker struct
    // -----------------------------------------------------------------------

    pub struct WindowTracker {
        hook_handles: Option<HookHandles>,
    }

    impl WindowTracker {
        pub fn new() -> Self {
            Self {
                hook_handles: None,
            }
        }

        /// Re-enumerate all windows and return the current snapshot.
        pub fn refresh(&self) -> Vec<WindowInfo> {
            enumerate_windows()
        }

        /// Start Win32 event hooks that deliver events to `sender`.
        pub fn start_hooks(&mut self, sender: Sender<WindowEvent>) {
            self.stop_hooks();
            self.hook_handles = Some(start_event_hooks(sender));
        }

        /// Unhook all active event hooks.
        pub fn stop_hooks(&mut self) {
            if let Some(handles) = self.hook_handles.take() {
                handles.unhook();
            }
        }
    }

    impl Drop for WindowTracker {
        fn drop(&mut self) {
            self.stop_hooks();
        }
    }
}

// ===========================================================================
// Non-Windows stubs
// ===========================================================================
#[cfg(not(windows))]
mod platform {
    use super::*;

    pub fn classify_window(_hwnd: isize) -> WindowClassification {
        WindowClassification::Unknown
    }

    pub fn enumerate_windows() -> Vec<WindowInfo> {
        Vec::new()
    }

    pub fn is_real_window(_info: &WindowInfo) -> bool {
        false
    }

    pub struct WindowTracker;

    impl WindowTracker {
        pub fn new() -> Self {
            Self
        }

        pub fn refresh(&self) -> Vec<WindowInfo> {
            Vec::new()
        }

        pub fn start_hooks(&mut self, _sender: std::sync::mpsc::Sender<WindowEvent>) {}

        pub fn stop_hooks(&mut self) {}
    }
}

// ===========================================================================
// Re-exports — public API surface
// ===========================================================================

pub use platform::{classify_window, enumerate_windows, is_real_window, WindowTracker};
