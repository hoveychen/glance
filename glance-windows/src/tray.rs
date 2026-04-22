// System tray icon and context menu for Glance on Windows.
//
// Equivalent of the macOS NSStatusBar/NSStatusItem. Creates a hidden window
// to receive Shell_NotifyIcon callbacks, shows a context menu on right-click,
// and toggles Glance on left-click.

use std::sync::mpsc::Sender;

use crate::config::{hotkey_mods, ActivationHotkey, HintTriggerKind};
use crate::swap_resize::SwapResizeMode;

/// Actions that can be triggered from the system tray.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrayAction {
    /// Toggle Glance on/off.
    Toggle,
    /// Change the swap-into-work-area resize policy.
    SetSwapResizeMode(SwapResizeMode),
    /// Enable / disable the recency glow on thumbnails.
    SetMruGlowEnabled(bool),
    /// Replace the global activation hotkey.
    SetActivationHotkey(ActivationHotkey),
    /// Change which modifier key's double-tap opens hint mode.
    SetHintTrigger(HintTriggerKind),
    /// Exit the application.
    Quit,
}

/// A named activation-hotkey combo shown in the tray submenu. Keeping the
/// set small and hand-picked gives users a one-click UI without having to
/// hand-edit config.json; the JSON escape hatch remains for power users.
struct HotkeyPreset {
    /// English label shown in the menu (modifier combos are universal).
    label: &'static str,
    hotkey: ActivationHotkey,
}

/// Returns the hard-coded list of hotkey presets offered in the tray menu.
/// The first entry is treated as the "default" for reset purposes and must
/// match `ActivationHotkey::default()`.
fn hotkey_presets() -> [HotkeyPreset; 6] {
    [
        HotkeyPreset {
            label: "Ctrl+Alt+H (Default)",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::CTRL | hotkey_mods::ALT, vk: 0x48 },
        },
        HotkeyPreset {
            label: "Ctrl+Shift+H",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::CTRL | hotkey_mods::SHIFT, vk: 0x48 },
        },
        HotkeyPreset {
            label: "Ctrl+Alt+G",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::CTRL | hotkey_mods::ALT, vk: 0x47 },
        },
        HotkeyPreset {
            label: "Ctrl+Alt+Space",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::CTRL | hotkey_mods::ALT, vk: 0x20 },
        },
        HotkeyPreset {
            label: "Ctrl+Shift+Space",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::CTRL | hotkey_mods::SHIFT, vk: 0x20 },
        },
        HotkeyPreset {
            label: "Win+Alt+H",
            hotkey: ActivationHotkey { modifiers: hotkey_mods::WIN | hotkey_mods::ALT, vk: 0x48 },
        },
    ]
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod platform {
    use super::{hotkey_presets, HintTriggerKind, Sender, SwapResizeMode, TrayAction};
    use std::cell::RefCell;
    use std::mem;

    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        GetCursorPos, LoadImageW, PostMessageW, RegisterClassExW, SetForegroundWindow,
        TrackPopupMenu, UnregisterClassW, IMAGE_ICON, LR_DEFAULTSIZE, MF_CHECKED, MF_POPUP,
        MF_SEPARATOR, MF_STRING, MF_UNCHECKED, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RIGHTBUTTON,
        WINDOW_EX_STYLE, WM_COMMAND, WM_DESTROY, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WM_USER,
        WNDCLASSEXW, WS_OVERLAPPED,
    };
    use windows::Win32::UI::WindowsAndMessaging::HICON;

    /// Custom callback message ID for tray icon notifications.
    const WM_TRAYICON: u32 = WM_USER + 1;

    /// Menu item IDs.
    const IDM_TOGGLE: usize = 1001;
    const IDM_QUIT: usize = 1002;
    const IDM_RESIZE_PRESERVE: usize = 1010;
    const IDM_RESIZE_CLAMP: usize = 1011;
    const IDM_MRU_GLOW_TOGGLE: usize = 1020;
    /// Base for hotkey preset items. Offset = preset index in `hotkey_presets()`.
    const IDM_HOTKEY_BASE: usize = 1030;
    /// Base IDs for the hint-trigger submenu entries. Offsets 0..4 correspond
    /// to Alt / Ctrl / Shift / Win.
    const IDM_HINT_TRIGGER_BASE: usize = 1040;

    /// The four hint-trigger kinds, in display order.
    const HINT_TRIGGERS: [HintTriggerKind; 4] = [
        HintTriggerKind::Alt,
        HintTriggerKind::Ctrl,
        HintTriggerKind::Shift,
        HintTriggerKind::Win,
    ];

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
                    IDM_RESIZE_PRESERVE => send_action(
                        TrayAction::SetSwapResizeMode(SwapResizeMode::PreserveAspectRatio)
                    ),
                    IDM_RESIZE_CLAMP => send_action(
                        TrayAction::SetSwapResizeMode(SwapResizeMode::ClampMax)
                    ),
                    IDM_MRU_GLOW_TOGGLE => {
                        let current = crate::config::load().mru_glow_enabled;
                        send_action(TrayAction::SetMruGlowEnabled(!current));
                    }
                    other => {
                        let presets = hotkey_presets();
                        if other >= IDM_HOTKEY_BASE
                            && other < IDM_HOTKEY_BASE + presets.len()
                        {
                            let idx = other - IDM_HOTKEY_BASE;
                            send_action(TrayAction::SetActivationHotkey(
                                presets[idx].hotkey.clone(),
                            ));
                        } else if other >= IDM_HINT_TRIGGER_BASE
                            && other < IDM_HINT_TRIGGER_BASE + HINT_TRIGGERS.len()
                        {
                            let idx = other - IDM_HINT_TRIGGER_BASE;
                            send_action(TrayAction::SetHintTrigger(HINT_TRIGGERS[idx]));
                        }
                    }
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
        let toggle_label: Vec<u16> = format!("{}\0", crate::strings::t("tray.toggle"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            hmenu,
            MF_STRING,
            IDM_TOGGLE,
            windows::core::PCWSTR(toggle_label.as_ptr()),
        );

        // "Resize Mode" submenu
        let resize_submenu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(_) => {
                let _ = DestroyMenu(hmenu);
                return;
            }
        };
        let current = crate::config::load().swap_resize_mode;
        let preserve_flag = if current == SwapResizeMode::PreserveAspectRatio { MF_CHECKED } else { MF_UNCHECKED };
        let clamp_flag    = if current == SwapResizeMode::ClampMax            { MF_CHECKED } else { MF_UNCHECKED };
        let preserve_label: Vec<u16> = format!("{}\0", crate::strings::t("tray.resize.preserve"))
            .encode_utf16()
            .collect();
        let clamp_label: Vec<u16> = format!("{}\0", crate::strings::t("tray.resize.clamp"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            resize_submenu,
            MF_STRING | preserve_flag,
            IDM_RESIZE_PRESERVE,
            windows::core::PCWSTR(preserve_label.as_ptr()),
        );
        let _ = AppendMenuW(
            resize_submenu,
            MF_STRING | clamp_flag,
            IDM_RESIZE_CLAMP,
            windows::core::PCWSTR(clamp_label.as_ptr()),
        );
        let resize_title: Vec<u16> = format!("{}\0", crate::strings::t("tray.resize_mode"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            hmenu,
            MF_POPUP,
            resize_submenu.0 as usize,
            windows::core::PCWSTR(resize_title.as_ptr()),
        );

        // "Hotkey" submenu — preset combos the user can pick with one click.
        let hotkey_submenu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(_) => {
                let _ = DestroyMenu(hmenu);
                return;
            }
        };
        let current_hotkey = crate::config::load().activation_hotkey;
        let presets = hotkey_presets();
        // Keep label buffers alive until TrackPopupMenu returns — PCWSTR holds
        // a raw pointer into the buffer and Windows reads the text lazily.
        let mut hotkey_label_buffers: Vec<Vec<u16>> = Vec::with_capacity(presets.len());
        for preset in presets.iter() {
            let buf: Vec<u16> = format!("{}\0", preset.label).encode_utf16().collect();
            hotkey_label_buffers.push(buf);
        }
        for (idx, preset) in presets.iter().enumerate() {
            let flag = if preset.hotkey == current_hotkey { MF_CHECKED } else { MF_UNCHECKED };
            let _ = AppendMenuW(
                hotkey_submenu,
                MF_STRING | flag,
                IDM_HOTKEY_BASE + idx,
                windows::core::PCWSTR(hotkey_label_buffers[idx].as_ptr()),
            );
        }
        let hotkey_title: Vec<u16> = format!("{}\0", crate::strings::t("tray.hotkey"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            hmenu,
            MF_POPUP,
            hotkey_submenu.0 as usize,
            windows::core::PCWSTR(hotkey_title.as_ptr()),
        );

        // "Hint Trigger" submenu — which modifier key's double-tap opens hint
        // mode. Applies only while Glance is active. Win is offered but will
        // clash with the Windows Start menu.
        let hint_trigger_submenu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(_) => {
                let _ = DestroyMenu(hmenu);
                return;
            }
        };
        let current_trigger = crate::config::load().hint_trigger;
        let trigger_keys = [
            "tray.hint_trigger.alt",
            "tray.hint_trigger.ctrl",
            "tray.hint_trigger.shift",
            "tray.hint_trigger.win",
        ];
        let mut trigger_label_buffers: Vec<Vec<u16>> = Vec::with_capacity(HINT_TRIGGERS.len());
        for key in trigger_keys.iter() {
            let buf: Vec<u16> = format!("{}\0", crate::strings::t(key)).encode_utf16().collect();
            trigger_label_buffers.push(buf);
        }
        for (idx, kind) in HINT_TRIGGERS.iter().enumerate() {
            let flag = if *kind == current_trigger { MF_CHECKED } else { MF_UNCHECKED };
            let _ = AppendMenuW(
                hint_trigger_submenu,
                MF_STRING | flag,
                IDM_HINT_TRIGGER_BASE + idx,
                windows::core::PCWSTR(trigger_label_buffers[idx].as_ptr()),
            );
        }
        let hint_trigger_title: Vec<u16> = format!("{}\0", crate::strings::t("tray.hint_trigger"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            hmenu,
            MF_POPUP,
            hint_trigger_submenu.0 as usize,
            windows::core::PCWSTR(hint_trigger_title.as_ptr()),
        );

        // "Highlight recent thumbnails" checkbox
        let mru_flag = if crate::config::load().mru_glow_enabled {
            MF_CHECKED
        } else {
            MF_UNCHECKED
        };
        let mru_label: Vec<u16> = format!("{}\0", crate::strings::t("tray.mru_glow"))
            .encode_utf16()
            .collect();
        let _ = AppendMenuW(
            hmenu,
            MF_STRING | mru_flag,
            IDM_MRU_GLOW_TOGGLE,
            windows::core::PCWSTR(mru_label.as_ptr()),
        );

        // Separator
        let _ = AppendMenuW(
            hmenu,
            MF_SEPARATOR,
            0,
            windows::core::PCWSTR::null(),
        );

        // "Quit"
        let quit_label: Vec<u16> = format!("{}\0", crate::strings::t("tray.quit"))
            .encode_utf16()
            .collect();
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

                // Load the app icon embedded in the exe resource.
                let hicon = HICON(
                    LoadImageW(
                        hinstance,
                        windows::core::PCWSTR(1 as *const u16), // resource ID 1 (set by winres)
                        IMAGE_ICON,
                        0,
                        0,
                        LR_DEFAULTSIZE,
                    )
                    .map_err(|e| format!("LoadImageW failed: {e}"))?
                    .0,
                );

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
