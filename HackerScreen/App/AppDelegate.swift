import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.HackerScreen", category: "App")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayControllers: [Int: OverlayWindowController] = [:]
    private let windowTracker = WindowTracker()
    private let captureManager = WindowCaptureManager()
    private let layoutEngine = MissionControlLayoutEngine()
    private var isActive = false

    /// The current main window ID displayed in the work area.
    private var currentMainWindowID: CGWindowID?

    /// PID of the current main window's app (so we skip its popups/dialogs).
    private var currentMainPID: pid_t?

    /// Window IDs parked on the virtual display.
    private var parkedWindows: Set<CGWindowID> = []

    /// All window IDs we've seen before (to detect newly opened windows).
    private var knownWindowIDs: Set<CGWindowID> = []

    /// Remembered CG frame (top-left origin) for each window when it was last in the work area.
    private var workAreaPositions: [CGWindowID: CGRect] = [:]

    /// Stable ordering of window IDs for layout. New windows are appended.
    private var windowOrder: [CGWindowID] = []

    /// Hover preview state.
    private var hoverTimer: Timer?
    private var hoverWindowID: CGWindowID?
    private var previewWindow: NSWindow?
    private var previewDimWindow: NSWindow?

    /// Quick-switch hint mode state.
    private var isHintMode = false
    private var hintMapping: [String: CGWindowID] = [:]
    private var hintLocalMonitor: Any?
    private var hintGlobalMonitor: Any?

    /// Option short-press detection.
    private var optionDownTimestamp: TimeInterval = 0
    private var optionWasCombined = false

    /// Stack of previously active window IDs (most recent last).
    private var mainWindowStack: [CGWindowID] = []

    /// The frosted-glass work area.
    private var workAreaWindow: WorkAreaWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        if AXIsProcessTrusted() {
            logger.warning("Accessibility: granted.")
        } else {
            logger.warning("Accessibility: NOT granted. Window management will be limited.")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 4 {
                self?.toggleActive()
            }
            // Any key pressed while Option is held → not a short-press
            if self?.optionDownTimestamp != 0 {
                self?.optionWasCombined = true
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 4 {
                self?.toggleActive()
                return nil
            }
            // Any key pressed while Option is held → not a short-press
            if self?.optionDownTimestamp != 0 {
                self?.optionWasCombined = true
            }
            return event
        }

        // Monitor Option key press/release for short-press detection
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        activate()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.grid.3x2", accessibilityDescription: "HackerScreen")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle (\u{2303}\u{2325}H)", action: #selector(toggleActive), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func quitApp() {
        deactivate()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Activation

    private func activate() {
        guard !isActive else { return }
        isActive = true
        logger.warning("Activating HackerScreen layout.")

        VirtualDisplayManager.shared.create()

        // Restore saved work area frame, or create default
        let waFrame: CGRect
        if let saved = UserDefaults.standard.string(forKey: "workAreaFrame"),
           let rect = NSRectFromString(saved) as NSRect?,
           rect.width >= 400, rect.height >= 300 {
            waFrame = rect
        } else {
            let mainScreen = NSScreen.main ?? NSScreen.screens.first!
            let usable = mainScreen.visibleFrame
            let waW = usable.width * 0.55
            let waH = usable.height * 0.60
            let waX = usable.midX - waW / 2
            let waY = usable.midY - waH / 2
            waFrame = CGRect(x: waX, y: waY, width: waW, height: waH)
        }

        let wa = WorkAreaWindow(frame: waFrame)
        wa.onExit = { [weak self] in self?.quitApp() }
        wa.onQuickSwitch = { [weak self] in self?.toggleHintMode() }
        wa.orderFrontRegardless()
        workAreaWindow = wa

        windowTracker.onWindowsUpdated = { [weak self] windows, mainWindowID in
            self?.handleWindowsUpdate(windows: windows, mainWindowID: mainWindowID)
        }
        windowTracker.startTracking()
        createOverlays()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        logger.warning("Deactivating HackerScreen layout.")

        windowTracker.stopTracking()
        captureManager.stopAll()
        exitHintMode()
        cancelHoverPreview()
        destroyOverlays()

        // Save work area frame for next launch
        if let wa = workAreaWindow {
            UserDefaults.standard.set(NSStringFromRect(wa.frame), forKey: "workAreaFrame")
        }

        // Restore main window (it's in work area, not virtual display) to original position
        if let mainID = currentMainWindowID,
           let windows = windowTracker.lastKnownWindows,
           let mainInfo = windows.first(where: { $0.windowID == mainID }) {
            // Park it briefly so moveFromVirtualDisplay can restore it from originalFrames
            AccessibilityManager.shared.parkMainWindow(windowID: mainID, pid: mainInfo.ownerPID)
            AccessibilityManager.shared.moveFromVirtualDisplay(windowID: mainID, pid: mainInfo.ownerPID)
        }

        // Restore all parked windows
        if let windows = windowTracker.lastKnownWindows {
            for windowID in parkedWindows {
                if let info = windows.first(where: { $0.windowID == windowID }) {
                    AccessibilityManager.shared.moveFromVirtualDisplay(windowID: windowID, pid: info.ownerPID)
                }
            }
        }
        parkedWindows.removeAll()
        AccessibilityManager.shared.clearAll()

        workAreaWindow?.orderOut(nil)
        workAreaWindow = nil

        VirtualDisplayManager.shared.destroy()
        currentMainWindowID = nil
    }

    @objc private func toggleActive() {
        if isActive { deactivate() } else { activate() }
    }

    // MARK: - Overlay Management

    private func createOverlays() {
        destroyOverlays()
        for (idx, screen) in NSScreen.screens.enumerated() {
            if screen.localizedName == "HackerScreen" { continue }
            let controller = OverlayWindowController(screen: screen)
            controller.onThumbnailClicked = { [weak self] windowInfo in
                self?.handleThumbnailClick(windowInfo)
            }
            controller.onThumbnailDragMoved = { [weak self] windowID, point in
                self?.handleDragMoved(windowID: windowID, point: point)
            }
            controller.onThumbnailDragComplete = { [weak self] windowID in
                self?.handleDragComplete(windowID: windowID)
            }
            controller.onThumbnailHoverStart = { [weak self] windowID in
                self?.startHoverPreview(windowID: windowID)
            }
            controller.onThumbnailHoverEnd = { [weak self] windowID in
                self?.cancelHoverPreview()
            }
            overlayControllers[idx] = controller
        }
    }

    private func destroyOverlays() {
        for (_, controller) in overlayControllers { controller.hideOverlay() }
        overlayControllers.removeAll()
    }

    @objc private func screensDidChange() {
        if isActive {
            createOverlays()
            VirtualDisplayManager.shared.refreshScreenCoordinates()
            windowTracker.forceUpdate()
        }
    }

    // MARK: - Window Updates

    private func handleWindowsUpdate(windows: [WindowInfo], mainWindowID: CGWindowID?) {
        guard isActive, let wa = workAreaWindow else { return }

        // Use the padded interior for window placement/constraining
        let usableArea = wa.usableCGFrame
        // Use the full frame for layout engine (excluded rect)
        let fullAreaAppKit = wa.appKitFrame

        // Detect newly appeared / disappeared windows
        let currentIDs = Set(windows.map(\.windowID))
        let parkedIDs = parkedWindows  // parked windows won't appear in currentIDs
        let allKnownNow = currentIDs.union(parkedIDs)
        let newWindowIDs = currentIDs.subtracting(knownWindowIDs)
        knownWindowIDs = currentIDs

        // If the current main window was closed, pop from the history stack
        var effectiveMainID = mainWindowID ?? windows.first?.windowID
        if let mainID = currentMainWindowID,
           !allKnownNow.contains(mainID) {
            logger.warning("Main window \(mainID) disappeared, checking stack for fallback")
            // Clean stale IDs from the stack and pop the most recent valid one
            mainWindowStack.removeAll { !allKnownNow.contains($0) }
            parkedWindows.remove(mainID)
            workAreaPositions.removeValue(forKey: mainID)
            AccessibilityManager.shared.clearWindow(mainID)

            if let fallbackID = mainWindowStack.popLast(),
               let fallbackInfo = windows.first(where: { $0.windowID == fallbackID })
                    ?? windowTracker.lastKnownWindows?.first(where: { $0.windowID == fallbackID }) {
                logger.warning("Falling back to: \(fallbackInfo.displayName)")
                effectiveMainID = fallbackID
                windowTracker.setMainWindow(fallbackID)
            }
        }

        // If a genuinely new window appeared (not one we already know about), auto-swap it in
        if effectiveMainID == nil {
            effectiveMainID = mainWindowID ?? windows.first?.windowID
        }
        if let newID = newWindowIDs.first(where: { id in
            // Must not be the current main, must not be already parked, must be a real new window
            id != effectiveMainID && !parkedWindows.contains(id)
        }), let newInfo = windows.first(where: { $0.windowID == newID }) {
            // Skip if it's same PID as current main (popup/dialog)
            if let mainPID = currentMainPID, newInfo.ownerPID == mainPID {
                // Don't auto-swap for popups
            } else {
                // Auto-swap: park current main, make new window the main
                logger.warning("New window detected: \(newInfo.displayName), auto-swapping to work area")

                if let oldID = effectiveMainID {
                    mainWindowStack.append(oldID)
                    if let currentFrame = AccessibilityManager.shared.getCurrentCGFrame(for: oldID) {
                        workAreaPositions[oldID] = currentFrame
                    }
                    if let oldInfo = windows.first(where: { $0.windowID == oldID }) {
                        AccessibilityManager.shared.parkMainWindow(
                            windowID: oldID, pid: oldInfo.ownerPID
                        )
                        parkedWindows.insert(oldID)
                    }
                }
                effectiveMainID = newID
                windowTracker.setMainWindow(newID)
            }
        }

        currentMainWindowID = effectiveMainID
        let mainInfo = windows.first(where: { $0.windowID == effectiveMainID })
        let mainPID = mainInfo?.ownerPID
        currentMainPID = mainPID

        // Determine which screen the work area is on
        let waCenter = CGPoint(x: wa.frame.midX, y: wa.frame.midY)
        let workAreaScreenIndex: Int = {
            for (idx, screen) in NSScreen.screens.enumerated() {
                if screen.frame.contains(waCenter) { return idx }
            }
            return 0
        }()

        // Build screen regions
        var screenRegions: [ScreenRegion] = []
        for (idx, screen) in NSScreen.screens.enumerated() {
            if screen.localizedName == "HackerScreen" { continue }
            let excluded = (idx == workAreaScreenIndex) ? fullAreaAppKit : nil
            screenRegions.append(ScreenRegion(
                screenIndex: idx,
                screenFrame: screen.visibleFrame,
                excludedRect: excluded
            ))
        }

        // Thumbnail candidates: all windows except small same-PID popups.
        // The main window is INCLUDED for layout (placeholder) but not parked.
        let mainArea = (mainInfo?.frame.width ?? 0) * (mainInfo?.frame.height ?? 0)
        let thumbnailInfos = windows.filter { info in
            if let mainPID, info.ownerPID == mainPID, info.windowID != effectiveMainID {
                let area = info.frame.width * info.frame.height
                if area < mainArea * 0.4 { return false }
            }
            return true
        }

        // Maintain stable ordering: keep existing order, append new windows
        let thumbnailIDs = Set(thumbnailInfos.map(\.windowID))
        windowOrder.removeAll { !thumbnailIDs.contains($0) }
        for info in thumbnailInfos where !windowOrder.contains(info.windowID) {
            windowOrder.append(info.windowID)
        }

        // Build metrics in stable order
        let orderedInfos = windowOrder.compactMap { id in thumbnailInfos.first { $0.windowID == id } }
        let metrics = orderedInfos.map { info -> WindowMetrics in
            let frameForRatio: CGRect
            if info.windowID == effectiveMainID,
               let orig = AccessibilityManager.shared.getOriginalFrame(for: info.windowID) {
                frameForRatio = orig
            } else {
                frameForRatio = info.frame
            }
            let ratio: CGFloat = frameForRatio.height > 0
                ? frameForRatio.width / frameForRatio.height
                : 16.0 / 9.0
            return WindowMetrics(
                windowID: info.windowID,
                aspectRatio: ratio,
                originalScreenIndex: info.originalScreenIndex,
                originalHeight: frameForRatio.height
            )
        }

        let slots = layoutEngine.layout(screens: screenRegions, windows: metrics)

        // Park non-main windows to virtual display (skip main window — it's in the work area)
        for (i, info) in thumbnailInfos.enumerated() {
            if info.windowID == effectiveMainID { continue }
            if !parkedWindows.contains(info.windowID) {
                AccessibilityManager.shared.moveToVirtualDisplay(
                    windowID: info.windowID,
                    pid: info.ownerPID,
                    windowFrame: info.frame
                )
                parkedWindows.insert(info.windowID)
            }
        }

        // Move main window into work area
        var justMovedMainWindow = false
        if let mainID = effectiveMainID, let info = mainInfo {
            if parkedWindows.remove(mainID) != nil {
                // Coming from virtual display → check for remembered position
                if let remembered = workAreaPositions[mainID] {
                    let clamped = clampToWorkArea(remembered, workArea: usableArea)
                    AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
                        windowID: mainID, pid: info.ownerPID, workAreaCG: usableArea,
                        targetFrame: clamped
                    )
                } else {
                    AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
                        windowID: mainID, pid: info.ownerPID, workAreaCG: usableArea,
                        targetFrame: nil
                    )
                }
                justMovedMainWindow = true
            } else if AccessibilityManager.shared.getOriginalFrame(for: mainID) == nil {
                // First time → move to work area
                AccessibilityManager.shared.moveToWorkArea(
                    windowID: mainID, pid: info.ownerPID,
                    windowFrame: info.frame, workAreaCG: usableArea
                )
                justMovedMainWindow = true
            }

            // Constrain only if we didn't just move it — give AX API time to settle
            if !justMovedMainWindow {
                constrainMainWindowToWorkArea(windowID: mainID, pid: info.ownerPID, workAreaCG: usableArea)
            }
        }

        // Cache slot centers for drag reordering (slots are already in AppKit coords)
        lastSlotCenters = slots.map { slot in
            (windowID: slot.windowID, center: CGPoint(x: slot.rect.midX, y: slot.rect.midY), screenIndex: slot.screenIndex)
        }

        // Dispatch slots and mark active window
        let slotsByScreen = Dictionary(grouping: slots, by: \.screenIndex)
        for (screenIdx, controller) in overlayControllers {
            controller.activeWindowID = effectiveMainID
            controller.updateSlots(slotsByScreen[screenIdx] ?? [], allWindows: thumbnailInfos)
        }

        // Capture thumbnails (only parked windows, not the main window in work area)
        let captureTargets = thumbnailInfos.filter { $0.windowID != effectiveMainID }
        captureManager.updateCaptures(for: captureTargets) { [weak self] windowID, image in
            guard let self else { return }
            if let info = windows.first(where: { $0.windowID == windowID }) {
                info.latestImage = image
            }
            for (_, controller) in self.overlayControllers {
                controller.thumbnailUpdated(windowID: windowID)
            }
        }
    }

    // MARK: - Interaction

    private func handleThumbnailClick(_ clickedInfo: WindowInfo) {
        guard let wa = workAreaWindow else { return }

        cancelHoverPreview()

        // Clicking the current main window's placeholder — no-op
        if clickedInfo.windowID == currentMainWindowID { return }

        logger.warning("Swapping to window: \(clickedInfo.displayName)")

        let oldMainID = currentMainWindowID
        // Push old main onto the stack for back-navigation
        if let oldID = oldMainID {
            mainWindowStack.append(oldID)
        }
        let usableArea = wa.usableCGFrame

        // Save current main window's position in work area before parking
        if let oldID = oldMainID {
            if let currentFrame = AccessibilityManager.shared.getCurrentCGFrame(for: oldID) {
                workAreaPositions[oldID] = currentFrame
            }
        }

        // Park old main window to virtual display
        if let oldID = oldMainID,
           let windows = windowTracker.lastKnownWindows,
           let oldMainInfo = windows.first(where: { $0.windowID == oldID }) {
            AccessibilityManager.shared.parkMainWindow(
                windowID: oldID,
                pid: oldMainInfo.ownerPID
            )
            parkedWindows.insert(oldID)
        }

        // Bring clicked window from virtual display to work area
        parkedWindows.remove(clickedInfo.windowID)
        let remembered = workAreaPositions[clickedInfo.windowID]
        let target: CGRect? = remembered.map { clampToWorkArea($0, workArea: usableArea) }
        AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
            windowID: clickedInfo.windowID,
            pid: clickedInfo.ownerPID,
            workAreaCG: usableArea,
            targetFrame: target
        )

        // Set new main and activate
        currentMainPID = clickedInfo.ownerPID
        windowTracker.setMainWindow(clickedInfo.windowID)
        AccessibilityManager.shared.activateWindow(pid: clickedInfo.ownerPID, windowTitle: clickedInfo.title)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.windowTracker.forceUpdate()
        }
    }

    // MARK: - Hover Preview

    private func startHoverPreview(windowID: CGWindowID) {
        // Don't preview the active window — it's already in the work area
        if windowID == currentMainWindowID { return }
        // Don't restart if already hovering the same window
        if hoverWindowID == windowID { return }
        cancelHoverPreview()
        hoverWindowID = windowID
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.showHoverPreview()
        }
    }

    private func cancelHoverPreview() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverWindowID = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            previewWindow?.animator().alphaValue = 0
            previewDimWindow?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.previewWindow?.orderOut(nil)
            self?.previewWindow = nil
            self?.previewDimWindow?.orderOut(nil)
            self?.previewDimWindow = nil
        })
    }

    private func showHoverPreview() {
        guard let wa = workAreaWindow,
              let windowID = hoverWindowID,
              let windows = windowTracker.lastKnownWindows,
              let info = windows.first(where: { $0.windowID == windowID }),
              let image = info.latestImage else { return }

        let usable = wa.usableCGFrame
        let primaryH = NSScreen.screens.first?.frame.height ?? 0

        // Dim overlay covering the work area
        let dimFrame = wa.frame
        let dw = NSWindow(contentRect: dimFrame, styleMask: .borderless, backing: .buffered, defer: false)
        dw.isOpaque = false
        dw.backgroundColor = NSColor(white: 0, alpha: 0.5)
        dw.level = .floating
        dw.ignoresMouseEvents = true
        dw.hasShadow = false
        dw.collectionBehavior = [.canJoinAllSpaces, .stationary]
        dw.contentView?.wantsLayer = true
        dw.contentView?.layer?.cornerRadius = 12
        dw.alphaValue = 0
        dw.orderFrontRegardless()
        previewDimWindow = dw

        // Calculate preview size: up to original size, clamped to work area
        let origFrame = AccessibilityManager.shared.getOriginalFrame(for: windowID)
        var imgW = origFrame?.width ?? CGFloat(image.width)
        var imgH = origFrame?.height ?? CGFloat(image.height)

        if imgW > usable.width {
            let scale = usable.width / imgW
            imgW *= scale; imgH *= scale
        }
        if imgH > usable.height {
            let scale = usable.height / imgH
            imgW *= scale; imgH *= scale
        }

        // Center in work area (convert CG → AppKit coords)
        let previewX = usable.origin.x + (usable.width - imgW) / 2
        let previewCGY = usable.origin.y + (usable.height - imgH) / 2
        let previewAppKitY = primaryH - previewCGY - imgH
        let previewFrame = CGRect(x: previewX, y: previewAppKitY, width: imgW, height: imgH)

        let pw = NSWindow(
            contentRect: previewFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        pw.isOpaque = false
        pw.backgroundColor = .clear
        pw.level = .floating
        pw.ignoresMouseEvents = true
        pw.hasShadow = true
        pw.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let imageView = NSImageView(frame: pw.contentView!.bounds)
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        pw.contentView?.addSubview(imageView)

        // Fade in both dim and preview
        pw.alphaValue = 0
        pw.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            dw.animator().alphaValue = 1
            pw.animator().alphaValue = 1
        }

        previewWindow = pw
    }

    // MARK: - Drag Reorder

    /// Tracks the last computed slot centers for insertion-point calculation.
    private var lastSlotCenters: [(windowID: CGWindowID, center: CGPoint, screenIndex: Int)] = []

    private func handleDragMoved(windowID: CGWindowID, point: CGPoint) {
        guard let draggedIdx = windowOrder.firstIndex(of: windowID) else { return }

        // Mark as dragging so controllers skip animating this window
        for (_, controller) in overlayControllers {
            controller.draggingWindowID = windowID
        }

        // Determine which screen the drag point is currently over
        let dragScreenIdx = screenIndex(for: point)

        // Find the closest slot center on the SAME screen as the drag point.
        // This prevents confusing cross-screen shuffles while dragging.
        var bestTargetID: CGWindowID?
        var bestDist: CGFloat = .infinity
        for entry in lastSlotCenters {
            if entry.windowID == windowID { continue }
            if entry.screenIndex != dragScreenIdx { continue }
            let dist = hypot(point.x - entry.center.x, point.y - entry.center.y)
            if dist < bestDist {
                bestDist = dist
                bestTargetID = entry.windowID
            }
        }

        // If hovering over a different slot, swap in the order and relayout others
        if let targetID = bestTargetID,
           let targetIdx = windowOrder.firstIndex(of: targetID),
           targetIdx != draggedIdx {
            windowOrder.swapAt(draggedIdx, targetIdx)
            windowTracker.forceUpdate()
        }
    }

    private func handleDragComplete(windowID: CGWindowID) {
        // Determine which screen the thumbnail was dropped on
        let mouseLocation = NSEvent.mouseLocation  // AppKit coords
        let targetScreen = screenIndex(for: mouseLocation)

        // Update the window's screen assignment so it stays on the new screen
        if let windows = windowTracker.lastKnownWindows,
           let info = windows.first(where: { $0.windowID == windowID }),
           info.originalScreenIndex != targetScreen {
            info.originalScreenIndex = targetScreen
        }

        // Clear dragging state
        for (_, controller) in overlayControllers {
            controller.draggingWindowID = nil
        }
        // Final relayout — the dragged window animates to its new slot
        windowTracker.forceUpdate()
    }

    /// Returns the NSScreen index for a point in AppKit coordinates.
    private func screenIndex(for point: CGPoint) -> Int {
        for (idx, screen) in NSScreen.screens.enumerated() {
            if screen.localizedName == "HackerScreen" { continue }
            if screen.frame.contains(point) { return idx }
        }
        return 0
    }

    // MARK: - Option Short-Press Detection

    private func handleFlagsChanged(_ event: NSEvent) {
        let optionPressed = event.modifierFlags.contains(.option)
        let otherModifiers = event.modifierFlags.intersection([.control, .command, .shift])

        if optionPressed && otherModifiers.isEmpty {
            // Option just pressed (alone)
            if optionDownTimestamp == 0 {
                optionDownTimestamp = event.timestamp
                optionWasCombined = false
            }
        } else if !optionPressed && optionDownTimestamp != 0 {
            // Option just released
            let duration = event.timestamp - optionDownTimestamp
            optionDownTimestamp = 0
            if !optionWasCombined && duration < 0.3 && isActive {
                toggleHintMode()
            }
        } else {
            // Other modifier pressed while Option held → combined
            if optionDownTimestamp != 0 {
                optionWasCombined = true
            }
        }
    }

    // MARK: - Quick Switch (Hint Mode)

    private static let hintKeys: [String] = {
        (1...9).map { String($0) } + (UnicodeScalar("a").value...UnicodeScalar("z").value).map { String(UnicodeScalar($0)!) }
    }()

    private func toggleHintMode() {
        if isHintMode {
            exitHintMode()
        } else {
            enterHintMode()
        }
    }

    private func enterHintMode() {
        guard isActive, !isHintMode else { return }
        isHintMode = true
        hintMapping.removeAll()

        var idx = 0
        for (_, controller) in overlayControllers.sorted(by: { $0.key < $1.key }) {
            let partial = controller.showHints(startIndex: &idx, hintKeys: Self.hintKeys)
            hintMapping.merge(partial) { _, new in new }
        }

        // Listen for key press — both local (when our app is focused) and global (other apps focused)
        hintLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHintKey(event)
            return nil
        }
        hintGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHintKey(event)
        }
    }

    private func exitHintMode() {
        guard isHintMode else { return }
        isHintMode = false
        hintMapping.removeAll()

        for (_, controller) in overlayControllers {
            controller.hideHints()
        }

        if let monitor = hintLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hintLocalMonitor = nil
        }
        if let monitor = hintGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hintGlobalMonitor = nil
        }
    }

    private func handleHintKey(_ event: NSEvent) {
        // Escape → cancel
        if event.keyCode == 53 {
            exitHintMode()
            return
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty else {
            exitHintMode()
            return
        }

        let key = String(chars.prefix(1))
        if let windowID = hintMapping[key],
           let windows = windowTracker.lastKnownWindows,
           let info = windows.first(where: { $0.windowID == windowID }) {
            exitHintMode()
            handleThumbnailClick(info)
        } else {
            exitHintMode()
        }
    }

    // MARK: - Work Area Helpers

    /// Clamp a window frame (CG coords) so it fits within the work area.
    private func clampToWorkArea(_ frame: CGRect, workArea: CGRect) -> CGRect {
        var w = min(frame.width, workArea.width)
        var h = min(frame.height, workArea.height)
        // Preserve aspect ratio if we had to shrink
        if w < frame.width || h < frame.height {
            let scale = min(w / frame.width, h / frame.height)
            w = frame.width * scale
            h = frame.height * scale
        }
        var x = frame.origin.x
        var y = frame.origin.y
        // Push inside work area bounds
        if x < workArea.origin.x { x = workArea.origin.x }
        if y < workArea.origin.y { y = workArea.origin.y }
        if x + w > workArea.maxX { x = workArea.maxX - w }
        if y + h > workArea.maxY { y = workArea.maxY - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Push the main window back inside the work area if it has been dragged/resized outside.
    private func constrainMainWindowToWorkArea(windowID: CGWindowID, pid: pid_t, workAreaCG: CGRect) {
        guard let currentFrame = AccessibilityManager.shared.getCurrentCGFrame(for: windowID) else { return }

        let clamped = clampToWorkArea(currentFrame, workArea: workAreaCG)

        // Only adjust if actually out of bounds
        if abs(clamped.origin.x - currentFrame.origin.x) < 1 &&
           abs(clamped.origin.y - currentFrame.origin.y) < 1 &&
           abs(clamped.width - currentFrame.width) < 1 &&
           abs(clamped.height - currentFrame.height) < 1 {
            return
        }

        AccessibilityManager.shared.setWindowFrame(windowID: windowID, cgFrame: clamped)
    }
}
