import AppKit

/// Tracks all visible windows using CGWindowList and reports changes.
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

    deinit {
        stopTracking()
    }

    func startTracking() {
        // Initial scan
        refreshWindows()

        // Poll every 1 second for window changes
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
    }

    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
    }

    func forceUpdate() {
        refreshWindows()
    }

    func setMainWindow(_ windowID: CGWindowID) {
        mainWindowID = windowID
        notifyUpdate()
    }

    // MARK: - Private

    private func refreshWindows() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return }

        var newWindows: [WindowInfo] = []
        var seenIDs = Set<CGWindowID>()

        for entry in windowList {
            guard let windowID = entry[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = entry[kCGWindowOwnerPID] as? pid_t,
                  let layer = entry[kCGWindowLayer] as? Int,
                  layer == 0  // Normal windows only (not menu bar, dock, etc.)
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

            // Skip tiny windows (likely hidden UI elements)
            if w < 100 || h < 100 { continue }

            let frame = CGRect(x: x, y: y, width: w, height: h)
            let isOnScreen = entry[kCGWindowIsOnscreen] as? Bool ?? true
            seenIDs.insert(windowID)

            // Reuse existing WindowInfo to preserve latestImage
            if let existing = windows.first(where: { $0.windowID == windowID }) {
                existing.title = title
                existing.frame = frame
                existing.isOnScreen = isOnScreen
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
            }
        }

        windows = newWindows

        // Auto-detect main window only if never set.
        // Don't reset to first window if current main temporarily disappears
        // (it might be in transit between work area and virtual display).
        if mainWindowID == nil {
            mainWindowID = windows.first?.windowID
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
