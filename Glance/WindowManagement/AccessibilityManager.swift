import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "Accessibility")

// MARK: - Private API: AXUIElement ↔ CGWindowID bridge

/// Returns the CGWindowID for a given AXUIElement window.
/// This is a private SPI that AltTab and other window managers rely on.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// Manages window operations via the macOS Accessibility API.
final class AccessibilityManager {

    static let shared = AccessibilityManager()

    /// Original frames before we moved windows (AppKit coords), keyed by windowID.
    private var originalFrames: [CGWindowID: CGRect] = [:]

    /// The AX position we parked each window at (AX coords: top-left origin).
    private var parkedPositions: [CGWindowID: CGPoint] = [:]

    /// Cached AXUIElement for the window currently in the work area.
    private var activeWorkAreaElement: (windowID: CGWindowID, element: AXUIElement)?

    /// Cache of CGWindowID → AXUIElement, rebuilt per refresh cycle.
    private var axElementCache: [CGWindowID: AXUIElement] = [:]

    private init() {
        // Set global AX messaging timeout to 1 second (default is 6s).
        // Prevents blocking when target apps are unresponsive.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - AX ↔ CG Bridge

    /// Get the CGWindowID for an AXUIElement window.
    func getWindowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &wid)
        return err == .success && wid != 0 ? wid : nil
    }

    /// Build/refresh the CGWindowID → AXUIElement cache for a set of PIDs.
    /// Call this once per refresh cycle before using `findAXWindowByID`.
    func rebuildAXCache(for pids: Set<pid_t>) {
        axElementCache.removeAll(keepingCapacity: true)
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }
            for axWin in axWindows {
                if let wid = getWindowID(for: axWin) {
                    axElementCache[wid] = axWin
                }
            }
        }
    }

    /// Find AXUIElement by CGWindowID using the cache. Falls back to enumeration.
    func findAXWindowByID(_ windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        // Check cache first
        if let cached = axElementCache[windowID] { return cached }

        // Cache miss — enumerate this app's windows
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }
        for axWin in axWindows {
            if let wid = getWindowID(for: axWin) {
                axElementCache[wid] = axWin
                if wid == windowID { return axWin }
            }
        }
        return nil
    }

    // MARK: - AX Attribute Queries

    /// Get the AX role string for a window (e.g. "AXWindow", "AXSheet").
    func getRole(for element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Get the AX subrole string (e.g. "AXStandardWindow", "AXDialog", "AXFloatingWindow").
    func getSubrole(for element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Query AX role and subrole for a window identified by CGWindowID.
    /// Returns (role, subrole), either of which may be nil.
    func getWindowClassification(windowID: CGWindowID, pid: pid_t) -> (role: String?, subrole: String?) {
        guard let axWin = findAXWindowByID(windowID, pid: pid) else {
            return (nil, nil)
        }
        return (getRole(for: axWin), getSubrole(for: axWin))
    }

    // MARK: - Window Activation

    func activateWindow(pid: pid_t, windowTitle: String?) {
        let app = AXUIElementCreateApplication(pid)

        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
        }

        guard let windowTitle, !windowTitle.isEmpty else { return }

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == windowTitle {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                break
            }
        }
    }

    // MARK: - Move to Work Area

    /// Move a window to the work area, scaling down if needed.
    /// Returns the frame actually set (CG coords, top-left origin).
    @discardableResult
    func moveToWorkArea(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect, workAreaCG: CGRect) -> Bool {
        guard let axWin = findAXWindowByID(windowID, pid: pid) ?? findAXWindow(pid: pid, cgFrame: windowFrame) else {
            logger.warning("moveToWorkArea: could not find AX window for \(windowID)")
            return false
        }

        // Save original frame (AppKit coords)
        if originalFrames[windowID] == nil, let currentFrame = getWindowFrameAppKit(axWin) {
            originalFrames[windowID] = currentFrame
        }

        // Calculate target size: fit within work area, preserving aspect ratio
        let winW = windowFrame.width
        let winH = windowFrame.height
        var targetW = winW
        var targetH = winH

        if targetW > workAreaCG.width {
            let scale = workAreaCG.width / targetW
            targetW *= scale
            targetH *= scale
        }
        if targetH > workAreaCG.height {
            let scale = workAreaCG.height / targetH
            targetW *= scale
            targetH *= scale
        }

        // Center in work area (CG coords: top-left origin)
        let targetX = workAreaCG.origin.x + (workAreaCG.width - targetW) / 2
        let targetY = workAreaCG.origin.y + (workAreaCG.height - targetH) / 2

        var position = CGPoint(x: targetX, y: targetY)
        var size = CGSize(width: targetW, height: targetH)

        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeValue)
        }

        // Cache this AX element so we can find it later without frame matching
        activeWorkAreaElement = (windowID: windowID, element: axWin)

        return true
    }

    /// Park the current main window from the work area to the virtual display.
    /// Returns `true` if the window was successfully moved.
    @discardableResult
    func parkMainWindow(windowID: CGWindowID, pid: pid_t, cgFrame: CGRect? = nil) -> Bool {
        let vdm = VirtualDisplayManager.shared
        guard vdm.isActive else { return false }

        // Try cached element first
        var axWin: AXUIElement?
        if let cached = activeWorkAreaElement, cached.windowID == windowID {
            axWin = cached.element
        }

        // Prefer ID-based lookup via _AXUIElementGetWindow bridge
        if axWin == nil {
            axWin = findAXWindowByID(windowID, pid: pid)
        }

        // Fallback: find by frame match
        if axWin == nil, let frame = cgFrame {
            axWin = findAXWindow(pid: pid, cgFrame: frame)
        }

        // Last resort: try focused window of the app
        if axWin == nil {
            let app = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success {
                axWin = (ref as! AXUIElement)
            }
        }

        guard let window = axWin else {
            logger.warning("parkMainWindow: could not find AX window for \(windowID)")
            return false
        }

        // Save original frame if not already saved
        if originalFrames[windowID] == nil, let frame = getWindowFrameAppKit(window) {
            originalFrames[windowID] = frame
        }

        let target = vdm.parkingPosition(for: windowID)
        var position = target
        guard let posValue = AXValueCreate(.cgPoint, &position) else { return false }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        if result != .success {
            logger.warning("parkMainWindow: AX set position failed for \(windowID), error: \(result.rawValue)")
            return false
        }

        // Verify the window actually moved toward the virtual display
        if let newPos = getAXPosition(window), newPos.x < vdm.origin.x - 200 {
            logger.warning("parkMainWindow: window \(windowID) didn't move to VD (pos: \(newPos.x))")
            return false
        }

        parkedPositions[windowID] = target
        activeWorkAreaElement = nil
        return true
    }

    // MARK: - Virtual Display Operations

    /// Move a window to the virtual display. Saves original frame for restoration.
    /// Returns `true` if the window was successfully moved.
    @discardableResult
    func moveToVirtualDisplay(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) -> Bool {
        let vdm = VirtualDisplayManager.shared
        guard vdm.isActive else { return false }

        guard let axWin = findAXWindowByID(windowID, pid: pid) ?? findAXWindow(pid: pid, cgFrame: windowFrame) else {
            logger.warning("moveToVirtualDisplay: could not find AX window for \(windowID) (\(pid))")
            return false
        }

        // Save original frame before moving
        if originalFrames[windowID] == nil, let currentFrame = getWindowFrameAppKit(axWin) {
            originalFrames[windowID] = currentFrame
        }

        // Move to virtual display (AX coordinates: top-left origin)
        let target = vdm.parkingPosition(for: windowID)
        var position = target
        guard let posValue = AXValueCreate(.cgPoint, &position) else { return false }
        let result = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        if result != .success {
            logger.warning("moveToVirtualDisplay: AX set position failed for \(windowID), error: \(result.rawValue)")
            return false
        }

        // Verify the window actually moved toward the virtual display
        if let newPos = getAXPosition(axWin), newPos.x < vdm.origin.x - 200 {
            logger.warning("moveToVirtualDisplay: window \(windowID) didn't move to VD (pos: \(newPos.x), vdOrigin: \(vdm.origin.x))")
            return false
        }

        // Remember where we parked it so we can find it later
        parkedPositions[windowID] = target
        return true
    }

    /// Move a window back from the virtual display to its original position.
    func moveFromVirtualDisplay(windowID: CGWindowID, pid: pid_t) {
        guard let originalFrame = originalFrames[windowID] else {
            logger.warning("moveFromVirtualDisplay: no original frame for \(windowID)")
            return
        }

        // Find the AX window by its parked position
        guard let axWin = findParkedAXWindow(windowID: windowID, pid: pid) else {
            logger.warning("moveFromVirtualDisplay: could not find parked AX window for \(windowID)")
            originalFrames.removeValue(forKey: windowID)
            parkedPositions.removeValue(forKey: windowID)
            return
        }

        // Restore to original position (convert AppKit → AX coords)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let axY = screenHeight - originalFrame.origin.y - originalFrame.height

        var position = CGPoint(x: originalFrame.origin.x, y: axY)
        var size = CGSize(width: originalFrame.width, height: originalFrame.height)

        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeValue)
        }

        originalFrames.removeValue(forKey: windowID)
        parkedPositions.removeValue(forKey: windowID)
    }

    /// Move a parked window to the work area (from virtual display).
    /// If targetFrame is provided (CG coords), use it; otherwise fit original size to work area center.
    @discardableResult
    func moveFromVirtualDisplayToWorkArea(windowID: CGWindowID, pid: pid_t, workAreaCG: CGRect, targetFrame: CGRect?) -> Bool {
        guard let axWin = findParkedAXWindow(windowID: windowID, pid: pid) else {
            logger.warning("moveFromVDToWorkArea: could not find parked AX window for \(windowID)")
            return false
        }

        let frame: CGRect
        if let target = targetFrame {
            frame = target
        } else {
            // Fit original size into work area, centered
            let origFrame = originalFrames[windowID]
            var w = origFrame?.width ?? workAreaCG.width
            var h = origFrame?.height ?? workAreaCG.height

            if w > workAreaCG.width {
                let scale = workAreaCG.width / w
                w *= scale; h *= scale
            }
            if h > workAreaCG.height {
                let scale = workAreaCG.height / h
                w *= scale; h *= scale
            }

            let x = workAreaCG.origin.x + (workAreaCG.width - w) / 2
            let y = workAreaCG.origin.y + (workAreaCG.height - h) / 2
            frame = CGRect(x: x, y: y, width: w, height: h)
        }

        var position = CGPoint(x: frame.origin.x, y: frame.origin.y)
        var size = CGSize(width: frame.width, height: frame.height)

        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeValue)
        }

        parkedPositions.removeValue(forKey: windowID)
        activeWorkAreaElement = (windowID: windowID, element: axWin)

        return true
    }

    /// Get the original (pre-move) frame for a window, in AppKit coords.
    func getOriginalFrame(for windowID: CGWindowID) -> CGRect? {
        originalFrames[windowID]
    }

    /// Get the current CG frame (top-left origin) of the active work area window.
    func getCurrentCGFrame(for windowID: CGWindowID) -> CGRect? {
        guard let cached = activeWorkAreaElement, cached.windowID == windowID else { return nil }
        guard let pos = getAXPosition(cached.element), let size = getAXSize(cached.element) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Constrain a window (by CG frame match) to stay within a target rect.
    /// Used for popup/dialog windows that aren't the cached active work area window.
    func constrainWindow(windowID: CGWindowID, pid: pid_t, cgFrame: CGRect, within targetCG: CGRect) {
        // Only reposition if the window is outside the target area
        let centerX = cgFrame.midX
        let centerY = cgFrame.midY
        let inTarget = targetCG.contains(CGPoint(x: centerX, y: centerY))
        if inTarget && cgFrame.width <= targetCG.width + 1 && cgFrame.height <= targetCG.height + 1 {
            return
        }

        guard let axWin = findAXWindowByID(windowID, pid: pid) ?? findAXWindow(pid: pid, cgFrame: cgFrame) else { return }

        var w = min(cgFrame.width, targetCG.width)
        var h = min(cgFrame.height, targetCG.height)
        var x = targetCG.origin.x + (targetCG.width - w) / 2
        var y = targetCG.origin.y + (targetCG.height - h) / 2

        var position = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        if w < cgFrame.width || h < cgFrame.height {
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeValue)
            }
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        }
    }

    /// Set a window's frame directly (CG coords: top-left origin). Uses cached AX element.
    func setWindowFrame(windowID: CGWindowID, cgFrame: CGRect) {
        guard let cached = activeWorkAreaElement, cached.windowID == windowID else { return }
        var position = CGPoint(x: cgFrame.origin.x, y: cgFrame.origin.y)
        var size = CGSize(width: cgFrame.width, height: cgFrame.height)
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(cached.element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(cached.element, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Clear saved state for a single window.
    func clearWindow(_ windowID: CGWindowID) {
        originalFrames.removeValue(forKey: windowID)
        parkedPositions.removeValue(forKey: windowID)
        if activeWorkAreaElement?.windowID == windowID {
            activeWorkAreaElement = nil
        }
    }

    /// Clear all saved state.
    func clearAll() {
        originalFrames.removeAll()
        parkedPositions.removeAll()
        activeWorkAreaElement = nil
        axElementCache.removeAll()
    }

    // MARK: - Private

    /// Find an AX window that was parked on the virtual display.
    /// Uses the saved parked position for precise matching.
    private func findParkedAXWindow(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        // If we know the exact parked position, match by that
        if let parkedPos = parkedPositions[windowID] {
            for axWin in axWindows {
                let pos = getAXPosition(axWin)
                if let pos, abs(pos.x - parkedPos.x) < 5 && abs(pos.y - parkedPos.y) < 5 {
                    return axWin
                }
            }
        }

        // Fallback: find any window on the virtual display
        let vdOriginX = VirtualDisplayManager.shared.origin.x
        for axWin in axWindows {
            if let pos = getAXPosition(axWin), pos.x >= vdOriginX - 100 {
                return axWin
            }
        }

        return nil
    }

    /// Find an AX window by its CGWindowList frame (CG coords: top-left origin).
    private func findAXWindow(pid: pid_t, cgFrame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        // AX position is also top-left origin, same as CGWindowList
        var bestMatch: AXUIElement?
        var bestDist: CGFloat = .infinity

        for axWin in axWindows {
            guard let pos = getAXPosition(axWin), let size = getAXSize(axWin) else { continue }

            let dx = abs(pos.x - cgFrame.origin.x)
            let dy = abs(pos.y - cgFrame.origin.y)
            let dw = abs(size.width - cgFrame.width)
            let dh = abs(size.height - cgFrame.height)
            let dist = dx + dy + dw + dh

            if dist < bestDist {
                bestDist = dist
                bestMatch = axWin
            }
        }

        // Accept match if reasonably close (within 50px total deviation)
        if bestDist < 50 { return bestMatch }

        // Looser fallback: just position match
        if bestDist < 200 { return bestMatch }

        // Only return the first window if it's the app's sole window.
        // For multi-window apps (e.g. two VS Code windows), returning
        // an arbitrary window is worse than returning nil.
        return axWindows.count == 1 ? axWindows.first : nil
    }

    private func getAXPosition(_ element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(ref as! AXValue, .cgPoint, &point)
        return point
    }

    private func getAXSize(_ element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success else { return nil }
        var size = CGSize.zero
        AXValueGetValue(ref as! AXValue, .cgSize, &size)
        return size
    }

    private func getWindowFrameAppKit(_ window: AXUIElement) -> CGRect? {
        guard let pos = getAXPosition(window), let size = getAXSize(window) else { return nil }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appKitY = screenHeight - pos.y - size.height
        return CGRect(x: pos.x, y: appKitY, width: size.width, height: size.height)
    }
}
