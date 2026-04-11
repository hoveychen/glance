// System tray icon and context menu for Glance on Windows.
//
// Equivalent of the macOS NSStatusBar/NSStatusItem. Creates a hidden window
// to receive Shell_NotifyIcon callbacks, shows a context menu on right-click,
// and toggles Glance on left-click.

use std::sync::mpsc::Sender;

/// Actions that can be triggered from the system tray.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayAction {
    /// Toggle Glance on/off.
    Toggle,
    /// Exit the application.
    Quit,
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod platform {
    use super::{Sender, TrayAction};
    use std::cell::RefCell;
    use std::mem;

    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        GetCursorPos, LoadIconW, PostMessageW, RegisterClassExW, SetForegroundWindow,
        TrackPopupMenu, UnregisterClassW, IDI_APPLICATION, MF_SEPARATOR, MF_STRING,
        TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RIGHTBUTTON, WINDOW_EX_STYLE, WM_COMMAND, WM_DESTROY,
        WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WM_USER, WNDCLASSEXW, WS_OVERLAPPED,
    };

    /// Custom callback message ID for tray icon notifications.
    const WM_TRAYICON: u32 = WM_USER + 1;

    /// Menu item IDs.
    const IDM_TOGGLE: usize = 1001;
    const IDM_QUIT: usize = 1002;

    /// Tray icon UID (arbitrary, unique within the process).
    const TRAY_UID: u32 = 1;

    /// Wide class name for the hidden window, null-terminated.
    const CLASS_NAME: &[u16] = &[
        b'G' as u16,
        b'l' as u16,
        b'a' as u16,
        b'n' as u16,
        b'c' as u16,
        b'e' as u16,
        b'T' as u16,
        b'r' as u16,
        b'a' as u16,
        b'y' as u16,
        b'W' as u16,
        b'i' as u16,
        b'n' as u16,
        b'd' as u16,
        b'o' as u16,
        b'w' as u16,
        0,
    ];

    thread_local! {
        static TRAY_SENDER: RefCell<Option<Sender<TrayAction>>> = const { RefCell::new(None) };
    }

    fn send_action(action: TrayAction) {
        TRAY_SENDER.with(|cell| {
            if let Some(ref sender) = *cell.borrow() {
                let _ = sender.send(action);
            }
        });
    }

    /// Encode a Rust string as a null-terminated UTF-16 array suitable for `szTip`.
    fn encode_tip(s: &str) -> [u16; 128] {
        let mut buf = [0u16; 128];
        for (i, c) in s.encode_utf16().take(127).enumerate() {
            buf[i] = c;
        }
        buf
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_TRAYICON => {
                let mouse_msg = (lparam.0 as u32) & 0xFFFF;
                match mouse_msg {
                    WM_LBUTTONUP => {
                        send_action(TrayAction::Toggle);
                    }
                    WM_RBUTTONUP => {
                        show_context_menu(hwnd);
                    }
                    _ => {}
                }
                LRESULT(0)
            }
            WM_COMMAND => {
                let id = (wparam.0 & 0xFFFF) as usize;
                match id {
                    IDM_TOGGLE => send_action(TrayAction::Toggle),
                    IDM_QUIT => send_action(TrayAction::Quit),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_DESTROY => {
                // Remove the tray icon on window destruction.
                let mut nid: NOTIFYICONDATAW = mem::zeroed();
                nid.cbSize = mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = hwnd;
                nid.uID = TRAY_UID;
                let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// Show the tray context menu at the current cursor position.
    unsafe fn show_context_menu(hwnd: HWND) {
        let hmenu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(_) => return,
        };

        // "Toggle Glance"
        let toggle_label: Vec<u16> = "Toggle Glance\0".encode_utf16().collect();
        let _ = AppendMenuW(
            hmenu,
            MF_STRING,
            IDM_TOGGLE,
            windows::core::PCWSTR(toggle_label.as_ptr()),
        );

        // Separator
        let _ = AppendMenuW(
            hmenu,
            MF_SEPARATOR,
            0,
            windows::core::PCWSTR::null(),
        );

        // "Quit"
        let quit_label: Vec<u16> = "Quit\0".encode_utf16().collect();
        let _ = AppendMenuW(
            hmenu,
            MF_STRING,
            IDM_QUIT,
            windows::core::PCWSTR(quit_label.as_ptr()),
        );

        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);

        // Required by Windows: SetForegroundWindow before TrackPopupMenu,
        // otherwise the menu won't dismiss when clicked outside.
        let _ = SetForegroundWindow(hwnd);

        let _ = TrackPopupMenu(
            hmenu,
            TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
            pt.x,
            pt.y,
            0,
            hwnd,
            None,
        );

        // Windows quirk: post WM_NULL to force the message loop to cycle,
        // ensuring the menu closes correctly.
        let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));

        let _ = DestroyMenu(hmenu);
    }

    pub struct TrayIcon {
        hwnd: HWND,
        #[allow(dead_code)]
        class_atom: u16,
    }

    impl TrayIcon {
        pub fn new(sender: Sender<TrayAction>) -> Result<Self, String> {
            // Store the sender in thread-local storage for the window proc.
            TRAY_SENDER.with(|cell| {
                *cell.borrow_mut() = Some(sender);
            });

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
                    return Err("RegisterClassExW failed".to_string());
                }

                // Create a regular hidden window (0-size, not visible).
                // HWND_MESSAGE windows may not receive tray messages on all
                // Windows versions, so we use a normal off-screen window.
                let hwnd = CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    windows::core::PCWSTR(CLASS_NAME.as_ptr()),
                    windows::core::PCWSTR::null(),
                    WS_OVERLAPPED,
                    0,
                    0,
                    0,
                    0,
                    None,  // no parent
                    None,  // no menu
                    hinstance,
                    None,
                )
                .map_err(|e| format!("CreateWindowExW failed: {e}"))?;

                // Load a placeholder icon (built-in IDI_APPLICATION).
                let hicon = LoadIconW(None, IDI_APPLICATION)
                    .map_err(|e| format!("LoadIconW failed: {e}"))?;

                // Set up NOTIFYICONDATAW.
                let mut nid: NOTIFYICONDATAW = mem::zeroed();
                nid.cbSize = mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = hwnd;
                nid.uID = TRAY_UID;
                nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
                nid.uCallbackMessage = WM_TRAYICON;
                nid.hIcon = hicon;
                nid.szTip = encode_tip("Glance");

                let ok = Shell_NotifyIconW(NIM_ADD, &nid);
                if !ok.as_bool() {
                    let _ = DestroyWindow(hwnd);
                    return Err("Shell_NotifyIconW(NIM_ADD) failed".to_string());
                }

                log::info!("System tray icon created");

                Ok(TrayIcon { hwnd, class_atom })
            }
        }
    }

    impl Drop for TrayIcon {
        fn drop(&mut self) {
            unsafe {
                // Remove the tray icon.
                let mut nid: NOTIFYICONDATAW = mem::zeroed();
                nid.cbSize = mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = self.hwnd;
                nid.uID = TRAY_UID;
                let _ = Shell_NotifyIconW(NIM_DELETE, &nid);

                // Destroy the hidden window.
                let _ = DestroyWindow(self.hwnd);

                // Unregister the window class.
                if let Ok(hinstance) = GetModuleHandleW(None) {
                    let _ = UnregisterClassW(
                        windows::core::PCWSTR(CLASS_NAME.as_ptr()),
                        hinstance,
                    );
                }
            }

            // Clear the thread-local sender.
            TRAY_SENDER.with(|cell| {
                *cell.borrow_mut() = None;
            });

            log::info!("System tray icon removed");
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stub
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
mod platform {
    use super::{Sender, TrayAction};

    pub struct TrayIcon;

    impl TrayIcon {
        pub fn new(_sender: Sender<TrayAction>) -> Result<Self, String> {
            Err("System tray is only supported on Windows".to_string())
        }
    }
}

// Re-export the platform-specific implementation.
pub use platform::TrayIcon;
