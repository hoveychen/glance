import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "Accessibility")

/// Manages window operations via the macOS Accessibility API.
final class AccessibilityManager {

    static let shared = AccessibilityManager()

    /// Original frames before we moved windows (AppKit coords), keyed by windowID.
    private var originalFrames: [CGWindowID: CGRect] = [:]

    /// The AX position we parked each window at (AX coords: top-left origin).
    private var parkedPositions: [CGWindowID: CGPoint] = [:]

    /// Cached AXUIElement for the window currently in the work area.
    private var activeWorkAreaElement: (windowID: CGWindowID, element: AXUIElement)?

    private init() {}

    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
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
        guard let axWin = findAXWindow(pid: pid, cgFrame: windowFrame) else {
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

        // Fallback: find by frame match (more reliable than focused/first window for multi-window apps)
        if axWin == nil, let frame = cgFrame {
            axWin = findAXWindow(pid: pid, cgFrame: frame)
        }

        // Fallback: try focused window of the app
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
    func moveToVirtualDisplay(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) {
        let vdm = VirtualDisplayManager.shared
        guard vdm.isActive else { return }

        guard let axWin = findAXWindow(pid: pid, cgFrame: windowFrame) else {
            logger.warning("moveToVirtualDisplay: could not find AX window for \(windowID) (\(pid))")
            return
        }

        // Save original frame before moving
        if originalFrames[windowID] == nil, let currentFrame = getWindowFrameAppKit(axWin) {
            originalFrames[windowID] = currentFrame
        }

        // Move to virtual display (AX coordinates: top-left origin)
        let target = vdm.parkingPosition(for: windowID)
        var position = target
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
        }

        // Remember where we parked it so we can find it later
        parkedPositions[windowID] = target
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
    func constrainWindow(pid: pid_t, cgFrame: CGRect, within targetCG: CGRect) {
        // Only reposition if the window is outside the target area
        let centerX = cgFrame.midX
        let centerY = cgFrame.midY
        let inTarget = targetCG.contains(CGPoint(x: centerX, y: centerY))
        if inTarget && cgFrame.width <= targetCG.width + 1 && cgFrame.height <= targetCG.height + 1 {
            return
        }

        guard let axWin = findAXWindow(pid: pid, cgFrame: cgFrame) else { return }

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
