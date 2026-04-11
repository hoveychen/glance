//! Main orchestrator for Glance Windows.
//!
//! Ties all modules together into a single event loop: tray icon, keyboard
//! input, window tracking, layout engine, DWM thumbnails, overlay windows,
//! and the frosted-glass work area.

use crate::input::{InputEvent, InputManager};
use crate::layout::MissionControlLayoutEngine;
use crate::monitor::MonitorManager;
use crate::overlay::{OverlayEvent, OverlayManager};
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
    work_area_positions: HashMap<isize, Rect>,
    manual_screen_assignment: HashSet<isize>,

    // Hint mode
    is_hint_mode: bool,
    hint_mapping: HashMap<String, isize>,

    // Pinned reference
    pinned_reference_hwnd: Option<isize>,
    pinned_reference_pid: Option<u32>,

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
            work_area_positions: HashMap::new(),
            manual_screen_assignment: HashSet::new(),

            is_hint_mode: false,
            hint_mapping: HashMap::new(),

            pinned_reference_hwnd: None,
            pinned_reference_pid: None,

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

        log::info!("Glance app running (inactive, waiting for activation)");

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
            AppEvent::Input(InputEvent::ToggleHotkey) => {
                self.toggle_active();
            }
            AppEvent::Input(InputEvent::AltDoubleTap) => {
                if self.is_active {
                    self.toggle_hint_mode();
                }
            }
            AppEvent::Input(InputEvent::HintKeyPressed(ch)) => {
                self.handle_hint_key(ch);
            }
            AppEvent::Input(InputEvent::EscapePressed) => {
                self.exit_hint_mode();
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
            AppEvent::WorkArea(WorkAreaEvent::ExitClicked) => {
                self.deactivate();
            }
            AppEvent::WorkArea(WorkAreaEvent::SwitchClicked) => {
                if self.is_active {
                    self.toggle_hint_mode();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::UnpinClicked) => {
                self.unpin_reference();
            }
            AppEvent::WorkArea(WorkAreaEvent::Resized(_)) => {
                if self.is_active {
                    self.refresh_layout();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::Moved(_)) => {
                if self.is_active {
                    self.refresh_layout();
                }
            }
            AppEvent::WorkArea(WorkAreaEvent::SplitRatioChanged(_)) => {
                if self.is_active {
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

        // Determine work area dimensions: 55% width x 60% height of primary,
        // centered.
        self.monitor_manager.refresh();
        let primary = self.monitor_manager.primary().cloned();
        let work_frame = if let Some(ref mon) = primary {
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
            Ok(wa) => {
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
        self.work_area_positions.clear();
        self.manual_screen_assignment.clear();
        self.hint_mapping.clear();
        self.pinned_reference_hwnd = None;
        self.pinned_reference_pid = None;

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
            self.work_area_positions.remove(hwnd);
            if self.current_main_hwnd == Some(*hwnd) {
                // Pop the stack to find the previous main window.
                self.current_main_hwnd = self.main_window_stack.pop();
                self.current_main_pid = self.current_main_hwnd.and_then(|h| {
                    real_windows.iter().find(|w| w.hwnd == h).map(|w| w.owner_pid)
                });
            }
            if self.pinned_reference_hwnd == Some(*hwnd) {
                self.pinned_reference_hwnd = None;
                self.pinned_reference_pid = None;
                if let Some(ref mut wa) = self.work_area {
                    wa.set_reference_active(false);
                }
            }
        }
        self.known_window_ids = current_ids;

        // Update window order (add new windows to the end, keep existing order).
        let mut new_order: Vec<isize> = self
            .window_order
            .iter()
            .copied()
            .filter(|id| self.known_window_ids.contains(id))
            .collect();
        for w in &real_windows {
            if !new_order.contains(&w.hwnd) {
                new_order.push(w.hwnd);
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
        let pinned_hwnd = self.pinned_reference_hwnd;

        // Separate main window from thumbnail windows.
        let thumbnail_windows: Vec<_> = real_windows
            .iter()
            .filter(|w| Some(w.hwnd) != main_hwnd && Some(w.hwnd) != pinned_hwnd)
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
            let target = if pinned_hwnd.is_some() {
                wa.main_panel_frame()
            } else {
                wa.usable_frame()
            };
            self.window_manager.move_window(
                main_h,
                target.x.round() as i32,
                target.y.round() as i32,
                target.width.round() as i32,
                target.height.round() as i32,
            );
            self.work_area_positions.insert(main_h, target);
        }

        // Move pinned reference window into the reference panel.
        if let (Some(pin_h), Some(ref wa)) = (pinned_hwnd, &self.work_area) {
            let target = wa.reference_panel_frame();
            self.window_manager.move_window(
                pin_h,
                target.x.round() as i32,
                target.y.round() as i32,
                target.width.round() as i32,
                target.height.round() as i32,
            );
            self.work_area_positions.insert(pin_h, target);
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
                .filter(|w| Some(w.hwnd) != main_hwnd && Some(w.hwnd) != pinned_hwnd)
                .cloned()
                .collect();
            overlay.update_slots(&slots, &all_info);
            overlay.set_active_window(main_hwnd);
            overlay.set_pinned_reference(pinned_hwnd);
        }

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

        if self.pinned_reference_hwnd == Some(hwnd) {
            self.pinned_reference_hwnd = None;
            self.pinned_reference_pid = None;
            if let Some(ref mut wa) = self.work_area {
                wa.set_reference_active(false);
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

        // If the focused window is the pinned reference, nothing to do.
        if self.pinned_reference_hwnd == Some(hwnd) {
            return;
        }

        // If the focused window is one of our known windows (a parked window
        // received focus from outside, e.g., Alt+Tab), auto-swap it in.
        if self.known_window_ids.contains(&hwnd) && self.parked_windows.contains(&hwnd) {
            self.handle_thumbnail_click(hwnd);
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

        // Get cursor position at drop time.
        #[cfg(windows)]
        let cursor_pos = unsafe {
            let mut pt = windows::Win32::Foundation::POINT::default();
            let _ = windows::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt);
            (pt.x, pt.y)
        };
        #[cfg(not(windows))]
        let cursor_pos = (0i32, 0i32);

        // Find which overlay the cursor is over (excluding the dragged one).
        let target_hwnd = self
            .overlay_manager
            .as_ref()
            .and_then(|om| om.source_hwnd_at_point(cursor_pos.0, cursor_pos.1, Some(dragged_hwnd)));

        if let Some(target) = target_hwnd {
            // Remove dragged from current position.
            self.window_order.retain(|&h| h != dragged_hwnd);
            // Find target position and insert dragged before it.
            if let Some(pos) = self.window_order.iter().position(|&h| h == target) {
                self.window_order.insert(pos, dragged_hwnd);
            } else {
                self.window_order.push(dragged_hwnd);
            }
            log::debug!(
                "Drag reorder: moved {:#x} before {:#x}",
                dragged_hwnd,
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

        let hint_keys = generate_hint_keys();
        if let Some(ref mut overlay) = self.overlay_manager {
            self.hint_mapping = overlay.show_hints(&hint_keys);
        }

        if let Some(ref input) = self.input_manager {
            input.set_hint_mode(true);
        }

        log::debug!("Hint mode entered with {} mappings", self.hint_mapping.len());
    }

    fn exit_hint_mode(&mut self) {
        if !self.is_hint_mode {
            return;
        }
        self.is_hint_mode = false;
        self.hint_mapping.clear();

        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.hide_hints();
        }

        if let Some(ref input) = self.input_manager {
            input.set_hint_mode(false);
        }

        log::debug!("Hint mode exited");
    }

    fn handle_hint_key(&mut self, ch: char) {
        if !self.is_hint_mode {
            return;
        }

        let key = ch.to_uppercase().to_string();
        if let Some(&hwnd) = self.hint_mapping.get(&key) {
            self.exit_hint_mode();
            self.handle_thumbnail_click(hwnd);
        }
    }

    // -----------------------------------------------------------------------
    // Pinned reference
    // -----------------------------------------------------------------------

    #[allow(dead_code)]
    fn pin_as_reference(&mut self, hwnd: isize) {
        if !self.is_active {
            return;
        }

        self.pinned_reference_hwnd = Some(hwnd);

        // Resolve pid.
        let windows = self.window_tracker.refresh();
        if let Some(info) = windows.iter().find(|w| w.hwnd == hwnd) {
            self.pinned_reference_pid = Some(info.owner_pid);
        }

        // Unpark the window (it will be placed in the reference panel).
        self.parked_windows.remove(&hwnd);
        if let Some(ref mut parking) = self.parking_manager {
            parking.unpark_window(hwnd);
        }

        if let Some(ref mut wa) = self.work_area {
            wa.set_reference_active(true);
        }

        if let Some(ref mut overlay) = self.overlay_manager {
            overlay.set_pinned_reference(Some(hwnd));
        }

        self.refresh_layout();
        log::info!("Pinned window {:#x} as reference", hwnd);
    }

    fn unpin_reference(&mut self) {
        if let Some(hwnd) = self.pinned_reference_hwnd.take() {
            self.pinned_reference_pid = None;

            // Park the unpinned window.
            if let Some(ref mut parking) = self.parking_manager {
                if parking.park_window(hwnd) {
                    self.parked_windows.insert(hwnd);
                }
            } else {
                let slot = self.parked_windows.len();
                crate::virtual_desktop::park_window_offscreen(hwnd, slot);
                self.parked_windows.insert(hwnd);
            }

            if let Some(ref mut wa) = self.work_area {
                wa.set_reference_active(false);
            }

            if let Some(ref mut overlay) = self.overlay_manager {
                overlay.set_pinned_reference(None);
            }

            self.refresh_layout();
            log::info!("Unpinned reference window {:#x}", hwnd);
        }
    }
}

impl Drop for GlanceApp {
    fn drop(&mut self) {
        self.deactivate();
    }
}
