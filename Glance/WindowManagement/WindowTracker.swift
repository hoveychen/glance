import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "WindowTracker")

// MARK: - Private API: CGS Space filtering

/// Connection to the window server.
@_silgen_name("CGSMainConnectionID")
func _CGSMainConnectionID() -> Int32

/// Returns per-display space info (current space, all spaces, etc.).
@_silgen_name("CGSCopyManagedDisplaySpaces")
func _CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

/// Returns Space IDs that the given windows belong to.
/// mask 0x7 = include all space types (current, others, fullscreen).
@_silgen_name("CGSCopySpacesForWindows")
func _CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray

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

        // Collect the current (visible) Space ID on every display, so we can
        // filter out windows from other Spaces (e.g., fullscreen apps on another
        // desktop). CGSGetActiveSpace only returns the focused display's space —
        // CGSCopyManagedDisplaySpaces covers all monitors.
        let cid = _CGSMainConnectionID()
        var visibleSpaceIDs = Set<Int>()
        if let displaySpaces = _CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] {
            for displayInfo in displaySpaces {
                if let currentSpace = displayInfo["Current Space"] as? [String: Any],
                   let spaceID = currentSpace["id64"] as? Int {
                    visibleSpaceIDs.insert(spaceID)
                }
            }
        }

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

            // Filter out windows from other Spaces (e.g., fullscreen apps on another desktop).
            if !visibleSpaceIDs.isEmpty {
                if let spaces = _CGSCopySpacesForWindows(cid, 0x7, [windowID as NSNumber] as CFArray) as? [NSNumber],
                   !spaces.isEmpty {
                    let windowSpaces = Set(spaces.map { $0.intValue })
                    if windowSpaces.isDisjoint(with: visibleSpaceIDs) {
                        // Not on any visible Space — skip unless it's on the virtual display
                        let vdm = VirtualDisplayManager.shared
                        if !vdm.isActive || x < vdm.origin.x - 100 {
                            continue
                        }
                    }
                }
            }

            let frame = CGRect(x: x, y: y, width: w, height: h)
            let isOnScreen = entry[kCGWindowIsOnscreen] as? Bool ?? true
            let sharingState = entry[kCGWindowSharingState] as? Int ?? 2
            seenIDs.insert(windowID)
            seenPIDs.insert(ownerPID)

            // Reuse existing WindowInfo to preserve latestImage and AX data
            if let existing = windows.first(where: { $0.windowID == windowID }) {
                existing.title = title
                existing.frame = frame
                existing.isOnScreen = isOnScreen
                existing.windowLevel = layer
                existing.sharingState = sharingState
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
                info.sharingState = sharingState
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
                // Verify the window still exists at the OS level — it may have been
                // closed (Cmd+W) or its app may have quit (Cmd+Q).
                if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], existing.windowID) as? [[CFString: Any]],
                   list.contains(where: { ($0[kCGWindowNumber] as? CGWindowID) == existing.windowID }) {
                    newWindows.append(existing)
                    seenPIDs.insert(existing.ownerPID)
                } else {
                    logger.info("Parked window \(existing.displayName) dropped — window no longer exists")
                }
            }
        }

        // Enrich windows with AX classification data.
        // Rebuild AX cache for all seen PIDs, then query role/subrole per window.
        let axMgr = AccessibilityManager.shared
        axMgr.cgWindowEntries = newWindows.map { ($0.windowID, $0.ownerPID, $0.title, $0.frame) }
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

        // Tether detection: identify satellite windows (sidebars, watermarks, drawers)
        // that ride along with a parent window. Runs once per window on first discovery.
        //
        // Heuristic: same-PID + geometric containment/edge-touch +
        //            (non-AXStandardWindow subrole  OR  area < 20% of host).
        //
        // Why not move-test: Qt/Electron sidebars re-apply their position asynchronously,
        // so an immediate setPosition+read lies to us. Same-PID + subrole/size is a
        // clean signal with no side effects. The "both standard and similar size" case
        // (e.g. two stacked VS Code editors) is explicitly rejected to avoid false
        // positives.
        for info in newWindows where !info.tetherCheckComplete && info.isActualWindow {
            defer { info.tetherCheckComplete = true }

            let f = info.frame
            let selfArea = f.width * f.height

            // Same-PID sibling, at least as large as us, that contains or edge-touches us.
            // When areas are equal (watermark overlaid on main with identical frame),
            // the tie-break is subrole: host must be AXStandardWindow and we must not be,
            // otherwise we'd pair two identical real windows as satellite of each other.
            let host = newWindows.first { other in
                guard other.windowID != info.windowID,
                      other.ownerPID == info.ownerPID,
                      other.isActualWindow
                else { return false }
                let otherArea = other.frame.width * other.frame.height
                if otherArea < selfArea { return false }
                if otherArea == selfArea {
                    guard other.axSubrole == "AXStandardWindow",
                          info.axSubrole != "AXStandardWindow"
                    else { return false }
                }
                return Self.isContainedOrAdjacent(f, host: other.frame)
            }
            guard let host else { continue }
            let hostArea = host.frame.width * host.frame.height

            let nonStandardSub = (info.axSubrole ?? "") != "AXStandardWindow"
            let muchSmaller = selfArea < hostArea * 0.2
            guard nonStandardSub || muchSmaller else {
                logger.warning("TetherCheck: wid=\(info.windowID, privacy: .public) host wid=\(host.windowID, privacy: .public) skipped (both AXStandardWindow, ratio=\(selfArea / hostArea, privacy: .public))")
                continue
            }

            info.isTethered = true
            logger.warning("Tether detected: wid=\(info.windowID, privacy: .public) pid=\(info.ownerPID, privacy: .public) owner=\(info.ownerName, privacy: .public) subrole=\(info.axSubrole ?? "nil", privacy: .public) host=\(host.windowID, privacy: .public) nonStd=\(nonStandardSub, privacy: .public) small=\(muchSmaller, privacy: .public)")
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
            // Prefer isActualWindow windows for initial selection; never pick a tethered satellite.
            mainWindowID = windows.first(where: { $0.isActualWindow && !$0.isTethered })?.windowID
                ?? windows.first(where: { $0.isActualWindow })?.windowID
                ?? windows.first?.windowID
        }

        notifyUpdate()
    }

    private func notifyUpdate() {
        onWindowsUpdated?(windows, mainWindowID)
    }

    // MARK: - Geometry

    /// Whether `inner` is fully contained in `host` (watermark case) or flush against
    /// one of `host`'s edges with its perpendicular extent within host (sidebar/drawer case).
    private static func isContainedOrAdjacent(_ inner: CGRect, host: CGRect, tolerance: CGFloat = 6) -> Bool {
        // Fully contained: inner ⊂ host (with a bit of slop).
        let hostPadded = host.insetBy(dx: -tolerance, dy: -tolerance)
        if hostPadded.contains(inner) {
            return true
        }
        // Edge-adjacent: one of inner's edges touches host's opposite edge, and inner
        // lies within host's span along the perpendicular axis.
        let yOverlap = inner.minY >= host.minY - tolerance && inner.maxY <= host.maxY + tolerance
        let xOverlap = inner.minX >= host.minX - tolerance && inner.maxX <= host.maxX + tolerance
        if yOverlap && abs(inner.minX - host.maxX) < tolerance { return true } // right edge
        if yOverlap && abs(inner.maxX - host.minX) < tolerance { return true } // left edge
        if xOverlap && abs(inner.minY - host.maxY) < tolerance { return true } // bottom edge
        if xOverlap && abs(inner.maxY - host.minY) < tolerance { return true } // top edge
        return false
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
