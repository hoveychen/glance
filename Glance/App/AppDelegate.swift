import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "App")

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
    /// When true, the next hint key press pins instead of swapping.
    private var isHintPinMode = false
    private var hintMapping: [String: CGWindowID] = [:]
    private var hintLocalMonitor: Any?
    private var hintEventTap: CFMachPort?
    private var hintEventTapSource: CFRunLoopSource?

    /// Option short-press detection.
    private var optionDownTimestamp: TimeInterval = 0
    private var optionWasCombined = false

    /// Stack of previously active window IDs (most recent last).
    private var mainWindowStack: [CGWindowID] = []

    /// Windows manually dragged to a specific screen — exempt from capacity capping.
    private var manualScreenAssignment: Set<CGWindowID> = []

    /// Pinned left reference window (optional, appears on the left of main).
    private var pinnedLeftReferenceWindowID: CGWindowID?
    private var pinnedLeftReferencePID: pid_t?

    /// Pinned right reference window (optional, appears on the right of main).
    private var pinnedRightReferenceWindowID: CGWindowID?
    private var pinnedRightReferencePID: pid_t?

    /// Returns true if this window is pinned as either left or right reference.
    private func isPinnedReference(_ id: CGWindowID) -> Bool {
        id == pinnedLeftReferenceWindowID || id == pinnedRightReferenceWindowID
    }

    /// The frosted-glass work area.
    private var workAreaWindow: WorkAreaWindow?

    /// Onboarding controller (retained during permission phase).
    private var onboardingController: OnboardingController?

    /// Retained during the interactive guide phase (after app is activated).
    private var onboardingGuide: OnboardingController?

    /// Retained NSEvent monitors installed in `setupEventMonitors`, so they can
    /// be removed during termination.
    private var eventMonitorTokens: [Any] = []

    /// Whether a hard-exit watchdog has already been scheduled — avoids arming
    /// multiple watchdogs if the terminate path runs more than once.
    private var terminateWatchdogArmed = false

    /// Periodic diagnostic heartbeat timer. Logs a compact one-line summary of
    /// display / virtual-display / overlay state every 30s so we have history
    /// leading up to any reported bug.
    private var diagnosticTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Check for updates (once per day)
        UpdateChecker.shared.checkIfNeeded()

        // Diagnostic heartbeat runs for the whole process lifetime so we have
        // historical state even while Glance is inactive.
        startDiagnosticTimer()
        logger.warning("launch snapshot:\n\(self.diagnosticSnapshot(), privacy: .public)")

        // Start onboarding if needed, otherwise activate directly
        let onboarding = OnboardingController()
        onboarding.onComplete = { [weak self] in
            guard let self else { return }
            let isFirstLaunch = !UserDefaults.standard.bool(forKey: "onboardingCompleted")
            self.onboardingController = nil  // Clear so activate() proceeds
            self.setupEventMonitors()
            self.activate()

            // Show interactive guide over the real running app on first launch
            if isFirstLaunch, let wa = self.workAreaWindow {
                self.onboardingGuide = onboarding
                onboarding.showGuide(workArea: wa) { [weak self] in
                    self?.onboardingGuide = nil
                }
            }
        }
        onboardingController = onboarding
        onboarding.start()
    }

    private func setupEventMonitors() {
        if let t = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 4 {
                self?.toggleActive()
            }
            if self?.optionDownTimestamp != 0 {
                self?.optionWasCombined = true
            }
        }) {
            eventMonitorTokens.append(t)
        }
        if let t = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 4 {
                self?.toggleActive()
                return nil
            }
            if self?.optionDownTimestamp != 0 {
                self?.optionWasCombined = true
            }
            return event
        }) {
            eventMonitorTokens.append(t)
        }

        if let t = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
        }) {
            eventMonitorTokens.append(t)
        }
        if let t = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }) {
            eventMonitorTokens.append(t)
        }
    }

    private func removeEventMonitors() {
        for token in eventMonitorTokens {
            NSEvent.removeMonitor(token)
        }
        eventMonitorTokens.removeAll()
    }

    /// Schedules a hard `_exit` after `seconds` so the process is guaranteed to
    /// die even if cleanup (AX calls, virtual display teardown) hangs. Safe to
    /// call more than once — only the first arming takes effect.
    private func armTerminateWatchdog(seconds: Double = 2.0) {
        if terminateWatchdogArmed { return }
        terminateWatchdogArmed = true
        logger.warning("Terminate watchdog armed: \(seconds)s")
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + seconds) {
            // Bypass atexit/static-destructors — the whole point is that
            // something in the normal terminate chain is hanging.
            Darwin._exit(0)
        }
    }

    // MARK: - Main Menu Bar

    /// Glance is a regular app (LSUIElement=false) so it shows in the Dock and
    /// needs a top main menu bar when it's the frontmost app. Without this the
    /// top menu bar is empty and users can't reach About / Quit / etc from
    /// there.
    private func setupMainMenu() {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info["CFBundleVersion"] as? String ?? "?"

        let mainMenu = NSMenu()

        // Application menu — macOS automatically renders the first submenu as
        // the "app menu" (the bold one next to the Apple logo) and uses the
        // bundle name as its title regardless of what we set here.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(
            title: "About Glance \(shortVersion) (\(buildNumber))",
            action: #selector(showAbout),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(
            title: "Toggle Glance  \u{2303}\u{2325}H",
            action: #selector(toggleActive),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem(
            title: "Show Guide",
            action: #selector(showGuideAgain),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnostics),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem(
            title: "Dump System Sample…",
            action: #selector(dumpSystemSample),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(
            title: "Hide Glance",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(
            title: "Quit Glance",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.grid.3x2", accessibilityDescription: "Glance")
        }

        // Show the running version directly in the menu item title so users
        // can verify which build they're running without having to click.
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info["CFBundleVersion"] as? String ?? "?"
        let aboutTitle = "About Glance \(shortVersion) (\(buildNumber))"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: aboutTitle, action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle (\u{2303}\u{2325}H)", action: #selector(toggleActive), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Guide", action: #selector(showGuideAgain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dump System Sample…", action: #selector(dumpSystemSample), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkNow()
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info["CFBundleVersion"] as? String ?? "?"

        // Include the executable's modification date so users (and we) can
        // tell at a glance whether the app binary is actually a new build.
        var buildDateStr = "unknown"
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            buildDateStr = df.string(from: modDate)
        }

        let alert = NSAlert()
        alert.messageText = "Glance \(shortVersion) (build \(buildNumber))"
        alert.informativeText = "Built: \(buildDateStr)\nBundle: \(Bundle.main.bundlePath)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        armTerminateWatchdog()
        deactivate()
        removeEventMonitors()
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // This path handles macOS reboot/logout sending us a quit Apple Event
        // without going through `quitApp`. Arm the watchdog unconditionally so
        // Glance can never block system shutdown.
        armTerminateWatchdog()
        if isActive { deactivate() }
        removeEventMonitors()
        return .terminateNow
    }

    @objc private func showGuideAgain() {
        guard isActive, onboardingGuide == nil, let wa = workAreaWindow else { return }
        let guide = OnboardingController()
        onboardingGuide = guide
        guide.showGuide(workArea: wa) { [weak self] in
            self?.onboardingGuide = nil
        }
    }

    // MARK: - Activation

    private func activate() {
        guard !isActive, onboardingController == nil else { return }
        isActive = true
        logger.warning("Activating Glance layout.")
        logger.warning("pre-create snapshot:\n\(self.diagnosticSnapshot(), privacy: .public)")

        if !VirtualDisplayManager.shared.create() {
            logger.error("Failed to create virtual display — cannot activate Glance.")
            isActive = false
            return
        }
        logger.warning("post-create snapshot:\n\(self.diagnosticSnapshot(), privacy: .public)")

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
        // Restore saved split ratios (fall back to defaults baked into WorkAreaWindow).
        let defaults = UserDefaults.standard
        let savedLeft = defaults.object(forKey: "workAreaLeftSplitRatio") as? Double
        let savedRight = defaults.object(forKey: "workAreaRightSplitRatio") as? Double
        if savedLeft != nil || savedRight != nil {
            wa.setSplitRatios(
                left: CGFloat(savedLeft ?? Double(wa.leftSplitRatio)),
                right: CGFloat(savedRight ?? Double(wa.rightSplitRatio))
            )
        }
        wa.onExit = { [weak self] in self?.quitApp() }
        wa.onQuickSwitch = { [weak self] in self?.toggleHintMode() }
        wa.onUnpinLeftReference = { [weak self] in self?.unpinReference(side: .left) }
        wa.onUnpinRightReference = { [weak self] in self?.unpinReference(side: .right) }
        wa.onSplitRatioChanged = { [weak self] in
            guard let self, let wa = self.workAreaWindow else { return }
            UserDefaults.standard.set(Double(wa.leftSplitRatio), forKey: "workAreaLeftSplitRatio")
            UserDefaults.standard.set(Double(wa.rightSplitRatio), forKey: "workAreaRightSplitRatio")
            self.repositionSplitWindows()
        }
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
        logger.warning("Deactivating Glance layout.")

        // Cancel onboarding guide if still showing
        if let guide = onboardingGuide {
            guide.cancelGuide()
            onboardingGuide = nil
        }

        windowTracker.stopTracking()
        captureManager.stopAll()
        exitHintMode()
        cancelHoverPreview()
        destroyOverlays()

        // Save work area frame for next launch
        if let wa = workAreaWindow {
            UserDefaults.standard.set(NSStringFromRect(wa.frame), forKey: "workAreaFrame")
        }

        // Restore pinned reference windows (they're in work area, not virtual display)
        for (refID, refPID) in [
            (pinnedLeftReferenceWindowID, pinnedLeftReferencePID),
            (pinnedRightReferenceWindowID, pinnedRightReferencePID),
        ] {
            if let refID, let refPID {
                AccessibilityManager.shared.parkReferenceWindow(windowID: refID, pid: refPID)
                AccessibilityManager.shared.moveFromVirtualDisplay(windowID: refID, pid: refPID)
            }
        }
        pinnedLeftReferenceWindowID = nil
        pinnedLeftReferencePID = nil
        pinnedRightReferenceWindowID = nil
        pinnedRightReferencePID = nil

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

        logger.warning("pre-destroy snapshot:\n\(self.diagnosticSnapshot(), privacy: .public)")
        VirtualDisplayManager.shared.destroy()
        currentMainWindowID = nil
        logger.warning("post-destroy snapshot:\n\(self.diagnosticSnapshot(), privacy: .public)")
    }

    @objc private func toggleActive() {
        if isActive { deactivate() } else { activate() }
    }

    // MARK: - Overlay Management

    private func createOverlays() {
        destroyOverlays()
        for (idx, screen) in NSScreen.screens.enumerated() {
            if VirtualDisplayManager.shared.isVirtualDisplay(screen) { continue }
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
            controller.onThumbnailDragSpringLoad = { [weak self] windowID in
                self?.handleDragSpringLoad(windowID: windowID)
            }
            controller.onThumbnailPinClicked = { [weak self] windowInfo, side in
                guard let self else { return }
                // Clicking the directional pin on an already-pinned-that-side window = unpin.
                if side == .left && windowInfo.windowID == self.pinnedLeftReferenceWindowID {
                    self.unpinReference(side: .left)
                } else if side == .right && windowInfo.windowID == self.pinnedRightReferenceWindowID {
                    self.unpinReference(side: .right)
                } else {
                    self.pinAsReference(windowInfo, side: side == .left ? .left : .right)
                }
            }
            overlayControllers[idx] = controller
        }
    }

    private func destroyOverlays() {
        for (_, controller) in overlayControllers { controller.hideOverlay() }
        overlayControllers.removeAll()
    }

    @objc private func screensDidChange() {
        logger.warning("screensDidChange:\n\(self.diagnosticSnapshot(), privacy: .public)")
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
        // When any reference is pinned, the main window uses only the middle panel.
        let mainArea = wa.mainPanelCGFrame()
        // Use the full frame for layout engine (excluded rect)
        let fullAreaAppKit = wa.appKitFrame

        // Detect newly appeared / disappeared windows
        let currentIDs = Set(windows.map(\.windowID))
        let parkedIDs = parkedWindows
        var allKnownNow = currentIDs.union(parkedIDs)
        if let refID = pinnedLeftReferenceWindowID { allKnownNow.insert(refID) }
        if let refID = pinnedRightReferenceWindowID { allKnownNow.insert(refID) }
        let newWindowIDs = currentIDs.subtracting(knownWindowIDs)
        knownWindowIDs = currentIDs

        // If a pinned reference window was closed, auto-unpin the corresponding side.
        if let refID = pinnedLeftReferenceWindowID, !currentIDs.contains(refID) && !parkedIDs.contains(refID) {
            logger.warning("Pinned left reference window \(refID) disappeared, unpinning")
            pinnedLeftReferenceWindowID = nil
            pinnedLeftReferencePID = nil
            AccessibilityManager.shared.clearReference(refID)
            wa.leftReferenceActive = false
        }
        if let refID = pinnedRightReferenceWindowID, !currentIDs.contains(refID) && !parkedIDs.contains(refID) {
            logger.warning("Pinned right reference window \(refID) disappeared, unpinning")
            pinnedRightReferenceWindowID = nil
            pinnedRightReferencePID = nil
            AccessibilityManager.shared.clearReference(refID)
            wa.rightReferenceActive = false
        }

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
                // Use silent setter to avoid re-entrant handleWindowsUpdate.
                // The current call will complete with the correct effectiveMainID.
                windowTracker.setMainWindowSilently(fallbackID)
            }
        }

        // If a genuinely new window appeared (not one we already know about), auto-swap it in
        if effectiveMainID == nil {
            effectiveMainID = mainWindowID ?? windows.first?.windowID
        }
        if let newID = newWindowIDs.first(where: { id in
            // Must not be the current main, must not be already parked, must not be a pinned reference
            id != effectiveMainID && !parkedWindows.contains(id) && !isPinnedReference(id)
        }), let newInfo = windows.first(where: { $0.windowID == newID }) {
            // Use AX subrole classification to decide whether to auto-swap.
            // Same-PID windows are held to a stricter standard: ONLY AXStandardWindow
            // triggers auto-swap. This prevents Chrome dropdowns, Save dialogs, sheets,
            // floating panels, and any unclassified popups from stealing the work area.
            // Different-PID windows use the broader isActualWindow check.
            let shouldSkipAutoSwap: Bool = {
                // Non-actual windows → never swap
                if !newInfo.isActualWindow {
                    return true
                }
                // Tethered satellites (sidebars, watermarks) follow a parent — never swap.
                if newInfo.isTethered {
                    return true
                }
                // Same-PID: must be explicitly AXStandardWindow to auto-swap.
                // Dialogs, unknown/nil subrole, and everything else stays in work area.
                if let mainPID = currentMainPID, newInfo.ownerPID == mainPID {
                    if newInfo.axSubrole != "AXStandardWindow" {
                        return true
                    }
                }
                return false
            }()
            if shouldSkipAutoSwap {
                // Don't auto-swap for popups/dialogs/non-actual windows
            } else {
                // Auto-swap: park current main, make new window the main
                logger.warning("New window detected: \(newInfo.displayName), auto-swapping to work area")

                if let oldID = effectiveMainID {
                    mainWindowStack.append(oldID)
                    if let currentFrame = AccessibilityManager.shared.getCurrentCGFrame(for: oldID) {
                        workAreaPositions[oldID] = currentFrame
                    }
                    if let oldInfo = windows.first(where: { $0.windowID == oldID }) {
                        let parked = AccessibilityManager.shared.parkMainWindow(
                            windowID: oldID, pid: oldInfo.ownerPID, cgFrame: oldInfo.frame
                        )
                        if parked {
                            parkedWindows.insert(oldID)
                        } else {
                            logger.warning("Auto-swap: failed to park \(oldInfo.displayName), will retry next cycle")
                        }
                    }
                }
                effectiveMainID = newID
                // Use silent setter to avoid re-entrant handleWindowsUpdate.
                windowTracker.setMainWindowSilently(newID)
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
            if VirtualDisplayManager.shared.isVirtualDisplay(screen) { continue }
            let excluded = (idx == workAreaScreenIndex) ? fullAreaAppKit : nil
            screenRegions.append(ScreenRegion(
                screenIndex: idx,
                screenFrame: screen.visibleFrame,
                excludedRect: excluded
            ))
        }

        // Thumbnail candidates: actual windows only (based on AX subrole classification).
        // Same-PID windows must be AXStandardWindow to get a thumbnail slot.
        // The main window is INCLUDED for layout (placeholder) but not parked.
        let thumbnailInfos = windows.filter { info in
            // Always include the main window and pinned references for layout
            if info.windowID == effectiveMainID { return true }
            if isPinnedReference(info.windowID) { return true }
            // Exclude non-actual windows
            if !info.isActualWindow {
                logger.warning("Thumbnail filter: excluded \(info.ownerName) '\(info.title)' wid=\(info.windowID) reason=notActualWindow level=\(info.windowLevel) subrole=\(info.axSubrole ?? "nil") frame=\(info.frame.width)x\(info.frame.height)")
                return false
            }
            // Exclude tethered satellites — their parent already carries them.
            if info.isTethered {
                logger.warning("Thumbnail filter: excluded \(info.ownerName) '\(info.title)' wid=\(info.windowID) reason=tethered")
                return false
            }
            // Same-PID: only AXStandardWindow gets a thumbnail (not dialogs, popups, etc.)
            if let mainPID, info.ownerPID == mainPID, info.axSubrole != "AXStandardWindow" {
                logger.warning("Thumbnail filter: excluded \(info.ownerName) '\(info.title)' wid=\(info.windowID) reason=samePIDNonStandard subrole=\(info.axSubrole ?? "nil")")
                return false
            }
            return true
        }

        // Maintain stable ordering: keep existing order, insert new windows
        // after the last existing window from the same process (fall back to
        // the end if no sibling exists).
        let thumbnailIDs = Set(thumbnailInfos.map(\.windowID))
        windowOrder.removeAll { !thumbnailIDs.contains($0) }
        let pidByID = Dictionary(uniqueKeysWithValues: thumbnailInfos.map { ($0.windowID, $0.ownerPID) })
        for info in thumbnailInfos where !windowOrder.contains(info.windowID) {
            if let lastSameIdx = windowOrder.lastIndex(where: { pidByID[$0] == info.ownerPID }) {
                windowOrder.insert(info.windowID, at: lastSameIdx + 1)
            } else {
                windowOrder.append(info.windowID)
            }
        }

        // Build metrics in stable order.
        // Use the saved original frame (before parking) for aspect ratio and height,
        // so layout inputs don't fluctuate from virtual-display frame jitter.
        let orderedInfos = windowOrder.compactMap { id in thumbnailInfos.first { $0.windowID == id } }
        let metrics = orderedInfos.map { info -> WindowMetrics in
            let frameForRatio: CGRect
            if info.windowID == effectiveMainID {
                // Active window is in the work area and may have been resized;
                // use its current frame so the thumbnail slot matches the captured image.
                frameForRatio = info.frame
            } else if let orig = AccessibilityManager.shared.getOriginalFrame(for: info.windowID) {
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
                originalHeight: frameForRatio.height,
                isManuallyAssigned: manualScreenAssignment.contains(info.windowID)
            )
        }

        let slots = layoutEngine.layout(screens: screenRegions, windows: metrics)

        // Stabilize distribution: update each window's screen preference to where it
        // was actually placed, so next cycle it stays on the same screen.
        for slot in slots {
            if let info = thumbnailInfos.first(where: { $0.windowID == slot.windowID }) {
                info.originalScreenIndex = slot.screenIndex
            }
        }

        // Self-healing: detect windows marked as parked but actually still on a real screen.
        // This can happen if a prior parkMainWindow call failed silently.
        let vdOriginX = VirtualDisplayManager.shared.origin.x
        for info in windows where info.windowID != effectiveMainID && !isPinnedReference(info.windowID) {
            if parkedWindows.contains(info.windowID) && info.frame.origin.x < vdOriginX - 100 {
                logger.warning("Recovery: window \(info.displayName) (\(info.windowID)) marked parked but on real screen, will re-park")
                parkedWindows.remove(info.windowID)
            }
        }

        // Park non-main windows to virtual display (skip main and pinned reference — they're in the work area)
        for info in thumbnailInfos {
            if info.windowID == effectiveMainID { continue }
            if isPinnedReference(info.windowID) { continue }
            if !parkedWindows.contains(info.windowID) {
                let success = AccessibilityManager.shared.moveToVirtualDisplay(
                    windowID: info.windowID,
                    pid: info.ownerPID,
                    windowFrame: info.frame
                )
                if success {
                    parkedWindows.insert(info.windowID)
                }
            }
        }

        // Move main window into work area (use mainArea which may be the left panel when reference is active)
        var justMovedMainWindow = false
        if let mainID = effectiveMainID, let info = mainInfo {
            if parkedWindows.remove(mainID) != nil {
                // Coming from virtual display → check for remembered position
                if let remembered = workAreaPositions[mainID] {
                    let clamped = clampToWorkArea(remembered, workArea: mainArea)
                    AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
                        windowID: mainID, pid: info.ownerPID, workAreaCG: mainArea,
                        targetFrame: clamped
                    )
                } else {
                    AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
                        windowID: mainID, pid: info.ownerPID, workAreaCG: mainArea,
                        targetFrame: nil
                    )
                }
                justMovedMainWindow = true
            } else if AccessibilityManager.shared.getOriginalFrame(for: mainID) == nil {
                // First time → move to work area
                AccessibilityManager.shared.moveToWorkArea(
                    windowID: mainID, pid: info.ownerPID,
                    windowFrame: info.frame, workAreaCG: mainArea
                )
                justMovedMainWindow = true
            }

            // Constrain only if we didn't just move it — give AX API time to settle
            if !justMovedMainWindow {
                constrainMainWindowToWorkArea(windowID: mainID, pid: info.ownerPID, workAreaCG: mainArea)
            }
        }

        // Constrain same-PID popup/dialog windows into the work area.
        // Uses AX subrole classification: only constrain windows identified as
        // popups/dialogs, plus any same-PID non-actual windows.
        if let mainPID {
            let vdOriginX = VirtualDisplayManager.shared.origin.x
            let thumbnailIDs = Set(thumbnailInfos.map(\.windowID))
            for info in windows where info.ownerPID == mainPID
                && info.windowID != effectiveMainID
                && !parkedWindows.contains(info.windowID)
                && !thumbnailIDs.contains(info.windowID)
                && info.frame.origin.x < vdOriginX - 100 {
                AccessibilityManager.shared.constrainWindow(
                    windowID: info.windowID, pid: info.ownerPID, cgFrame: info.frame, within: usableArea
                )
            }
        }

        // Fill pinned reference windows to their panels each cycle
        if let refID = pinnedLeftReferenceWindowID, let refPID = pinnedLeftReferencePID {
            let refArea = wa.leftReferencePanelCGFrame()
            AccessibilityManager.shared.setReferenceFrame(windowID: refID, pid: refPID, cgFrame: refArea)
        }
        if let refID = pinnedRightReferenceWindowID, let refPID = pinnedRightReferencePID {
            let refArea = wa.rightReferencePanelCGFrame()
            AccessibilityManager.shared.setReferenceFrame(windowID: refID, pid: refPID, cgFrame: refArea)
        }

        // Cache slot rects for drag reordering (slots are already in AppKit coords)
        lastSlotRects = slots.map { slot in
            (windowID: slot.windowID, rect: slot.rect, screenIndex: slot.screenIndex)
        }

        // Cache inputs for the lightweight drag relayout path.
        cachedThumbnailInfos = thumbnailInfos
        cachedScreenRegions = screenRegions

        // Dispatch slots and mark active / pinned windows
        let slotsByScreen = Dictionary(grouping: slots, by: \.screenIndex)
        for (screenIdx, controller) in overlayControllers {
            controller.activeWindowID = effectiveMainID
            controller.pinnedLeftReferenceWindowID = pinnedLeftReferenceWindowID
            controller.pinnedRightReferenceWindowID = pinnedRightReferenceWindowID
            controller.updateSlots(slotsByScreen[screenIdx] ?? [], allWindows: thumbnailInfos)
        }

        // Capture thumbnails (including the active window so its thumbnail stays fresh)
        captureManager.updateCaptures(for: thumbnailInfos) { [weak self] windowID, image in
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
        // Pinned reference windows cannot be swapped into main
        if isPinnedReference(clickedInfo.windowID) { return }

        NotificationCenter.default.post(name: .glanceThumbnailClicked, object: nil)

        logger.warning("Swapping to window: \(clickedInfo.displayName)")

        let oldMainID = currentMainWindowID
        // Push old main onto the stack for back-navigation
        if let oldID = oldMainID {
            mainWindowStack.append(oldID)
        }
        // When any reference is pinned, main uses only the middle panel.
        let mainArea = wa.mainPanelCGFrame()

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
            let parked = AccessibilityManager.shared.parkMainWindow(
                windowID: oldID,
                pid: oldMainInfo.ownerPID,
                cgFrame: oldMainInfo.frame
            )
            if parked {
                parkedWindows.insert(oldID)
            }
        }

        // Bring clicked window from virtual display to work area
        parkedWindows.remove(clickedInfo.windowID)
        let remembered = workAreaPositions[clickedInfo.windowID]
        let target: CGRect? = remembered.map { clampToWorkArea($0, workArea: mainArea) }
        AccessibilityManager.shared.moveFromVirtualDisplayToWorkArea(
            windowID: clickedInfo.windowID,
            pid: clickedInfo.ownerPID,
            workAreaCG: mainArea,
            targetFrame: target
        )

        // Set new main and activate.
        // Use silent setter to avoid triggering handleWindowsUpdate with stale
        // CGWindowList data — the just-parked window's frame hasn't been refreshed yet,
        // so self-healing would incorrectly un-park it and the parking loop could
        // match the wrong same-PID window via findAXWindow.
        currentMainWindowID = clickedInfo.windowID
        currentMainPID = clickedInfo.ownerPID
        windowTracker.setMainWindowSilently(clickedInfo.windowID)

        // Update thumbnail active indicators immediately (layout refreshes on forceUpdate)
        for (_, controller) in overlayControllers {
            controller.activeWindowID = clickedInfo.windowID
        }

        AccessibilityManager.shared.activateWindow(pid: clickedInfo.ownerPID, windowID: clickedInfo.windowID, windowTitle: clickedInfo.title)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.windowTracker.forceUpdate()
        }
    }

    // MARK: - Spring-Loading (Drag to Switch)

    /// An external file/text drag hovered over a thumbnail long enough — switch that window
    /// into the work area so the user can drop onto it.
    private func handleDragSpringLoad(windowID: CGWindowID) {
        guard let windows = windowTracker.lastKnownWindows,
              let info = windows.first(where: { $0.windowID == windowID }) else { return }
        logger.info("Spring-load activated for: \(info.displayName)")
        handleThumbnailClick(info)
    }

    // MARK: - Pin as Reference

    enum ReferenceSide { case left, right }

    private func pinAsReference(_ windowInfo: WindowInfo, side: ReferenceSide) {
        guard let wa = workAreaWindow else { return }
        // Cannot pin the main window as reference
        if windowInfo.windowID == currentMainWindowID { return }

        // If the target is already pinned on the *other* side, unpin that first
        // so it doesn't stay in two places.
        if side == .left, pinnedRightReferenceWindowID == windowInfo.windowID {
            unpinReference(side: .right)
        } else if side == .right, pinnedLeftReferenceWindowID == windowInfo.windowID {
            unpinReference(side: .left)
        }

        // Unpin whatever's currently on the target side.
        if side == .left, pinnedLeftReferenceWindowID != nil {
            unpinReference(side: .left)
        } else if side == .right, pinnedRightReferenceWindowID != nil {
            unpinReference(side: .right)
        }

        // Activate the side on the work area so the panel geometry updates.
        switch side {
        case .left:  wa.leftReferenceActive = true
        case .right: wa.rightReferenceActive = true
        }

        let refArea = side == .left ? wa.leftReferencePanelCGFrame() : wa.rightReferencePanelCGFrame()

        let success = AccessibilityManager.shared.moveFromVirtualDisplayToReferencePanel(
            windowID: windowInfo.windowID,
            pid: windowInfo.ownerPID,
            referencePanelCG: refArea
        )
        guard success else {
            logger.warning("pinAsReference(\(side == .left ? "left" : "right")): failed to move \(windowInfo.displayName)")
            // Roll back side activation if it wasn't already active for a different window.
            switch side {
            case .left:  if pinnedLeftReferenceWindowID == nil { wa.leftReferenceActive = false }
            case .right: if pinnedRightReferenceWindowID == nil { wa.rightReferenceActive = false }
            }
            return
        }

        parkedWindows.remove(windowInfo.windowID)
        switch side {
        case .left:
            pinnedLeftReferenceWindowID = windowInfo.windowID
            pinnedLeftReferencePID = windowInfo.ownerPID
        case .right:
            pinnedRightReferenceWindowID = windowInfo.windowID
            pinnedRightReferencePID = windowInfo.ownerPID
        }

        // Reposition the main window into its (possibly shrunken) middle panel.
        let mainArea = wa.mainPanelCGFrame()
        if let mainID = currentMainWindowID {
            AccessibilityManager.shared.setWindowFrame(windowID: mainID, cgFrame: mainArea)
        }

        logger.warning("Pinned \(windowInfo.displayName) as \(side == .left ? "left" : "right") reference")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.windowTracker.forceUpdate()
        }
    }

    /// Reposition main + any pinned references after the split ratio changes.
    private func repositionSplitWindows() {
        guard let wa = workAreaWindow else { return }
        if let mainID = currentMainWindowID {
            AccessibilityManager.shared.setWindowFrame(windowID: mainID, cgFrame: wa.mainPanelCGFrame())
        }
        if let refID = pinnedLeftReferenceWindowID, let refPID = pinnedLeftReferencePID {
            AccessibilityManager.shared.setReferenceFrame(windowID: refID, pid: refPID, cgFrame: wa.leftReferencePanelCGFrame())
        }
        if let refID = pinnedRightReferenceWindowID, let refPID = pinnedRightReferencePID {
            AccessibilityManager.shared.setReferenceFrame(windowID: refID, pid: refPID, cgFrame: wa.rightReferencePanelCGFrame())
        }
    }

    private func unpinReference(side: ReferenceSide) {
        guard let wa = workAreaWindow else { return }
        let refID: CGWindowID?
        let refPID: pid_t?
        switch side {
        case .left:
            refID = pinnedLeftReferenceWindowID
            refPID = pinnedLeftReferencePID
        case .right:
            refID = pinnedRightReferenceWindowID
            refPID = pinnedRightReferencePID
        }
        guard let refID, let refPID else { return }

        // Park reference window back to virtual display
        let parked = AccessibilityManager.shared.parkReferenceWindow(windowID: refID, pid: refPID)
        if parked {
            parkedWindows.insert(refID)
        }

        switch side {
        case .left:
            pinnedLeftReferenceWindowID = nil
            pinnedLeftReferencePID = nil
            wa.leftReferenceActive = false
        case .right:
            pinnedRightReferenceWindowID = nil
            pinnedRightReferencePID = nil
            wa.rightReferenceActive = false
        }

        // Reposition main to its new (possibly expanded) panel.
        if let mainID = currentMainWindowID {
            AccessibilityManager.shared.setWindowFrame(windowID: mainID, cgFrame: wa.mainPanelCGFrame())
        }

        logger.warning("Unpinned reference window")

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

    /// Tracks the last computed slot rects for insertion-point calculation.
    private var lastSlotRects: [(windowID: CGWindowID, rect: CGRect, screenIndex: Int)] = []

    /// Cached inputs for the lightweight drag relayout path. Refreshed at the
    /// end of `handleWindowsUpdate` so `relayoutForDrag` can re-run the layout
    /// engine without re-enumerating windows or touching AX / capture.
    private var cachedThumbnailInfos: [WindowInfo] = []
    private var cachedScreenRegions: [ScreenRegion] = []

    /// Lightweight relayout used during drag reorder. Re-runs only the layout
    /// engine with cached inputs and dispatches slots, skipping window
    /// enumeration, Space queries, parking/constraint logic, and capture
    /// scheduling — all of which are unchanged during a same-set reorder.
    private func relayoutForDrag() {
        guard isActive, !cachedThumbnailInfos.isEmpty, !cachedScreenRegions.isEmpty else { return }

        let orderedInfos = windowOrder.compactMap { id in
            cachedThumbnailInfos.first { $0.windowID == id }
        }
        let metrics = orderedInfos.map { info -> WindowMetrics in
            let frameForRatio: CGRect
            if info.windowID == currentMainWindowID {
                frameForRatio = info.frame
            } else if let orig = AccessibilityManager.shared.getOriginalFrame(for: info.windowID) {
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
                originalHeight: frameForRatio.height,
                isManuallyAssigned: manualScreenAssignment.contains(info.windowID)
            )
        }

        let slots = layoutEngine.layout(screens: cachedScreenRegions, windows: metrics)

        lastSlotRects = slots.map { slot in
            (windowID: slot.windowID, rect: slot.rect, screenIndex: slot.screenIndex)
        }

        let slotsByScreen = Dictionary(grouping: slots, by: \.screenIndex)
        for (screenIdx, controller) in overlayControllers {
            controller.updateSlots(slotsByScreen[screenIdx] ?? [], allWindows: cachedThumbnailInfos)
        }
    }

    private func handleDragMoved(windowID: CGWindowID, point: CGPoint) {
        guard let draggedIdx = windowOrder.firstIndex(of: windowID) else { return }

        // Mark as dragging so controllers skip animating this window
        for (_, controller) in overlayControllers {
            controller.draggingWindowID = windowID
        }

        // Drop-hint: if the cursor is over the work area, highlight the half
        // (left/right) that a release would pin to. Mirrors the midpoint rule
        // used in handleDragComplete so the hint matches the actual outcome.
        if let wa = workAreaWindow {
            let mouse = NSEvent.mouseLocation
            if wa.frame.contains(mouse) {
                let side: DropHintSide = mouse.x < wa.frame.midX ? .left : .right
                wa.updateDropHint(side: side)
            } else {
                wa.updateDropHint(side: nil)
            }
        }

        // Candidate slots on the SAME screen as the drag point, excluding the
        // dragged window itself. Staying on one screen avoids confusing
        // cross-screen shuffles while dragging.
        let dragScreenIdx = screenIndex(for: point)
        let candidates = lastSlotRects.filter {
            $0.windowID != windowID && $0.screenIndex == dragScreenIdx
        }
        guard !candidates.isEmpty else { return }

        // Pick the slot the pointer is over; otherwise the nearest slot by
        // distance from the point to the rect (clamped to rect edges).
        let target: (windowID: CGWindowID, rect: CGRect, screenIndex: Int) = {
            if let hit = candidates.first(where: { $0.rect.contains(point) }) {
                return hit
            }
            return candidates.min { a, b in
                Self.distance(from: point, to: a.rect) < Self.distance(from: point, to: b.rect)
            }!
        }()

        // Decide whether the insertion gap is before or after the target slot.
        // AppKit y grows upward, so "above the target" (larger y) means earlier
        // in reading order; "below" means later. When the pointer is on the
        // target's row, use the x midpoint.
        let insertBefore: Bool
        if point.y > target.rect.maxY {
            insertBefore = true
        } else if point.y < target.rect.minY {
            insertBefore = false
        } else {
            insertBefore = point.x < target.rect.midX
        }

        guard let targetIdx = windowOrder.firstIndex(of: target.windowID) else { return }

        // Compute the final index after removing the dragged element.
        var desiredIdx = insertBefore ? targetIdx : targetIdx + 1
        if draggedIdx < desiredIdx { desiredIdx -= 1 }

        if desiredIdx == draggedIdx { return }

        let moved = windowOrder.remove(at: draggedIdx)
        windowOrder.insert(moved, at: desiredIdx)
        // Use the lightweight path: during a reorder the window set and screen
        // topology are unchanged, so skip window enumeration / AX / capture and
        // just re-run the layout engine + dispatch slot positions.
        relayoutForDrag()
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func handleDragComplete(windowID: CGWindowID) {
        let mouseLocation = NSEvent.mouseLocation  // AppKit coords
        workAreaWindow?.updateDropHint(side: nil)

        // If dropped on the work area, pin as reference (skip if already pinned or is main).
        // Side is chosen by which half of the work area the drop landed on.
        if let wa = workAreaWindow, wa.frame.contains(mouseLocation),
           windowID != currentMainWindowID,
           !isPinnedReference(windowID) {
            if let windows = windowTracker.lastKnownWindows,
               let info = windows.first(where: { $0.windowID == windowID }) {
                for (_, controller) in overlayControllers {
                    controller.draggingWindowID = nil
                }
                let side: ReferenceSide = mouseLocation.x < wa.frame.midX ? .left : .right
                pinAsReference(info, side: side)
                return
            }
        }

        // Determine which screen the thumbnail was dropped on
        let targetScreen = screenIndex(for: mouseLocation)

        // Update the window's screen assignment so it stays on the new screen
        if let windows = windowTracker.lastKnownWindows,
           let info = windows.first(where: { $0.windowID == windowID }),
           info.originalScreenIndex != targetScreen {
            info.originalScreenIndex = targetScreen
            manualScreenAssignment.insert(windowID)
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
            if VirtualDisplayManager.shared.isVirtualDisplay(screen) { continue }
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
            switchToPreviousWindow()
        } else {
            enterHintMode()
        }
    }

    /// Pop the main-window stack and switch back to the previous window.
    private func switchToPreviousWindow() {
        guard let windows = windowTracker.lastKnownWindows else { return }
        let allKnownNow = Set(windows.map(\.windowID))
        // Clean stale entries and duplicates of the current window
        mainWindowStack.removeAll { !allKnownNow.contains($0) || $0 == currentMainWindowID }

        guard let previousID = mainWindowStack.popLast(),
              let info = windows.first(where: { $0.windowID == previousID }) else {
            return
        }
        handleThumbnailClick(info)
    }

    private func enterHintMode() {
        guard isActive, !isHintMode else { return }
        isHintMode = true
        NotificationCenter.default.post(name: .glanceOptionKeyPressed, object: nil)
        hintMapping.removeAll()

        var idx = 0
        for (_, controller) in overlayControllers.sorted(by: { $0.key < $1.key }) {
            let partial = controller.showHints(startIndex: &idx, hintKeys: Self.hintKeys)
            hintMapping.merge(partial) { _, new in new }
        }

        // Local monitor for when Glance itself is focused
        hintLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHintKey(event)
            return nil  // consume the event
        }

        // CGEvent tap to intercept (not just observe) key events globally.
        // This prevents keystrokes from leaking to the foreground app and
        // bypasses input method interference on non-English systems.
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,       // actively filters (can suppress) events
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                guard delegate.isHintMode else { return Unmanaged.passRetained(event) }
                let nsEvent = NSEvent(cgEvent: event)!
                delegate.handleHintKey(nsEvent)
                return nil  // suppress the event — do not deliver to foreground app
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if let tap {
            hintEventTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            hintEventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func exitHintMode() {
        guard isHintMode else { return }
        isHintMode = false
        isHintPinMode = false
        hintMapping.removeAll()

        for (_, controller) in overlayControllers {
            controller.hideHints()
        }

        if let monitor = hintLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hintLocalMonitor = nil
        }
        if let tap = hintEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = hintEventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                hintEventTapSource = nil
            }
            hintEventTap = nil
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

        // '#' toggles pin sub-mode: next key press pins instead of swapping
        if key == "#" && !isHintPinMode {
            isHintPinMode = true
            // Show pin icons on hint badges
            for (_, controller) in overlayControllers {
                controller.showHintPinMode()
            }
            return
        }

        if let windowID = hintMapping[key],
           let windows = windowTracker.lastKnownWindows,
           let info = windows.first(where: { $0.windowID == windowID }) {
            if isHintPinMode {
                exitHintMode()
                // Hint-pin defaults to right side (matches prior single-side behavior).
                pinAsReference(info, side: .right)
            } else {
                exitHintMode()
                handleThumbnailClick(info)
            }
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
    /// If the window exceeds the work area (e.g. double-click title bar zoom), fill the work area.
    private func constrainMainWindowToWorkArea(windowID: CGWindowID, pid: pid_t, workAreaCG: CGRect) {
        guard let currentFrame = AccessibilityManager.shared.getCurrentCGFrame(for: windowID) else { return }

        let target: CGRect
        if currentFrame.width > workAreaCG.width + 1 || currentFrame.height > workAreaCG.height + 1 {
            // Window exceeds work area (zoom/maximize) → fill work area entirely
            target = workAreaCG
        } else {
            // Just push position back inside, keep size unchanged
            var x = currentFrame.origin.x
            var y = currentFrame.origin.y
            if x < workAreaCG.origin.x { x = workAreaCG.origin.x }
            if y < workAreaCG.origin.y { y = workAreaCG.origin.y }
            if x + currentFrame.width > workAreaCG.maxX { x = workAreaCG.maxX - currentFrame.width }
            if y + currentFrame.height > workAreaCG.maxY { y = workAreaCG.maxY - currentFrame.height }
            target = CGRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height)
        }

        // Only adjust if actually changed
        if abs(target.origin.x - currentFrame.origin.x) < 1 &&
           abs(target.origin.y - currentFrame.origin.y) < 1 &&
           abs(target.width - currentFrame.width) < 1 &&
           abs(target.height - currentFrame.height) < 1 {
            return
        }

        AccessibilityManager.shared.setWindowFrame(windowID: windowID, cgFrame: target)
    }

    // MARK: - Diagnostics

    /// Starts the 30-second diagnostic heartbeat. Safe to call more than once.
    private func startDiagnosticTimer() {
        diagnosticTimer?.invalidate()
        let t = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.logDiagnosticHeartbeat()
        }
        // Add to common modes so it continues to fire during modal UI / menu tracking.
        RunLoop.main.add(t, forMode: .common)
        diagnosticTimer = t
    }

    /// Compact one-line state summary. Goes to os.log every 30s so we have a
    /// historical trail leading up to any reported bug.
    private func logDiagnosticHeartbeat() {
        let vd = VirtualDisplayManager.shared
        let screenCount = NSScreen.screens.count
        let mainID = CGMainDisplayID()
        let vdID = vd.displayID
        let mainWIDStr = currentMainWindowID.map(String.init) ?? "nil"
        let active = isActive ? "1" : "0"
        logger.warning("heartbeat active=\(active, privacy: .public) screens=\(screenCount, privacy: .public) cg_main=\(mainID, privacy: .public) vd_id=\(vdID, privacy: .public) vd_on=\(vd.isActive, privacy: .public) main_wid=\(mainWIDStr, privacy: .public) parked=\(self.parkedWindows.count, privacy: .public) overlays=\(self.overlayControllers.count, privacy: .public)")
    }

    /// Full multi-line diagnostic snapshot suitable for the user to paste into
    /// a bug report. Captures everything we can observe about the display
    /// layout, virtual-display state, and Glance's internal tracking.
    ///
    /// Intentionally has no side effects — safe to call at any time.
    func diagnosticSnapshot() -> String {
        var lines: [String] = []
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        lines.append("=== Glance diagnostic snapshot ===")
        lines.append("time: \(df.string(from: Date()))")
        lines.append("isActive: \(isActive)")
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("version: \(bundleVersion) (\(build))")
        lines.append("")

        // NSScreen state
        lines.append("--- NSScreen.screens (\(NSScreen.screens.count)) ---")
        for (i, s) in NSScreen.screens.enumerated() {
            let name = s.localizedName
            let displayID = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
            let isMain = (s == NSScreen.main) ? " [NSScreen.main]" : ""
            let isVD = VirtualDisplayManager.shared.isVirtualDisplay(s) ? " [glance virtual]" : ""
            let f = s.frame
            let vf = s.visibleFrame
            lines.append(String(format: "  [%d] id=%u \"%@\"%@%@", i, displayID, name, isMain, isVD))
            lines.append(String(format: "      frame=(%.0f,%.0f %.0fx%.0f) visible=(%.0f,%.0f %.0fx%.0f) scale=%.2f",
                                f.origin.x, f.origin.y, f.width, f.height,
                                vf.origin.x, vf.origin.y, vf.width, vf.height,
                                s.backingScaleFactor))
        }
        lines.append("NSScreen.main: \(NSScreen.main?.localizedName ?? "nil")")
        lines.append("CGMainDisplayID(): \(CGMainDisplayID())")
        lines.append("")

        // CG display list — this is independent of AppKit and shows the true
        // state of the display registry as CoreGraphics sees it.
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &onlineIDs, &onlineCount)
        lines.append("--- CG online displays (\(onlineCount)) ---")
        for i in 0..<Int(onlineCount) {
            let id = onlineIDs[i]
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pxW = mode?.pixelWidth ?? 0
            let pxH = mode?.pixelHeight ?? 0
            var flags: [String] = []
            if CGDisplayIsActive(id) != 0 { flags.append("active") }
            if CGDisplayIsAsleep(id) != 0 { flags.append("asleep") }
            if CGDisplayIsMain(id) != 0 { flags.append("main") }
            if CGDisplayIsBuiltin(id) != 0 { flags.append("builtin") }
            if CGDisplayIsInHWMirrorSet(id) != 0 { flags.append("hwMirror") }
            if CGDisplayIsInMirrorSet(id) != 0 { flags.append("mirror") }
            let mirrorOf = CGDisplayMirrorsDisplay(id)
            if mirrorOf != 0 { flags.append("mirrorOf=\(mirrorOf)") }
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            lines.append(String(format: "  id=%u bounds=(%.0f,%.0f %.0fx%.0f) px=%dx%d vendor=0x%x model=0x%x [%@]",
                                id, b.origin.x, b.origin.y, b.width, b.height,
                                pxW, pxH, vendor, model, flags.joined(separator: ",")))
        }
        lines.append("")

        // VirtualDisplayManager state
        let vd = VirtualDisplayManager.shared
        lines.append("--- VirtualDisplayManager ---")
        lines.append("isActive: \(vd.isActive)")
        lines.append("displayID: \(vd.displayID)")
        lines.append(String(format: "origin: (%.0f, %.0f)", vd.origin.x, vd.origin.y))
        lines.append(String(format: "size: %.0fx%.0f", vd.size.width, vd.size.height))
        lines.append("")

        // Glance state
        lines.append("--- Glance state ---")
        lines.append("currentMainWindowID: \(currentMainWindowID.map(String.init) ?? "nil")")
        lines.append("currentMainPID: \(currentMainPID.map(String.init) ?? "nil")")
        lines.append("pinnedLeftReferenceWindowID: \(pinnedLeftReferenceWindowID.map(String.init) ?? "nil")")
        lines.append("pinnedRightReferenceWindowID: \(pinnedRightReferenceWindowID.map(String.init) ?? "nil")")
        lines.append("parkedWindows: \(parkedWindows.count) \(parkedWindows.sorted())")
        lines.append("knownWindowIDs: \(knownWindowIDs.count)")
        lines.append("overlayControllers: \(overlayControllers.count)")
        lines.append("windowOrder: \(windowOrder.count) entries")
        if let wa = workAreaWindow {
            let f = wa.frame
            lines.append(String(format: "workArea: (%.0f,%.0f %.0fx%.0f) visible=\(wa.isVisible)",
                                f.origin.x, f.origin.y, f.width, f.height))
        } else {
            lines.append("workArea: nil")
        }
        lines.append("")
        lines.append("=== end ===")

        return lines.joined(separator: "\n")
    }

    /// Menu-bar action: copies a full diagnostic snapshot to the clipboard and
    /// shows a confirmation so the end user knows it worked. End users paste
    /// the clipboard contents into a bug report.
    @objc private func copyDiagnostics() {
        let snapshot = diagnosticSnapshot()
        // Also log the full snapshot so it lands in Console.app persistently.
        logger.warning("diagnostic snapshot requested:\n\(snapshot, privacy: .public)")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Diagnostics copied to clipboard"
        alert.informativeText = "Paste into the bug report. (\(snapshot.count) characters)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Menu action: capture `sample` output for Glance + relevant system
    /// daemons, so we can diagnose capture-pipeline stalls (e.g. the 64-thread
    /// libdispatch saturation from `SLSWindowListCreateImageProxying`). Runs
    /// out-of-process so it works even while our capture pipeline is hung.
    @objc private func dumpSystemSample() {
        let ts = Self.diagTimestampFormatter.string(from: Date())
        let dirURL = URL(fileURLWithPath: "/tmp/glance-diag-\(ts)")
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            logger.error("dumpSystemSample: mkdir failed: \(error.localizedDescription, privacy: .public)")
            let a = NSAlert()
            a.messageText = "Could not create diagnostic folder"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }

        logger.warning("dumpSystemSample: starting, output=\(dirURL.path, privacy: .public)")

        // The snapshot is instant; write it first so the folder is never empty.
        let snapshotPath = dirURL.appendingPathComponent("diagnostic-snapshot.txt").path
        try? diagnosticSnapshot().write(toFile: snapshotPath, atomically: true, encoding: .utf8)

        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()

            // `sample` writes to `-f` itself; we only need to wait for it.
            // Same-uid processes (Glance, replayd) work without sudo.
            // WindowServer runs as _windowserver so we can't sample it here;
            // users who need that can run `sudo sample WindowServer` manually.
            Self.runTool(
                "/usr/bin/sample",
                ["Glance", "3", "-f", dirURL.appendingPathComponent("glance.txt").path],
                group: group
            )
            Self.runTool(
                "/usr/bin/sample",
                ["replayd", "3", "-f", dirURL.appendingPathComponent("replayd.txt").path],
                group: group
            )
            Self.runTool(
                "/usr/bin/log",
                ["show", "--last", "120s", "--predicate",
                 "subsystem CONTAINS \"ScreenCaptureKit\" OR subsystem CONTAINS \"com.apple.windowserver\" OR process == \"replayd\" OR process == \"WindowServer\""],
                stdoutPath: dirURL.appendingPathComponent("system-log.txt").path,
                group: group
            )

            group.wait()
            logger.warning("dumpSystemSample: finished")

            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([dirURL])
                let alert = NSAlert()
                alert.messageText = "System sample captured"
                alert.informativeText = "Saved to:\n\(dirURL.path)\n\nContents:\n• glance.txt — sample of Glance\n• replayd.txt — sample of ScreenCaptureKit daemon\n• system-log.txt — last 2 min of WindowServer / ScreenCaptureKit log\n• diagnostic-snapshot.txt — Glance internal state\n\nAttach all four files to the bug report."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private static let diagTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Runs a child tool asynchronously on a background queue, optionally
    /// redirecting stdout/stderr to a file. Signals `group` on completion.
    private static func runTool(_ launchPath: String, _ args: [String], stdoutPath: String? = nil, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let p = Process()
            p.launchPath = launchPath
            p.arguments = args
            if let stdoutPath {
                FileManager.default.createFile(atPath: stdoutPath, contents: nil)
                if let fh = FileHandle(forWritingAtPath: stdoutPath) {
                    p.standardOutput = fh
                    p.standardError = fh
                }
            }
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                logger.error("runTool \(launchPath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
