//! Global keyboard input handling for Glance Windows.
//!
//! Provides low-level keyboard hook support for:
//! - Alt double-tap detection (toggle hint mode)
//! - Hint mode key interception (letters, numbers, escape)
//! - Global hotkey detection (Ctrl+Alt+H)
//!
//! # Threading requirements
//!
//! `install_hooks()` must be called from a thread that runs a Win32 message
//! loop (`GetMessageW` / `DispatchMessageW`). The low-level keyboard hook
//! callback is invoked on the same thread that installed the hook, and
//! Windows requires that thread to pump messages for the hook to function.

use std::sync::mpsc::Sender;

/// Events emitted by the input system.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEvent {
    /// Alt key double-tapped (toggle hint mode).
    AltDoubleTap,
    /// A hint key was pressed while in hint mode (e.g., '1', 'A'). The second
    /// field is true when Shift was held at the time of the press — used to
    /// enter pill edit mode.
    HintKeyPressed(char, bool),
    /// Backspace pressed while in hint mode — clears the reservation of the
    /// pill currently being edited (no-op if not editing).
    HintBackspacePressed,
    /// Escape pressed while in hint mode (cancel).
    EscapePressed,
    /// Global hotkey triggered (Ctrl+Alt+H).
    ToggleHotkey,
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod platform {
    use super::{InputEvent, Sender};
    use std::sync::Mutex;
    use std::time::Instant;
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, VIRTUAL_KEY, VK_A, VK_BACK, VK_ESCAPE, VK_H, VK_LCONTROL, VK_LMENU,
        VK_LSHIFT, VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_Z, VK_0, VK_9,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, SetWindowsHookExW, UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT,
        WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    /// Wrapper around `HHOOK` that is `Send`-safe.
    ///
    /// `HHOOK` contains a raw `*mut c_void` which prevents it from being
    /// stored in a `Mutex` in a `static`. The hook handle is only ever
    /// accessed from the thread that installed it (or during `Drop`), and
    /// its value is an opaque system handle, so sending it across threads
    /// is safe in practice.
    struct SendHhook(HHOOK);
    // SAFETY: HHOOK is an opaque handle; Windows guarantees it can be used
    // from any thread for UnhookWindowsHookEx.
    unsafe impl Send for SendHhook {}

    /// Shared state accessible from the hook callback.
    struct HookState {
        sender: Sender<InputEvent>,
        hint_mode: bool,
        /// Timestamp of the last "clean" Alt press (no other key mixed in).
        last_alt_press: Option<Instant>,
        /// Timestamp of the last "clean" Alt release (tap completed).
        last_alt_tap: Option<Instant>,
        /// Whether any non-Alt key was pressed while Alt was held down.
        alt_contaminated: bool,
        /// Whether Alt is currently held down.
        alt_down: bool,
    }

    static HOOK_STATE: Mutex<Option<HookState>> = Mutex::new(None);
    static HOOK_HANDLE: Mutex<Option<SendHhook>> = Mutex::new(None);

    /// Maximum duration of an Alt press-release to count as a "tap".
    const ALT_TAP_MAX_MS: u128 = 200;
    /// Maximum gap between two taps to count as a "double-tap".
    const ALT_DOUBLE_TAP_MAX_MS: u128 = 400;

    pub struct InputManager;

    impl InputManager {
        pub fn new(sender: Sender<InputEvent>) -> Self {
            let mut state = HOOK_STATE.lock().unwrap();
            *state = Some(HookState {
                sender,
                hint_mode: false,
                last_alt_press: None,
                last_alt_tap: None,
                alt_contaminated: false,
                alt_down: false,
            });
            InputManager
        }

        pub fn set_hint_mode(&self, active: bool) {
            if let Ok(mut state) = HOOK_STATE.lock() {
                if let Some(ref mut s) = *state {
                    s.hint_mode = active;
                }
            }
        }

        /// Install a low-level keyboard hook.
        ///
        /// # Requirements
        ///
        /// This must be called from a thread that pumps a Win32 message loop
        /// (`GetMessageW` / `DispatchMessageW`). The hook callback will be
        /// invoked on the same thread.
        pub fn install_hooks(&self) -> Result<(), String> {
            let hook = unsafe {
                SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook_proc), None, 0)
            }
            .map_err(|e| format!("SetWindowsHookExW failed: {e}"))?;

            let mut handle = HOOK_HANDLE.lock().unwrap();
            *handle = Some(SendHhook(hook));
            log::info!("Low-level keyboard hook installed");
            Ok(())
        }

        pub fn uninstall_hooks(&self) {
            let mut handle = HOOK_HANDLE.lock().unwrap();
            if let Some(SendHhook(hook)) = handle.take() {
                unsafe {
                    let _ = UnhookWindowsHookEx(hook);
                }
                log::info!("Low-level keyboard hook uninstalled");
            }
        }
    }

    impl Drop for InputManager {
        fn drop(&mut self) {
            self.uninstall_hooks();
            let mut state = HOOK_STATE.lock().unwrap();
            *state = None;
        }
    }

    /// Returns true if the given virtual key is currently pressed.
    fn is_key_down(vk: VIRTUAL_KEY) -> bool {
        // GetAsyncKeyState returns a value with the high bit set if the key
        // is currently down.
        unsafe { GetAsyncKeyState(vk.0 as i32) < 0 }
    }

    /// Convert a virtual key code in the 0-9 or A-Z range to its character.
    fn vk_to_char(vk: u32) -> Option<char> {
        let vk0 = VK_0.0 as u32;
        let vk9 = VK_9.0 as u32;
        let vka = VK_A.0 as u32;
        let vkz = VK_Z.0 as u32;

        if (vk0..=vk9).contains(&vk) {
            Some((b'0' + (vk - vk0) as u8) as char)
        } else if (vka..=vkz).contains(&vk) {
            Some((b'A' + (vk - vka) as u8) as char)
        } else {
            None
        }
    }

    fn send_event(state: &HookState, event: InputEvent) {
        if let Err(e) = state.sender.send(event) {
            log::warn!("Failed to send input event: {e}");
        }
    }

    /// Low-level keyboard hook callback.
    ///
    /// # Safety
    ///
    /// Called by Windows; `lparam` must point to a valid `KBDLLHOOKSTRUCT`.
    unsafe extern "system" fn keyboard_hook_proc(
        code: i32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        // If code < 0, we must pass it along without processing.
        if code < 0 {
            return CallNextHookEx(None, code, wparam, lparam);
        }

        let kb = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let vk = kb.vkCode;
        let msg = wparam.0 as u32;

        let is_keydown = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        let is_keyup = msg == WM_KEYUP || msg == WM_SYSKEYUP;

        // We need to lock the state to process the event. If the lock is
        // poisoned we just pass through.
        let mut guard = match HOOK_STATE.lock() {
            Ok(g) => g,
            Err(_) => return CallNextHookEx(None, code, wparam, lparam),
        };
        let state = match guard.as_mut() {
            Some(s) => s,
            None => return CallNextHookEx(None, code, wparam, lparam),
        };

        let is_left_alt = vk == VK_LMENU.0 as u32;
        let is_right_alt = vk == VK_RMENU.0 as u32;
        let is_any_alt = is_left_alt || is_right_alt;

        // --- Alt double-tap detection ---
        if is_any_alt {
            if is_keydown && !state.alt_down {
                state.alt_down = true;
                state.alt_contaminated = false;
                state.last_alt_press = Some(Instant::now());
            } else if is_keyup && state.alt_down {
                state.alt_down = false;
                let now = Instant::now();

                // Was it a clean tap (pressed and released quickly, no other
                // key mixed in)?
                let is_clean_tap = !state.alt_contaminated
                    && state
                        .last_alt_press
                        .map(|t| now.duration_since(t).as_millis() <= ALT_TAP_MAX_MS)
                        .unwrap_or(false);

                if is_clean_tap {
                    // Check for double-tap: was there a previous tap within
                    // the double-tap window?
                    let is_double_tap = state
                        .last_alt_tap
                        .map(|t| now.duration_since(t).as_millis() <= ALT_DOUBLE_TAP_MAX_MS)
                        .unwrap_or(false);

                    if is_double_tap {
                        send_event(state, InputEvent::AltDoubleTap);
                        state.last_alt_tap = None; // Reset so triple-tap doesn't re-trigger.
                    } else {
                        state.last_alt_tap = Some(now);
                    }
                } else {
                    // Not a clean tap — reset.
                    state.last_alt_tap = None;
                }

                state.last_alt_press = None;
            }

            // Always pass Alt through — we never consume the Alt key itself.
            // Drop the lock before calling CallNextHookEx.
            drop(guard);
            return CallNextHookEx(None, code, wparam, lparam);
        }

        // Any non-Alt key while Alt is held contaminates the current Alt press.
        if state.alt_down {
            state.alt_contaminated = true;
        }

        // --- Only process key-down events for the rest ---
        if !is_keydown {
            drop(guard);
            return CallNextHookEx(None, code, wparam, lparam);
        }

        // --- Global hotkey: Ctrl+Alt+H ---
        let ctrl_down = is_key_down(VK_LCONTROL) || is_key_down(VK_RCONTROL);
        let alt_down = is_key_down(VK_LMENU) || is_key_down(VK_RMENU);

        if vk == VK_H.0 as u32 && ctrl_down && alt_down {
            send_event(state, InputEvent::ToggleHotkey);
            drop(guard);
            // Consume the key so it doesn't reach other apps.
            return LRESULT(1);
        }

        // --- Hint mode interception ---
        if state.hint_mode {
            if vk == VK_ESCAPE.0 as u32 {
                send_event(state, InputEvent::EscapePressed);
                drop(guard);
                return LRESULT(1); // Consume.
            }

            if vk == VK_BACK.0 as u32 {
                send_event(state, InputEvent::HintBackspacePressed);
                drop(guard);
                return LRESULT(1); // Consume.
            }

            if let Some(ch) = vk_to_char(vk) {
                let shift = is_key_down(VK_LSHIFT) || is_key_down(VK_RSHIFT);
                send_event(state, InputEvent::HintKeyPressed(ch, shift));
                drop(guard);
                return LRESULT(1); // Consume.
            }
        }

        // --- Pass through ---
        drop(guard);
        CallNextHookEx(None, code, wparam, lparam)
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stub
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
mod platform {
    use super::{InputEvent, Sender};

    pub struct InputManager {
        _sender: Sender<InputEvent>,
    }

    impl InputManager {
        pub fn new(sender: Sender<InputEvent>) -> Self {
            InputManager { _sender: sender }
        }

        pub fn set_hint_mode(&self, _active: bool) {
            // No-op on non-Windows.
        }

        pub fn install_hooks(&self) -> Result<(), String> {
            Err("Keyboard hooks are only supported on Windows".into())
        }

        pub fn uninstall_hooks(&self) {
            // No-op on non-Windows.
        }
    }
}

// Re-export the platform-specific type at module level.
pub use platform::InputManager;
