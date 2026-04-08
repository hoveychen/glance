import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "WindowTracker")

/// Tracks all visible windows using CGWindowList + AX observers and reports changes.
final class WindowTracker {

    /// Called when the window list is refreshed. Provides all tracked windows and the current main window ID.
    var onWindowsUpdated: (([WindowInfo], CGWindowID?) -> Void)?

    private(set) var windows: [WindowInfo] = []

    /// Expose windows for external access.
    var lastKnownWindows: [WindowInfo]? { windows.isEmpty ? nil : windows }
    private(set) var mainWindowID: CGWindowID?
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Our own app's PID, to exclude overlay windows from tracking.
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // MARK: - AX Observer State

    /// AX observers per PID, for real-time window creation/focus events.
    private var axObservers: [pid_t: AXObserver] = [:]
    /// PIDs we've already attempted to observe (avoid retrying failed subscriptions every cycle).
    private var observedPIDs: Set<pid_t> = []
    /// Throttle: don't refresh more than once per 200ms from AX events.
    private var lastAXRefreshTime: CFAbsoluteTime = 0
    private var pendingAXRefresh = false

    deinit {
        stopTracking()
    }

    func startTracking() {
        // Initial scan
        refreshWindows()

        // Poll every 1 second as fallback / zombie detection.
        // AX observers handle real-time events for known apps.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshWindows()
        }

        // Also refresh on app activation changes
        let center = NSWorkspace.shared.notificationCenter
        let activateObs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshWindows()
        }
        workspaceObservers.append(activateObs)

        // Observe app launches and terminations to manage AX observers
        let launchObs = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.addAXObserver(for: app.processIdentifier)
            }
            self?.refreshWindows()
        }
        workspaceObservers.append(launchObs)

        let terminateObs = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.removeAXObserver(for: app.processIdentifier)
            }
            self?.refreshWindows()
        }
        workspaceObservers.append(terminateObs)

        // Refresh when the user switches Spaces — CGWindowList only returns
        // windows on the current Space, so we need an immediate rescan.
        let spaceObs = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay for the system to settle after space switch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.refreshWindows()
            }
        }
        workspaceObservers.append(spaceObs)
    }

    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        removeAllAXObservers()
    }

    func forceUpdate() {
        refreshWindows()
    }

    func setMainWindow(_ windowID: CGWindowID) {
        mainWindowID = windowID
        notifyUpdate()
    }

    /// Set the main window ID without triggering an update notification.
    /// Use when the caller will trigger a fresh update separately (e.g., via forceUpdate).
    func setMainWindowSilently(_ windowID: CGWindowID) {
        mainWindowID = windowID
    }

    // MARK: - AX Observers

    /// Subscribe to AX notifications for a given PID.
    /// Listens for window creation and focus changes to trigger immediate refreshes.
    private func addAXObserver(for pid: pid_t) {
        guard pid != ownPID, !observedPIDs.contains(pid) else { return }
        observedPIDs.insert(pid)

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handleAXEvent(notification as String)
        }
        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let app = AXUIElementCreateApplication(pid)

        // Subscribe to key events. These may fail for some apps — that's fine.
        for notif in [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
        ] as [CFString] {
            AXObserverAddNotification(observer, app, notif, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func removeAXObserver(for pid: pid_t) {
        if let observer = axObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observedPIDs.remove(pid)
    }

    private func removeAllAXObservers() {
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObservers.removeAll()
        observedPIDs.removeAll()
    }

    /// Called from AX observer callback. Throttled to avoid excessive refreshes.
    private func handleAXEvent(_ notification: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastAXRefreshTime
        if elapsed >= 0.2 {
            // Enough time has passed — refresh immediately
            lastAXRefreshTime = now
            DispatchQueue.main.async { [weak self] in
                self?.refreshWindows()
            }
        } else if !pendingAXRefresh {
            // Schedule a deferred refresh
            pendingAXRefresh = true
            let delay = 0.2 - elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.pendingAXRefresh = false
                self.lastAXRefreshTime = CFAbsoluteTimeGetCurrent()
                self.refreshWindows()
            }
        }
    }

    // MARK: - Private

    private func refreshWindows() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return }

        var newWindows: [WindowInfo] = []
        var seenIDs = Set<CGWindowID>()
        var seenPIDs = Set<pid_t>()

        for entry in windowList {
            guard let windowID = entry[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = entry[kCGWindowOwnerPID] as? pid_t,
                  let layer = entry[kCGWindowLayer] as? Int,
                  layer == 0  // Normal windows only (menus, tooltips, popups have layer > 0)
            else { continue }

            // Skip our own windows
            if ownerPID == ownPID { continue }

            let ownerName = entry[kCGWindowOwnerName] as? String ?? "Unknown"
            let title = entry[kCGWindowName] as? String ?? ""

            // Skip system/utility windows that shouldn't be managed
            if Self.ignoredOwnerNames.contains(ownerName) { continue }

            // Parse bounds
            guard let boundsDict = entry[kCGWindowBounds] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"]
            else { continue }

            // Skip tiny windows (likely hidden UI elements like tooltips, menus)
            if w < 50 || h < 50 { continue }

            let frame = CGRect(x: x, y: y, width: w, height: h)
            let isOnScreen = entry[kCGWindowIsOnscreen] as? Bool ?? true
            seenIDs.insert(windowID)
            seenPIDs.insert(ownerPID)

            // Reuse existing WindowInfo to preserve latestImage and AX data
            if let existing = windows.first(where: { $0.windowID == windowID }) {
                existing.title = title
                existing.frame = frame
                existing.isOnScreen = isOnScreen
                existing.windowLevel = layer
                newWindows.append(existing)
            } else {
                let info = WindowInfo(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    ownerName: ownerName,
                    title: title,
                    frame: frame,
                    isOnScreen: isOnScreen
                )
                info.windowLevel = layer
                // Determine which screen this window belongs to (CG coords: top-left origin)
                let centerX = x + w / 2
                let centerY = y + h / 2
                let mainH = NSScreen.screens.first?.frame.height ?? 0
                for (idx, screen) in NSScreen.screens.enumerated() {
                    // Convert NSScreen frame (bottom-left) to CG (top-left)
                    let cgScreenY = mainH - screen.frame.origin.y - screen.frame.height
                    let cgScreenRect = CGRect(x: screen.frame.origin.x, y: cgScreenY,
                                              width: screen.frame.width, height: screen.frame.height)
                    if cgScreenRect.contains(CGPoint(x: centerX, y: centerY)) {
                        info.originalScreenIndex = idx
                        break
                    }
                }
                newWindows.append(info)
            }
        }

        // Keep windows that are parked on the virtual display (not on-screen but still tracked)
        for existing in windows where !seenIDs.contains(existing.windowID) {
            // Check if this window is on the virtual display by its frame position
            let vdm = VirtualDisplayManager.shared
            if vdm.isActive && existing.frame.origin.x >= vdm.origin.x - 100 {
                newWindows.append(existing)
                seenPIDs.insert(existing.ownerPID)
            }
        }

        // Enrich windows with AX classification data.
        // Rebuild AX cache for all seen PIDs, then query role/subrole per window.
        let axMgr = AccessibilityManager.shared
        axMgr.rebuildAXCache(for: seenPIDs)
        for info in newWindows {
            // Skip re-classifying windows that already have AX data and are parked
            // (their AX element may not be reachable while on virtual display)
            if info.axSubrole != nil && info.frame.origin.x >= (VirtualDisplayManager.shared.origin.x - 100) {
                continue
            }
            let (role, subrole) = axMgr.getWindowClassification(windowID: info.windowID, pid: info.ownerPID)
            if role != nil || subrole != nil {
                info.axRole = role
                info.axSubrole = subrole
            }
            // windowLevel is already set from CGWindowList layer above
        }

        // Set up AX observers for any new PIDs we haven't subscribed to yet
        for pid in seenPIDs {
            if !observedPIDs.contains(pid) {
                addAXObserver(for: pid)
            }
        }

        // Clean up observers for PIDs no longer present
        let stalePIDs = observedPIDs.subtracting(seenPIDs)
        for pid in stalePIDs {
            removeAXObserver(for: pid)
        }

        windows = newWindows

        // Auto-detect main window only if never set.
        // Don't reset to first window if current main temporarily disappears
        // (it might be in transit between work area and virtual display).
        if mainWindowID == nil {
            // Prefer isActualWindow windows for initial selection
            mainWindowID = windows.first(where: { $0.isActualWindow })?.windowID
                ?? windows.first?.windowID
        }

        notifyUpdate()
    }

    private func notifyUpdate() {
        onWindowsUpdated?(windows, mainWindowID)
    }

    // MARK: - System Window Filter

    /// Owner names of system processes whose windows should be ignored.
    private static let ignoredOwnerNames: Set<String> = [
        "WindowManager",
        "Window Manager",
        "Window Server",
        "Dock",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "ControlCenter",
        "NotificationCenter",
        "AXVisualSupportAgent",
        "TextInputMenuAgent",
        "TextInputSwitcher",
        "universalAccessAuthWarn",
        "ScreenCaptureKit",
        "com.apple.preference.security.remoteservice",
    ]
}
