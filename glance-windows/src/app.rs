//! Main orchestrator for Glance Windows.
//!
//! Ties all modules together into a single event loop: tray icon, keyboard
//! input, window tracking, layout engine, DWM thumbnails, overlay windows,
//! and the frosted-glass work area.

use crate::input::{InputEvent, InputManager};
use crate::layout::MissionControlLayoutEngine;
use crate::monitor::MonitorManager;
use crate::overlay::{OverlayEvent, OverlayManager, PinSide};
use crate::thumbnail_manager::ThumbnailManager;
use crate::tray::{TrayAction, TrayIcon};
use crate::types::{Rect, WindowMetrics};
use crate::virtual_desktop::ParkingManager;
use crate::window_manager::WindowManager;
use crate::window_tracker::{WindowEvent, WindowTracker};
use crate::work_area::{WorkAreaEvent, WorkAreaWindow};

use std::collections::{HashMap, HashSet};
use std::sync::mpsc;

// ---------------------------------------------------------------------------
// AppEvent — unified event enum
// ---------------------------------------------------------------------------

/// All modules funnel their events through this enum into a single channel.
pub enum AppEvent {
    /// From tray icon.
    Tray(TrayAction),
    /// From overlay windows.
    Overlay(OverlayEvent),
    /// From work area window.
    WorkArea(WorkAreaEvent),
    /// From keyboard input hooks.
    Input(InputEvent),
    /// From window event hooks.
    Window(WindowEvent),
    /// Periodic refresh tick (1 s).
    Tick,
}

// ---------------------------------------------------------------------------
// Hint key generation
// ---------------------------------------------------------------------------

/// Hint keys: 1-9 first, then A-Z.
fn generate_hint_keys() -> Vec<String> {
    let mut keys = Vec::new();
    for c in '1'..='9' {
        keys.push(c.to_string());
    }
    for c in 'A'..='Z' {
        keys.push(c.to_string());
    }
    keys
}

// ---------------------------------------------------------------------------
// GlanceApp
// ---------------------------------------------------------------------------

pub struct GlanceApp {
    // Modules (tray must be held alive for the icon to persist)
    #[allow(dead_code)]
    tray: Option<TrayIcon>,
    window_tracker: WindowTracker,
    window_manager: WindowManager,
    monitor_manager: MonitorManager,
    layout_engine: MissionControlLayoutEngine,
    overlay_manager: Option<OverlayManager>,
    thumbnail_manager: ThumbnailManager,
    parking_manager: Option<ParkingManager>,
    input_manager: Option<InputManager>,
    work_area: Option<WorkAreaWindow>,

    // State
    is_active: bool,
    current_main_hwnd: Option<isize>,
    current_main_pid: Option<u32>,
    parked_windows: HashSet<isize>,
    known_window_ids: HashSet<isize>,
    window_order: Vec<isize>,
    main_window_stack: Vec<isize>,
    /// MRU list of recently-interacted thumbnail windows (newest at front).
    /// Drives the recency glow. Capacity-based: a 4th interaction drops the
    /// oldest; time does not evict.
    mru_hwnds: std::collections::VecDeque<isize>,
    work_area_positions: HashMap<isize, Rect>,
    manual_screen_assignment: HashSet<isize>,

    // Hint mode
    is_hint_mode: bool,
    hint_mapping: HashMap<String, isize>,
    /// Hint-pill edit mode: the hwnd whose reserved key the user is currently
    /// renaming (via Shift+<key>). `None` outside edit mode. While editing,
    /// the next alpha/digit key commits; Backspace clears; Esc cancels.
    hint_editing_hwnd: Option<isize>,
    /// The key that was displayed on the pill when edit mode was entered —
    /// used to restore the pill on Esc-cancel.
    hint_editing_original_key: Option<String>,

    // Pinned reference (left side)
    pinned_left_hwnd: Option<isize>,
    pinned_left_pid: Option<u32>,
    // Pinned reference (right side)
    pinned_right_hwnd: Option<isize>,
    pinned_right_pid: Option<u32>,

    // Event channel
    event_rx: mpsc::Receiver<AppEvent>,
    event_tx: mpsc::Sender<AppEvent>,
}

impl GlanceApp {
    /// Create a new Glance application instance.
    ///
    /// Initializes all sub-modules, creates the tray icon and input hooks,
    /// but does **not** activate the layout yet (starts in inactive state).
    pub fn new() -> Self {
        let (event_tx, event_rx) = mpsc::channel();

        // Window tracker
        let mut window_tracker = WindowTracker::new();
        let wt_tx = event_tx.clone();
        window_tracker.start_hooks(std::sync::mpsc::Sender::from({
            // We need a Sender<WindowEvent> but our channel is Sender<AppEvent>.
            // Bridge via a dedicated channel + forwarding thread.
            let (wtx, wrx) = mpsc::channel::<WindowEvent>();
            let fwd_tx = wt_tx;
            std::thread::spawn(move || {
                while let Ok(evt) = wrx.recv() {
                    if fwd_tx.send(AppEvent::Window(evt)).is_err() {
                        break;
                    }
                }
            });
            wtx
        }));

        // Input manager — bridge InputEvent to AppEvent
        let (input_tx, input_rx) = mpsc::channel::<InputEvent>();
        let input_fwd_tx = event_tx.clone();
        std::thread::spawn(move || {
            while let Ok(evt) = input_rx.recv() {
                if input_fwd_tx.send(AppEvent::Input(evt)).is_err() {
                    break;
                }
            }
        });
        let input_manager = InputManager::new(input_tx);
        if let Err(e) = input_manager.install_hooks() {
            log::warn!("Failed to install keyboard hooks: {e}");
        }

        // Tray icon — bridge TrayAction to AppEvent
        let (tray_tx, tray_rx) = mpsc::channel::<TrayAction>();
        let tray_fwd_tx = event_tx.clone();
        std::thread::spawn(move || {
            while let Ok(evt) = tray_rx.recv() {
                if tray_fwd_tx.send(AppEvent::Tray(evt)).is_err() {
                    break;
                }
            }
        });
        let tray = match TrayIcon::new(tray_tx) {
            Ok(t) => Some(t),
            Err(e) => {
                log::error!("Failed to create tray icon: {e}");
                None
            }
        };

        GlanceApp {
            tray,
            window_tracker,
            window_manager: WindowManager::new(),
            monitor_manager: MonitorManager::new(),
            layout_engine: MissionControlLayoutEngine::default(),
            overlay_manager: None,
            thumbnail_manager: ThumbnailManager::new(),
            parking_manager: None,
            input_manager: Some(input_manager),
            work_area: None,

            is_active: false,
            current_main_hwnd: None,
            current_main_pid: None,
            parked_windows: HashSet::new(),
            known_window_ids: HashSet::new(),
            window_order: Vec::new(),
            main_window_stack: Vec::new(),
            mru_hwnds: std::collections::VecDeque::new(),
            work_area_positions: HashMap::new(),
            manual_screen_assignment: HashSet::new(),

            is_hint_mode: false,
            hint_mapping: HashMap::new(),
            hint_editing_hwnd: None,
            hint_editing_original_key: None,

            pinned_left_hwnd: None,
            pinned_left_pid: None,
            pinned_right_hwnd: None,
            pinned_right_pid: None,

            event_rx,
            event_tx,
        }
    }

    // -----------------------------------------------------------------------
    // Main event loop
    // -----------------------------------------------------------------------

    /// Run the main event loop with a Win32 message pump.
    #[cfg(windows)]
    pub fn run(&mut self) {
        use windows::Win32::UI::WindowsAndMessaging::{
            DispatchMessageW, PeekMessageW, TranslateMessage, MSG, PM_REMOVE, WM_QUIT, WM_TIMER,
        };

        log::info!("Glance app running");

        // Match macOS behaviour: activate immediately on launch. macOS gates
        // activation behind the onboarding flow, but onboarding completion
        // (first-run or not) always calls activate(). Windows has no
        // onboarding, so call activate() directly.
        self.activate();

        // Set up a 1-second timer for periodic refresh ticks.
        let timer_id = unsafe {
            windows::Win32::UI::WindowsAndMessaging::SetTimer(None, 0, 1000, None)
        };

        let tick_tx = self.event_tx.clone();

        let mut msg = MSG::default();
        loop {
            // Process all pending Win32 messages.
            unsafe {
                while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).into() {
                    if msg.message == WM_QUIT {
                        log::info!("WM_QUIT received, exiting event loop");
                        if timer_id != 0 {
                            let _ = windows::Win32::UI::WindowsAndMessaging::KillTimer(
                                None,
                                timer_id,
                            );
                        }
                        return;
                    }
                    if msg.message == WM_TIMER {
                        let _ = tick_tx.send(AppEvent::Tick);
                    }
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }

            // Process our app events (non-blocking).
            while let Ok(event) = self.event_rx.try_recv() {
                self.handle_event(event);
            }

            // Sleep briefly to avoid busy-waiting.
            unsafe {
                windows::Win32::System::Threading::Sleep(1);
            }
        }
    }

    /// Stub for non-Windows platforms.
    #[cfg(not(windows))]
    pub fn run(&mut self) {
        log::info!("Glance Windows only runs on Windows. Exiting.");
    }

    // -----------------------------------------------------------------------
    // Event dispatch
    // -----------------------------------------------------------------------

    fn handle_event(&mut self, event: AppEvent) {
        match event {
            AppEvent::Tray(TrayAction::Toggle) => {
                self.toggle_active();
            }
            AppEvent::Tray(TrayAction::Quit) => {
                self.deactivate();
                #[cfg(windows)]
                unsafe {
                    windows::Win32::UI::WindowsAndMessaging::PostQuitMessage(0);
                }
            }
            AppEvent::Tray(TrayAction::SetSwapResizeMode(mode)) => {
                crate::config::update(|c| {
                    c.swap_resize_mode = mode;
                });
                if self.is_active {
                    self.refresh_layout();
                }
            }
            AppEvent::Tray(TrayAction::SetMruGlowEnabled(enabled)) => {
                crate::config::update(|c| {
                    c.mru_glow_enabled = enabled;
                });
                if self.is_active {
                    self.refresh_mru_highlights();
                }
            }
            AppEvent::Tray(TrayAction::SetActivationHotkey(hk)) => {
                log::info!(
                    "Activation hotkey changed via tray: mods=0x{:x} vk=0x{:x}",
                    hk.modifiers,
                    hk.vk
                );
                crate::config::update(|c| {
                    c.activation_hotkey = hk;
                });
                // No extra wiring needed — input.rs reads the cached config
                // on every keydown, so the new combo fires immediately.
            }
            AppEvent::Tray(TrayAction::SetHintTrigger(kind)) => {
                log::info!("Hint trigger changed via tray: {:?}", kind);
                crate::config::update(|c| {
                    c.hint_trigger = kind;
                });
                // input.rs re-reads the cached config on every keystroke, so
                // the new trigger key is picked up on the next key event.
            }
            AppEvent::Input(InputEvent::ToggleHotkey) => {
                self.toggle_active();
            }
            AppEvent::Input(InputEvent::AltDoubleTap) => {
                if self.is_active {
                    self.toggle_hint_mode();
                }
            }
            AppEvent::Input(InputEvent::HintKeyPressed(ch, shift)) => {
                self.handle_hint_key(ch, shift);
            }
            AppEvent::Input(InputEvent::HintBackspacePressed) => {
                self.handle_hint_backspace();
            }
            AppEvent::Input(InputEvent::EscapePressed) => {
                self.handle_hint_escape();
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailClicked(hwnd)) => {
                self.handle_thumbnail_click(hwnd);
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailHoverStart(hwnd)) => {
                if self.is_active {
                    if let Some(ref mut overlay) = self.overlay_manager {
                        overlay.set_hovered(hwnd);
                    }
                }
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailHoverEnd(hwnd)) => {
                if self.is_active {
                    if let Some(ref mut overlay) = self.overlay_manager {
                        overlay.clear_hover(hwnd);
                    }
                }
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailDragStarted(_)) => {
                // Drag tracking is handled per-overlay in the wndproc.
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailDragMoved(_, _, _)) => {
                // Visual feedback during drag is handled by the overlay wndproc.
            }
            AppEvent::Overlay(OverlayEvent::ThumbnailDragCompleted(hwnd)) => {
                self.handle_drag_reorder(hwnd);
            }
            AppEvent::Overlay(OverlayEvent::SpringLoadActivated(hwnd)) => {
                if self.is_active {
                    self.handle_thumbnail_click(hwnd);
                }
            }
            AppEvent::Overlay(OverlayEvent::PinClicked(hwnd, side)) => {
                let ref_side = match side {
                    PinSide::Left => ReferenceSide::Left,
                    PinSide::Right => ReferenceSide::Right,
                };
                self.pin_as_reference(hwnd, ref_side);
            }
            AppEvent::Overlay(OverlayEvent::HintPillClicked(hwnd)) => {
                self.handle_hint_pill_clicked(hwnd);
            }
            AppEvent::WorkArea(WorkAreaEvent::ExitClicked) => {
                self.deactivate();
            }
            AppEvent::WorkArea(WorkAreaEvent::SwitchClicked) => {
                if self.is_active {
                    self.toggle_hint_mode();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::UnpinLeftClicked) => {
                self.unpin_reference(ReferenceSide::Left);
            }
            AppEvent::WorkArea(WorkAreaEvent::UnpinRightClicked) => {
                self.unpin_reference(ReferenceSide::Right);
            }
            AppEvent::WorkArea(WorkAreaEvent::Resized(r))
            | AppEvent::WorkArea(WorkAreaEvent::Moved(r)) => {
                if self.is_active {
                    crate::config::update(|c| {
                        c.work_area_frame = Some((r.x, r.y, r.width, r.height));
                    });
                    self.refresh_layout();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::LeftSplitRatioChanged(r)) => {
                if self.is_active {
                    crate::config::update(|c| c.left_split_ratio = r);
                    self.refresh_layout();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::RightSplitRatioChanged(r)) => {
                if self.is_active {
                    crate::config::update(|c| c.right_split_ratio = r);
                    self.refresh_layout();
                }
            }
            AppEvent::Window(WindowEvent::Created(_)) => {
                if self.is_active {
                    self.refresh_layout();
                }
            }
            AppEvent::Window(WindowEvent::Destroyed(hwnd)) => {
                if self.is_active {
                    self.handle_window_destroyed(hwnd);
                    self.refresh_layout();
                }
            }
            AppEvent::Window(WindowEvent::Focused(hwnd)) => {
                if self.is_active {
                    self.handle_window_focused(hwnd);
                }
            }
            AppEvent::Window(WindowEvent::Moved(_)) => {
                // We handle window moves during periodic refresh.
            }
            AppEvent::Tick => {
                if self.is_active {
                    self.refresh_layout();
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Activate / deactivate
    // -----------------------------------------------------------------------

    fn toggle_active(&mut self) {
        if self.is_active {
            self.deactivate();
        } else {
            self.activate();
        }
    }

    fn activate(&mut self) {
        if self.is_active {
            return;
        }
        self.is_active = true;
        log::info!("Glance activating");

        // Create parking manager.
        self.parking_manager = ParkingManager::new().ok();

        // Load persisted config.
        let cfg = crate::config::load();

        // Determine work area dimensions: prefer saved frame; otherwise
        // 55% width x 60% height of primary, centered.
        self.monitor_manager.refresh();
        let primary = self.monitor_manager.primary().cloned();
        let work_frame = if let Some((x, y, w, h)) = cfg.work_area_frame {
            Rect::new(x, y, w, h)
        } else if let Some(ref mon) = primary {
            let w = mon.work_area.width * 0.55;
            let h = mon.work_area.height * 0.60;
            let x = mon.work_area.x + (mon.work_area.width - w) / 2.0;
            let y = mon.work_area.y + (mon.work_area.height - h) / 2.0;
            Rect::new(x, y, w, h)
        } else {
            Rect::new(200.0, 100.0, 1056.0, 648.0)
        };

        // Create work area window.
        let wa_tx = self.event_tx.clone();
        let (wa_sender, wa_rx) = mpsc::channel::<WorkAreaEvent>();
        std::thread::spawn(move || {
            while let Ok(evt) = wa_rx.recv() {
                if wa_tx.send(AppEvent::WorkArea(evt)).is_err() {
                    break;
                }
            }
        });
        match WorkAreaWindow::new(&work_frame, wa_sender) {
            Ok(mut wa) => {
                wa.set_left_split_ratio(cfg.left_split_ratio);
                wa.set_right_split_ratio(cfg.right_split_ratio);
                wa.show();
                self.work_area = Some(wa);
            }
            Err(e) => {
                log::error!("Failed to create work area window: {e}");
            }
        }

        // Create overlay manager.
        let ov_tx = self.event_tx.clone();
        let (ov_sender, ov_rx) = mpsc::channel::<OverlayEvent>();
        std::thread::spawn(move || {
            while let Ok(evt) = ov_rx.recv() {
                if ov_tx.send(AppEvent::Overlay(evt)).is_err() {
                    break;
                }
            }
        });
        self.overlay_manager = Some(OverlayManager::new(ov_sender));

        // Pick the current foreground window as the initial main window.
        if let Some(fg) = self.window_manager.get_foreground_window() {
            // Make sure it is not our own work area.
            let wa_hwnd = self.work_area.as_ref().map(|w| w.hwnd());
            if Some(fg) != wa_hwnd {
                self.current_main_hwnd = Some(fg);
                // Try to get PID.
                let windows = self.window_tracker.refresh();
                if let Some(info) = windows.iter().find(|w| w.hwnd == fg) {
                    self.current_main_pid = Some(info.owner_pid);
                }
            }
        }

        // Initial layout.
        self.refresh_layout();
        log::info!("Glance activated");
    }

    fn deactivate(&mut self) {
        if !self.is_active {
            return;
        }
        log::info!("Glance deactivating");

        self.is_active = false;
        self.is_hint_mode = false;
        if let Some(ref input) = self.input_manager {
            input.set_hint_mode(false);
        }

        // Unpark all windows.
        if let Some(ref mut parking) = self.parking_manager {
            let parked: Vec<isize> = parking.parked_windows().iter().copied().collect();
            for hwnd in parked {
                parking.unpark_window(hwnd);
            }
        }

        // Unregister all DWM thumbnails.
        self.thumbnail_manager.unregister_all();

        // Destroy overlays.
        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.destroy_all();
        }
        self.overlay_manager = None;

        // Destroy work area.
        if let Some(ref mut wa) = self.work_area {
            wa.destroy();
        }
        self.work_area = None;

        // Clear state.
        self.parking_manager = None;
        self.current_main_hwnd = None;
        self.current_main_pid = None;
        self.parked_windows.clear();
        self.known_window_ids.clear();
        self.window_order.clear();
        self.main_window_stack.clear();
        self.mru_hwnds.clear();
        self.work_area_positions.clear();
        self.manual_screen_assignment.clear();
        self.hint_mapping.clear();
        self.pinned_left_hwnd = None;
        self.pinned_left_pid = None;
        self.pinned_right_hwnd = None;
        self.pinned_right_pid = None;

        log::info!("Glance deactivated");
    }

    // -----------------------------------------------------------------------
    // Layout refresh
    // -----------------------------------------------------------------------

    fn refresh_layout(&mut self) {
        if !self.is_active {
            return;
        }

        let wa_hwnd = self.work_area.as_ref().map(|w| w.hwnd()).unwrap_or(0);

        // Re-enumerate windows.
        let all_windows = self.window_tracker.refresh();

        // Filter to real windows, excluding our own work area and overlay windows.
        let real_windows: Vec<_> = all_windows
            .iter()
            .filter(|w| {
                crate::window_tracker::is_real_window(w)
                    && w.hwnd != wa_hwnd
                    && !self.is_our_overlay(w.hwnd)
            })
            .cloned()
            .collect();

        // Update known window set — detect disappeared windows.
        let current_ids: HashSet<isize> = real_windows.iter().map(|w| w.hwnd).collect();
        let disappeared: Vec<isize> = self
            .known_window_ids
            .difference(&current_ids)
            .copied()
            .collect();
        for hwnd in &disappeared {
            self.parked_windows.remove(hwnd);
            self.main_window_stack.retain(|h| h != hwnd);
            self.mru_hwnds.retain(|h| h != hwnd);
            self.work_area_positions.remove(hwnd);
            if self.current_main_hwnd == Some(*hwnd) {
                // Pop the stack to find the previous main window.
                self.current_main_hwnd = self.main_window_stack.pop();
                self.current_main_pid = self.current_main_hwnd.and_then(|h| {
                    real_windows.iter().find(|w| w.hwnd == h).map(|w| w.owner_pid)
                });
            }
            if self.pinned_left_hwnd == Some(*hwnd) {
                self.pinned_left_hwnd = None;
                self.pinned_left_pid = None;
                if let Some(ref mut wa) = self.work_area {
                    wa.set_left_reference_active(false);
                }
            }
            if self.pinned_right_hwnd == Some(*hwnd) {
                self.pinned_right_hwnd = None;
                self.pinned_right_pid = None;
                if let Some(ref mut wa) = self.work_area {
                    wa.set_right_reference_active(false);
                }
            }
        }
        self.known_window_ids = current_ids;

        // Update window order: keep existing order; insert new windows right
        // after the last existing window from the same process (fall back to
        // the end if no sibling exists).
        let mut new_order: Vec<isize> = self
            .window_order
            .iter()
            .copied()
            .filter(|id| self.known_window_ids.contains(id))
            .collect();
        let pid_by_hwnd: HashMap<isize, u32> =
            real_windows.iter().map(|w| (w.hwnd, w.owner_pid)).collect();
        for w in &real_windows {
            if new_order.contains(&w.hwnd) {
                continue;
            }
            let last_same = new_order
                .iter()
                .rposition(|h| pid_by_hwnd.get(h) == Some(&w.owner_pid));
            match last_same {
                Some(idx) => new_order.insert(idx + 1, w.hwnd),
                None => new_order.push(w.hwnd),
            }
        }
        self.window_order = new_order;

        // If no main window is set, pick the first real window.
        if self.current_main_hwnd.is_none() {
            if let Some(first) = real_windows.first() {
                self.current_main_hwnd = Some(first.hwnd);
                self.current_main_pid = Some(first.owner_pid);
            }
        }

        let main_hwnd = self.current_main_hwnd;
        let pinned_left_hwnd = self.pinned_left_hwnd;
        let pinned_right_hwnd = self.pinned_right_hwnd;

        // Separate main window from thumbnail windows.
        let thumbnail_windows: Vec<_> = real_windows
            .iter()
            .filter(|w| {
                Some(w.hwnd) != main_hwnd
                    && Some(w.hwnd) != pinned_left_hwnd
                    && Some(w.hwnd) != pinned_right_hwnd
            })
            .collect();

        // Build screen regions from monitors.
        self.monitor_manager.refresh();
        let work_area_frame = self.work_area.as_ref().map(|wa| wa.frame());
        let main_screen_index = work_area_frame.as_ref().and_then(|f| {
            self.monitor_manager
                .monitors()
                .iter()
                .find(|m| m.work_area.contains_point(f.x + f.width / 2.0, f.y + f.height / 2.0))
                .map(|m| m.index)
        });

        let screen_regions = self.monitor_manager.to_screen_regions(
            work_area_frame.as_ref(),
            main_screen_index,
        );

        // Build window metrics for the layout engine.
        let window_metrics: Vec<WindowMetrics> = thumbnail_windows
            .iter()
            .map(|w| {
                let aspect = if w.frame.height > 0.0 {
                    w.frame.width / w.frame.height
                } else {
                    16.0 / 9.0
                };
                WindowMetrics {
                    window_id: w.hwnd,
                    aspect_ratio: aspect,
                    original_screen_index: w.original_screen_index,
                    original_height: w.frame.height,
                    is_manually_assigned: self.manual_screen_assignment.contains(&w.hwnd),
                }
            })
            .collect();

        // Run the layout engine.
        let slots = self.layout_engine.layout(&screen_regions, &window_metrics);

        // Move main window into the work area.
        if let (Some(main_h), Some(ref wa)) = (main_hwnd, &self.work_area) {
            let any_pinned = pinned_left_hwnd.is_some() || pinned_right_hwnd.is_some();
            let work_target = if any_pinned {
                wa.main_panel_frame()
            } else {
                wa.usable_frame()
            };
            let main_native_size = real_windows
                .iter()
                .find(|w| w.hwnd == main_h)
                .map(|w| (w.frame.width, w.frame.height))
                .unwrap_or((work_target.width, work_target.height));
            let target = crate::swap_resize::decide_main_window_target(
                main_native_size,
                work_target,
                any_pinned,
                crate::config::load().swap_resize_mode,
            );
            self.window_manager.move_window(
                main_h,
                target.x.round() as i32,
                target.y.round() as i32,
                target.width.round() as i32,
                target.height.round() as i32,
            );
            self.work_area_positions.insert(main_h, target);
        }

        // Move pinned LEFT reference window into the left panel.
        if let (Some(pin_h), Some(ref wa)) = (pinned_left_hwnd, &self.work_area) {
            if let Some(target) = wa.left_reference_panel_frame() {
                self.window_manager.move_window(
                    pin_h,
                    target.x.round() as i32,
                    target.y.round() as i32,
                    target.width.round() as i32,
                    target.height.round() as i32,
                );
                self.work_area_positions.insert(pin_h, target);
            }
        }

        // Move pinned RIGHT reference window into the right panel.
        if let (Some(pin_h), Some(ref wa)) = (pinned_right_hwnd, &self.work_area) {
            if let Some(target) = wa.right_reference_panel_frame() {
                self.window_manager.move_window(
                    pin_h,
                    target.x.round() as i32,
                    target.y.round() as i32,
                    target.width.round() as i32,
                    target.height.round() as i32,
                );
                self.work_area_positions.insert(pin_h, target);
            }
        }

        // Park all non-main, non-pinned windows.
        for w in &thumbnail_windows {
            if !self.parked_windows.contains(&w.hwnd) {
                if let Some(ref mut parking) = self.parking_manager {
                    if parking.park_window(w.hwnd) {
                        self.parked_windows.insert(w.hwnd);
                    }
                } else {
                    // Fallback: park offscreen directly.
                    let slot = self.parked_windows.len();
                    crate::virtual_desktop::park_window_offscreen(w.hwnd, slot);
                    self.parked_windows.insert(w.hwnd);
                }
            }
        }

        // Update overlay windows.
        if let Some(ref mut overlay) = self.overlay_manager {
            let all_info: Vec<_> = real_windows
                .iter()
                .filter(|w| {
                    Some(w.hwnd) != main_hwnd
                        && Some(w.hwnd) != pinned_left_hwnd
                        && Some(w.hwnd) != pinned_right_hwnd
                })
                .cloned()
                .collect();
            overlay.update_slots(&slots, &all_info);
            overlay.set_active_window(main_hwnd);
            // Overlay manager currently tracks one pinned hwnd; prefer right
            // then left for visual purposes.
            overlay.set_pinned_reference(pinned_right_hwnd.or(pinned_left_hwnd));
        }

        // Re-apply recency glow — newly materialized overlays pick it up.
        self.refresh_mru_highlights();

        // Register / update DWM thumbnails (source window → overlay window).
        self.register_thumbnails_for_slots(&slots);
    }

    /// Register or update DWM thumbnails for the current layout slots.
    fn register_thumbnails_for_slots(&mut self, slots: &[crate::types::WindowSlot]) {
        // Get the source_hwnd → overlay_hwnd mapping from the overlay manager.
        let overlay_hwnds = self
            .overlay_manager
            .as_ref()
            .map(|o| o.overlay_hwnds())
            .unwrap_or_default();

        let current_slot_ids: HashSet<isize> = slots.iter().map(|s| s.window_id).collect();

        // Unregister thumbnails for windows no longer in the slot set.
        let stale: Vec<isize> = overlay_hwnds
            .keys()
            .copied()
            .filter(|id| !current_slot_ids.contains(id))
            .collect();
        for id in stale {
            self.thumbnail_manager.unregister(id);
        }

        // Register new or update existing DWM thumbnails.
        for slot in slots {
            let source = slot.window_id;
            let w = slot.rect.width.round() as i32;
            let h = slot.rect.height.round() as i32;

            if self.thumbnail_manager.is_registered(source) {
                // Update destination rect for existing thumbnail.
                self.thumbnail_manager.update_position(source, w, h, 32);
            } else if let Some(&dest_hwnd) = overlay_hwnds.get(&source) {
                // Register new DWM thumbnail: source window → overlay window.
                self.thumbnail_manager.register(source, dest_hwnd, w, h);
            }
        }
    }

    /// Check if a window handle belongs to one of our overlay or work-area windows.
    fn is_our_overlay(&self, hwnd: isize) -> bool {
        if let Some(ref overlay) = self.overlay_manager {
            if overlay.overlay_hwnds().values().any(|&h| h == hwnd) {
                return true;
            }
        }
        if let Some(ref wa) = self.work_area {
            if wa.hwnd() == hwnd {
                return true;
            }
        }
        false
    }

    // -----------------------------------------------------------------------
    // Window event handling
    // -----------------------------------------------------------------------

    fn handle_window_destroyed(&mut self, hwnd: isize) {
        self.parked_windows.remove(&hwnd);
        self.main_window_stack.retain(|h| *h != hwnd);
        self.mru_hwnds.retain(|h| *h != hwnd);
        self.work_area_positions.remove(&hwnd);

        if self.current_main_hwnd == Some(hwnd) {
            self.current_main_hwnd = self.main_window_stack.pop();
            self.current_main_pid = None;
            // Try to resolve pid for the new main window.
            if let Some(new_main) = self.current_main_hwnd {
                let windows = self.window_tracker.refresh();
                if let Some(info) = windows.iter().find(|w| w.hwnd == new_main) {
                    self.current_main_pid = Some(info.owner_pid);
                }
            }
        }

        if self.pinned_left_hwnd == Some(hwnd) {
            self.pinned_left_hwnd = None;
            self.pinned_left_pid = None;
            if let Some(ref mut wa) = self.work_area {
                wa.set_left_reference_active(false);
            }
        }
        if self.pinned_right_hwnd == Some(hwnd) {
            self.pinned_right_hwnd = None;
            self.pinned_right_pid = None;
            if let Some(ref mut wa) = self.work_area {
                wa.set_right_reference_active(false);
            }
        }

        self.thumbnail_manager.unregister(hwnd);
    }

    fn handle_window_focused(&mut self, hwnd: isize) {
        let wa_hwnd = self.work_area.as_ref().map(|w| w.hwnd()).unwrap_or(0);

        // Ignore focus events for our own windows.
        if hwnd == wa_hwnd || hwnd == 0 {
            return;
        }

        // If the focused window is the current main window, nothing to do.
        if self.current_main_hwnd == Some(hwnd) {
            return;
        }

        // If the focused window is a pinned reference, nothing to do.
        if self.pinned_left_hwnd == Some(hwnd) || self.pinned_right_hwnd == Some(hwnd) {
            return;
        }

        // If the focused window is one of our known windows (a parked window
        // received focus from outside, e.g., Alt+Tab), auto-swap it in.
        if self.known_window_ids.contains(&hwnd) && self.parked_windows.contains(&hwnd) {
            self.handle_thumbnail_click(hwnd);
        }
    }

    // -----------------------------------------------------------------------
    // Recency glow (MRU)
    // -----------------------------------------------------------------------

    /// Capacity of the MRU glow list.
    const MRU_CAPACITY: usize = 3;

    /// Record a window as the most-recently-interacted thumbnail and refresh
    /// overlay highlights. Dedups existing entries before insertion.
    fn push_mru(&mut self, hwnd: isize) {
        self.mru_hwnds.retain(|&h| h != hwnd);
        self.mru_hwnds.push_front(hwnd);
        while self.mru_hwnds.len() > Self::MRU_CAPACITY {
            self.mru_hwnds.pop_back();
        }
        self.refresh_mru_highlights();
    }

    /// Apply the current MRU state (or clear, if disabled by config) to all
    /// overlays. Safe to call when overlay_manager is absent.
    fn refresh_mru_highlights(&mut self) {
        let enabled = crate::config::load().mru_glow_enabled;
        let list: Vec<isize> = self.mru_hwnds.iter().copied().collect();
        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.apply_mru_ranks(&list, enabled);
        }
    }

    // -----------------------------------------------------------------------
    // Thumbnail click (window swap)
    // -----------------------------------------------------------------------

    fn handle_thumbnail_click(&mut self, hwnd: isize) {
        if !self.is_active {
            return;
        }

        self.exit_hint_mode();

        // Recency glow: the target window is about to become active, so
        // strip it from MRU — active windows aren't "recently-used
        // thumbnails". The outgoing main is the one that just turned
        // into a thumbnail, so push it instead. Covers click / spring-load /
        // focus auto-swap (Alt-Tab via handle_window_focused) uniformly.
        self.mru_hwnds.retain(|&h| h != hwnd);
        if let Some(old) = self.current_main_hwnd {
            self.push_mru(old);
        } else {
            self.refresh_mru_highlights();
        }

        let old_main = self.current_main_hwnd;

        // Park the current main window.
        if let Some(old) = old_main {
            if let Some(ref mut parking) = self.parking_manager {
                if parking.park_window(old) {
                    self.parked_windows.insert(old);
                }
            } else {
                let slot = self.parked_windows.len();
                crate::virtual_desktop::park_window_offscreen(old, slot);
                self.parked_windows.insert(old);
            }
            // Push to stack.
            self.main_window_stack.push(old);
        }

        // Unpark the clicked window.
        self.parked_windows.remove(&hwnd);
        if let Some(ref mut parking) = self.parking_manager {
            parking.unpark_window(hwnd);
        }

        // Update main window.
        self.current_main_hwnd = Some(hwnd);
        // Try to resolve pid.
        let windows = self.window_tracker.refresh();
        if let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) {
            self.current_main_pid = Some(info.owner_pid);
        }

        // Focus the new main window.
        self.window_manager.focus_window(hwnd);

        // Refresh layout to reposition everything.
        self.refresh_layout();
    }

    // -----------------------------------------------------------------------
    // Drag reorder
    // -----------------------------------------------------------------------

    /// Handle a completed thumbnail drag: reorder window_order so the dragged
    /// window is placed next to whichever overlay it was dropped on.
    fn handle_drag_reorder(&mut self, dragged_hwnd: isize) {
        if !self.is_active {
            return;
        }

        // Recency glow: any drag completion counts, regardless of whether it
        // resolves to a pin or a reorder.
        self.push_mru(dragged_hwnd);

        // Get cursor position at drop time.
        #[cfg(windows)]
        let cursor_pos = unsafe {
            let mut pt = windows::Win32::Foundation::POINT::default();
            let _ = windows::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt);
            (pt.x, pt.y)
        };
        #[cfg(not(windows))]
        let cursor_pos = (0i32, 0i32);

        // Drag-to-pin: if the cursor was released inside the work area,
        // pin the dragged window to the left or right based on cursor X
        // relative to the work area's midpoint.
        if let Some(ref wa) = self.work_area {
            let f = wa.frame();
            let cx = cursor_pos.0 as f64;
            let cy = cursor_pos.1 as f64;
            if cx >= f.x && cx < f.x + f.width && cy >= f.y && cy < f.y + f.height {
                let mid_x = f.x + f.width / 2.0;
                let side = if cx < mid_x { ReferenceSide::Left } else { ReferenceSide::Right };
                self.pin_as_reference(dragged_hwnd, side);
                return;
            }
        }

        // Find which overlay the cursor is over (excluding the dragged one)
        // along with that overlay's screen rect so we can choose the insertion
        // side (before/after the target) based on which half of the target the
        // cursor fell on.
        let hit = self.overlay_manager.as_ref().and_then(|om| {
            om.source_hwnd_and_rect_at_point(cursor_pos.0, cursor_pos.1, Some(dragged_hwnd))
        });

        if let Some((target, (left, top, right, bottom))) = hit {
            // Windows screen coords: y grows downward, so "above" = smaller y =
            // earlier in reading order; "below" = later. If the cursor is
            // within the target's vertical band, fall back to x vs. midX.
            let mid_x = (left + right) / 2;
            let insert_before = if cursor_pos.1 < top {
                true
            } else if cursor_pos.1 >= bottom {
                false
            } else {
                cursor_pos.0 < mid_x
            };

            // Remove dragged from its current position, then insert at the
            // chosen side of the target.
            self.window_order.retain(|&h| h != dragged_hwnd);
            if let Some(pos) = self.window_order.iter().position(|&h| h == target) {
                let insert_at = if insert_before { pos } else { pos + 1 };
                self.window_order.insert(insert_at, dragged_hwnd);
            } else {
                self.window_order.push(dragged_hwnd);
            }
            log::debug!(
                "Drag reorder: moved {:#x} {} {:#x}",
                dragged_hwnd,
                if insert_before { "before" } else { "after" },
                target
            );
        }

        self.refresh_layout();
    }

    // -----------------------------------------------------------------------
    // Hint mode
    // -----------------------------------------------------------------------

    fn toggle_hint_mode(&mut self) {
        if self.is_hint_mode {
            // If in hint mode, exit and switch to previous window.
            self.exit_hint_mode();
            if let Some(prev) = self.main_window_stack.last().copied() {
                self.handle_thumbnail_click(prev);
            }
        } else {
            self.enter_hint_mode();
        }
    }

    fn enter_hint_mode(&mut self) {
        if !self.is_active {
            return;
        }
        self.is_hint_mode = true;

        let (preassigned, remaining_keys) = self.compute_hint_assignments();

        if let Some(ref mut overlay) = self.overlay_manager {
            self.hint_mapping = overlay.show_hints(&remaining_keys, &preassigned);
        }

        if let Some(ref input) = self.input_manager {
            input.set_hint_mode(true);
        }

        log::debug!("Hint mode entered with {} mappings", self.hint_mapping.len());
    }

    /// Compute the reserved-key preassignments for the current window snapshot,
    /// plus the remaining auto-fill keys (original `generate_hint_keys()` minus
    /// any reserved keys — reserved keys are withheld from the pool even when
    /// their target window is absent, so the slot stays frozen for the user).
    fn compute_hint_assignments(&self) -> (HashMap<isize, String>, Vec<String>) {
        let all_keys = generate_hint_keys();
        let reservations = crate::config::load().reservations;
        if reservations.is_empty() {
            return (HashMap::new(), all_keys);
        }

        let windows = self.window_tracker.refresh();
        let mut preassigned: HashMap<isize, String> = HashMap::new();
        let mut used_keys: HashSet<String> = HashSet::new();
        let mut used_hwnds: HashSet<isize> = HashSet::new();

        for res in &reservations {
            used_keys.insert(res.key.clone());
            if let Some(hwnd) = Self::match_reservation(res, &windows, &used_hwnds) {
                preassigned.insert(hwnd, res.key.clone());
                used_hwnds.insert(hwnd);
            }
        }

        let remaining: Vec<String> = all_keys
            .into_iter()
            .filter(|k| !used_keys.contains(k))
            .collect();
        (preassigned, remaining)
    }

    /// Find the best window in `windows` that matches a reservation, skipping
    /// hwnds already claimed by an earlier reservation. Matching rules:
    /// 1. Same `owner_name` (case-insensitive).
    /// 2. If the reservation has a `title_pattern`, prefer exact-title match;
    ///    else fall back to the sole candidate if only one exists (single-window
    ///    apps). If there's a title pattern but zero exact matches and multiple
    ///    candidates, no match — ambiguous.
    /// 3. With no title pattern, pick the lowest hwnd for determinism.
    fn match_reservation(
        res: &crate::config::Reservation,
        windows: &[crate::types::WindowInfo],
        used: &HashSet<isize>,
    ) -> Option<isize> {
        let candidates: Vec<&crate::types::WindowInfo> = windows
            .iter()
            .filter(|w| !used.contains(&w.hwnd))
            .filter(|w| w.owner_name.eq_ignore_ascii_case(&res.owner_name))
            .collect();

        if let Some(ref pattern) = res.title_pattern {
            if let Some(exact) = candidates.iter().find(|w| &w.title == pattern) {
                return Some(exact.hwnd);
            }
            if candidates.len() == 1 {
                return Some(candidates[0].hwnd);
            }
            return None;
        }

        candidates.iter().map(|w| w.hwnd).min()
    }

    fn exit_hint_mode(&mut self) {
        if !self.is_hint_mode {
            return;
        }
        self.is_hint_mode = false;
        self.hint_mapping.clear();
        self.hint_editing_hwnd = None;
        self.hint_editing_original_key = None;

        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.hide_hints();
        }

        if let Some(ref input) = self.input_manager {
            input.set_hint_mode(false);
        }

        log::debug!("Hint mode exited");
    }

    fn handle_hint_key(&mut self, ch: char, shift: bool) {
        if !self.is_hint_mode {
            return;
        }

        // In edit mode, any alpha/digit key commits a new reservation.
        if self.hint_editing_hwnd.is_some() {
            let key = ch.to_uppercase().to_string();
            self.commit_hint_edit(key);
            return;
        }

        let key = ch.to_uppercase().to_string();

        // Shift+<key> → enter edit mode for the window currently showing `key`.
        if shift {
            if let Some(&hwnd) = self.hint_mapping.get(&key) {
                self.enter_hint_edit(hwnd, key);
                return;
            }
            // Shift+<unknown-key> — ignore, don't exit the mode.
            return;
        }

        if let Some(&hwnd) = self.hint_mapping.get(&key) {
            self.exit_hint_mode();
            self.handle_thumbnail_click(hwnd);
        }
    }

    /// Escape behaviour: while editing a pill, cancel the edit only; otherwise
    /// exit hint mode entirely.
    fn handle_hint_escape(&mut self) {
        if self.hint_editing_hwnd.is_some() {
            self.cancel_hint_edit();
        } else {
            self.exit_hint_mode();
        }
    }

    /// Backspace: while editing a pill, clear that window's reservation (the
    /// key returns to the auto-assignment pool). Outside editing, do nothing.
    fn handle_hint_backspace(&mut self) {
        if self.hint_editing_hwnd.is_some() {
            self.clear_hint_edit_reservation();
        }
    }

    /// Click landed directly on a hint pill — enter edit mode for that
    /// window's reservation key. Mirrors Shift+<key> entry.
    fn handle_hint_pill_clicked(&mut self, hwnd: isize) {
        if !self.is_hint_mode {
            return;
        }
        let current_key = match self
            .hint_mapping
            .iter()
            .find_map(|(k, &h)| if h == hwnd { Some(k.clone()) } else { None })
        {
            Some(k) => k,
            None => return,
        };
        self.enter_hint_edit(hwnd, current_key);
    }

    /// Flip a single pill into editing mode. Preserves the current displayed
    /// character so the user sees what key they're replacing.
    fn enter_hint_edit(&mut self, hwnd: isize, current_key: String) {
        self.hint_editing_hwnd = Some(hwnd);
        self.hint_editing_original_key = Some(current_key.clone());
        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.set_hint_editing(hwnd, current_key);
        }
    }

    /// Commit the edit: persist the reservation for the editing hwnd with
    /// `new_key`, then refresh the whole hint grid so the new assignment is
    /// reflected visually and the auto-pool is re-derived.
    fn commit_hint_edit(&mut self, new_key: String) {
        let hwnd = match self.hint_editing_hwnd {
            Some(h) => h,
            None => return,
        };
        let windows = self.window_tracker.refresh();
        let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) else {
            self.cancel_hint_edit();
            return;
        };
        let title_pattern = if info.title.is_empty() { None } else { Some(info.title.clone()) };
        crate::config::update(|cfg| {
            cfg.reservations
                .retain(|r| !(r.owner_name.eq_ignore_ascii_case(&info.owner_name) && r.title_pattern == title_pattern));
            cfg.reservations.retain(|r| r.key != new_key);
            cfg.reservations.push(crate::config::Reservation {
                owner_name: info.owner_name.clone(),
                title_pattern,
                key: new_key,
            });
        });
        self.hint_editing_hwnd = None;
        self.hint_editing_original_key = None;
        self.refresh_hint_assignments();
    }

    /// Clear the reservation for the window currently being edited. The key
    /// drops back into the auto-assignment pool on refresh.
    fn clear_hint_edit_reservation(&mut self) {
        let hwnd = match self.hint_editing_hwnd {
            Some(h) => h,
            None => return,
        };
        let windows = self.window_tracker.refresh();
        let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) else {
            self.cancel_hint_edit();
            return;
        };
        let title_pattern = if info.title.is_empty() { None } else { Some(info.title.clone()) };
        let owner_name = info.owner_name.clone();
        crate::config::update(|cfg| {
            cfg.reservations
                .retain(|r| !(r.owner_name.eq_ignore_ascii_case(&owner_name) && r.title_pattern == title_pattern));
        });
        self.hint_editing_hwnd = None;
        self.hint_editing_original_key = None;
        self.refresh_hint_assignments();
    }

    /// Cancel the current edit without persisting, restoring the previous pill
    /// style (reserved iff the key is still present in the store, else auto).
    fn cancel_hint_edit(&mut self) {
        let (hwnd, original_key) = match (self.hint_editing_hwnd, self.hint_editing_original_key.clone()) {
            (Some(h), Some(k)) => (h, k),
            _ => return,
        };
        let reserved = crate::config::load()
            .reservations
            .iter()
            .any(|r| r.key == original_key);
        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.set_hint_style(hwnd, original_key, reserved);
        }
        self.hint_editing_hwnd = None;
        self.hint_editing_original_key = None;
    }

    /// Re-derive the full hint grid from the current reservation store, used
    /// after the store mutates while hint mode is still open.
    fn refresh_hint_assignments(&mut self) {
        self.hint_mapping.clear();
        let (preassigned, remaining_keys) = self.compute_hint_assignments();
        if let Some(ref mut overlay) = self.overlay_manager {
            self.hint_mapping = overlay.show_hints(&remaining_keys, &preassigned);
        }
    }

    // -----------------------------------------------------------------------
    // Pinned reference
    // -----------------------------------------------------------------------

    #[allow(dead_code)]
    pub(crate) fn pin_as_reference(&mut self, hwnd: isize, side: ReferenceSide) {
        if !self.is_active {
            return;
        }

        // Recency glow: pinning is an interaction.
        self.push_mru(hwnd);

        // If this window is already pinned on the other side, unpin it there first.
        match side {
            ReferenceSide::Left => {
                if self.pinned_right_hwnd == Some(hwnd) {
                    self.unpin_reference(ReferenceSide::Right);
                }
                // If something else was pinned on the left, park it.
                if let Some(old) = self.pinned_left_hwnd.take() {
                    self.pinned_left_pid = None;
                    self.park_hwnd(old);
                }
                self.pinned_left_hwnd = Some(hwnd);
                let windows = self.window_tracker.refresh();
                if let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) {
                    self.pinned_left_pid = Some(info.owner_pid);
                }
                if let Some(ref mut wa) = self.work_area {
                    wa.set_left_reference_active(true);
                }
            }
            ReferenceSide::Right => {
                if self.pinned_left_hwnd == Some(hwnd) {
                    self.unpin_reference(ReferenceSide::Left);
                }
                if let Some(old) = self.pinned_right_hwnd.take() {
                    self.pinned_right_pid = None;
                    self.park_hwnd(old);
                }
                self.pinned_right_hwnd = Some(hwnd);
                let windows = self.window_tracker.refresh();
                if let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) {
                    self.pinned_right_pid = Some(info.owner_pid);
                }
                if let Some(ref mut wa) = self.work_area {
                    wa.set_right_reference_active(true);
                }
            }
        }

        // Unpark the window (it goes into the reference panel, not parked).
        self.parked_windows.remove(&hwnd);
        if let Some(ref mut parking) = self.parking_manager {
            parking.unpark_window(hwnd);
        }

        // Overlay manager currently tracks a single pinned hwnd; we feed it the
        // most recently pinned window so the overlay gets the pinned visual.
        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.set_pinned_reference(Some(hwnd));
        }

        self.refresh_layout();
        log::info!("Pinned window {:#x} as {:?} reference", hwnd, side);
    }

    fn unpin_reference(&mut self, side: ReferenceSide) {
        let hwnd_opt = match side {
            ReferenceSide::Left => self.pinned_left_hwnd.take(),
            ReferenceSide::Right => self.pinned_right_hwnd.take(),
        };
        let Some(hwnd) = hwnd_opt else { return; };

        match side {
            ReferenceSide::Left => {
                self.pinned_left_pid = None;
                if let Some(ref mut wa) = self.work_area {
                    wa.set_left_reference_active(false);
                }
            }
            ReferenceSide::Right => {
                self.pinned_right_pid = None;
                if let Some(ref mut wa) = self.work_area {
                    wa.set_right_reference_active(false);
                }
            }
        }

        // Park the unpinned window.
        self.park_hwnd(hwnd);

        // If no reference is pinned anymore, clear the overlay's pinned marker.
        if self.pinned_left_hwnd.is_none() && self.pinned_right_hwnd.is_none() {
            if let Some(ref mut overlay) = self.overlay_manager {
                overlay.set_pinned_reference(None);
            }
        }

        self.refresh_layout();
        log::info!("Unpinned {:?} reference window {:#x}", side, hwnd);
    }

    fn park_hwnd(&mut self, hwnd: isize) {
        if let Some(ref mut parking) = self.parking_manager {
            if parking.park_window(hwnd) {
                self.parked_windows.insert(hwnd);
            }
        } else {
            let slot = self.parked_windows.len();
            crate::virtual_desktop::park_window_offscreen(hwnd, slot);
            self.parked_windows.insert(hwnd);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReferenceSide {
    Left,
    Right,
}

impl Drop for GlanceApp {
    fn drop(&mut self) {
        self.deactivate();
    }
}
