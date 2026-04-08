import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "Onboarding")

extension Notification.Name {
    static let glanceThumbnailClicked = Notification.Name("glanceThumbnailClicked")
    static let glanceOptionKeyPressed = Notification.Name("glanceOptionKeyPressed")
}

/// Manages the first-launch onboarding flow:
/// 1. Permission check (Accessibility + Screen Recording)
/// 2. Interactive step-by-step guidance overlay on top of the real running app
final class OnboardingController: NSObject {

    var onComplete: (() -> Void)?

    // MARK: - Permission Phase

    private var permissionWindow: NSWindow?
    private var permissionTimer: Timer?
    private var accessibilityDot: NSView?
    private var accessibilityStatus: NSTextField?
    private var screenRecordingDot: NSView?
    private var screenRecordingStatus: NSTextField?
    private var continueButton: NSButton?

    // MARK: - Guide Phase

    private static let totalSteps = 4
    private var currentStep = 0
    private var currentCard: NSWindow?
    private var stepObservers: [Any] = []
    private weak var guideWorkArea: WorkAreaWindow?
    private var guideCompletion: (() -> Void)?

    // MARK: - Entry Point

    func start() {
        // Perform a real screen capture attempt so macOS registers this app
        // in the Screen Recording permission list. Without this, the app won't
        // appear in System Settings > Privacy > Screen Recording.
        triggerScreenCaptureRegistration()

        let needsPermissions = !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess()

        if needsPermissions {
            showPermissionPhase()
        } else {
            onComplete?()
        }
    }

    /// Attempt a real screen capture so macOS adds this app to the Screen Recording list.
    /// CGRequestScreenCaptureAccess() alone is not enough — the system only registers the
    /// app after it actually calls a capture API.
    private func triggerScreenCaptureRegistration() {
        let _ = CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )
    }

    // MARK: - Permission Phase

    private func showPermissionPhase() {

        let w: CGFloat = 500, h: CGFloat = 340
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Title
        let title = NSTextField(labelWithString: "Welcome to Glance")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Grant these permissions to get started.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitle)

        // Accessibility row
        let hasA = AXIsProcessTrusted()
        let (aRow, aDot, aStatus) = makePermissionRow(
            name: "Accessibility",
            detail: "Required to move and resize windows",
            granted: hasA,
            action: #selector(openAccessibility)
        )
        aRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(aRow)
        accessibilityDot = aDot
        accessibilityStatus = aStatus

        // Screen Recording row
        let hasSR = CGPreflightScreenCaptureAccess()
        let (sRow, sDot, sStatus) = makePermissionRow(
            name: "Screen Recording",
            detail: "Required to capture window thumbnails",
            granted: hasSR,
            action: #selector(openScreenRecording)
        )
        sRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sRow)
        screenRecordingDot = sDot
        screenRecordingStatus = sStatus

        // Continue button
        let btn = NSButton(title: "Continue", target: self, action: #selector(permissionsContinue))
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.isEnabled = AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
        btn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(btn)
        continueButton = btn

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            aRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 32),
            aRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            aRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            aRow.heightAnchor.constraint(equalToConstant: 52),

            sRow.topAnchor.constraint(equalTo: aRow.bottomAnchor, constant: 12),
            sRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            sRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            sRow.heightAnchor.constraint(equalToConstant: 52),

            btn.topAnchor.constraint(equalTo: sRow.bottomAnchor, constant: 32),
            btn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        win.contentView = root
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow = win

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
    }

    private func makePermissionRow(
        name: String, detail: String, granted: Bool, action: Selector
    ) -> (NSView, NSView, NSTextField) {
        let row = NSView()

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemRed).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(detailLabel)

        let status = NSTextField(labelWithString: granted ? "Granted" : "Not Granted")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = granted ? .systemGreen : .systemOrange
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(status)

        let button = NSButton(title: "Open Settings", target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            status.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return (row, dot, status)
    }

    private func pollPermissions() {
        let hasA = AXIsProcessTrusted()
        let hasSR = CGPreflightScreenCaptureAccess()

        accessibilityDot?.layer?.backgroundColor = (hasA ? NSColor.systemGreen : NSColor.systemRed).cgColor
        accessibilityStatus?.stringValue = hasA ? "Granted" : "Not Granted"
        accessibilityStatus?.textColor = hasA ? .systemGreen : .systemOrange

        screenRecordingDot?.layer?.backgroundColor = (hasSR ? NSColor.systemGreen : NSColor.systemRed).cgColor
        screenRecordingStatus?.stringValue = hasSR ? "Granted" : "Not Granted"
        screenRecordingStatus?.textColor = hasSR ? .systemGreen : .systemOrange

        continueButton?.isEnabled = hasA && hasSR
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func permissionsContinue() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionWindow?.orderOut(nil)
        permissionWindow = nil
        onComplete?()
    }

    // MARK: - Guide Phase (interactive step-by-step overlay)

    /// Show interactive guide steps on top of the real, already-activated app.
    /// Steps advance automatically when the user performs the required action.
    func showGuide(workArea: WorkAreaWindow, completion: @escaping () -> Void) {
        guideWorkArea = workArea
        guideCompletion = completion
        currentStep = 0
        showCurrentStep()
    }

    /// Cancel the guide without marking onboarding as complete (e.g. if the app deactivates).
    func cancelGuide() {
        clearStepObservers()
        if let card = currentCard {
            card.orderOut(nil)
            currentCard = nil
        }
    }

    private func showCurrentStep() {
        guard currentStep < Self.totalSteps, guideWorkArea != nil else {
            completeGuide()
            return
        }

        let (title, message) = stepContent(for: currentStep)
        let card = makeGuideCard(step: currentStep, title: title, message: message)
        currentCard = card
        positionCard(card, for: currentStep)

        card.alphaValue = 0
        card.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            card.animator().alphaValue = 1
        }

        setupDetection(for: currentStep)
    }

    private func stepContent(for step: Int) -> (String, String) {
        switch step {
        case 0: return ("Move the Work Area",
                        "Drag the work area to reposition it.\nTry moving it now!")
        case 1: return ("Resize the Work Area",
                        "Drag any edge of the work area\nto resize it. Try it now!")
        case 2: return ("Switch Windows",
                        "Click any thumbnail around the work area\nto bring that window to the front.")
        case 3: return ("Quick Switch",
                        "Tap the Option key (\u{2325}) to reveal\nkeyboard shortcuts for quick switching.")
        default: return ("", "")
        }
    }

    // MARK: - Card Positioning

    private func positionCard(_ card: NSWindow, for step: Int) {
        guard let wa = guideWorkArea else { return }
        let waFrame = wa.frame
        let cardSize = card.frame.size

        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: waFrame.midX, y: waFrame.midY))
        }) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        switch step {
        case 0, 1:
            // Position outside the work area so user can freely drag/resize it
            let spaceAbove = visible.maxY - waFrame.maxY
            let spaceBelow = waFrame.minY - visible.minY
            let spaceRight = visible.maxX - waFrame.maxX
            let spaceLeft = waFrame.minX - visible.minX

            if spaceAbove >= cardSize.height + 16 {
                card.setFrameOrigin(CGPoint(
                    x: waFrame.midX - cardSize.width / 2,
                    y: waFrame.maxY + 16))
            } else if spaceBelow >= cardSize.height + 16 {
                card.setFrameOrigin(CGPoint(
                    x: waFrame.midX - cardSize.width / 2,
                    y: waFrame.minY - cardSize.height - 16))
            } else if spaceRight >= cardSize.width + 16 {
                card.setFrameOrigin(CGPoint(
                    x: waFrame.maxX + 16,
                    y: waFrame.midY - cardSize.height / 2))
            } else if spaceLeft >= cardSize.width + 16 {
                card.setFrameOrigin(CGPoint(
                    x: waFrame.minX - cardSize.width - 16,
                    y: waFrame.midY - cardSize.height / 2))
            } else {
                // Fallback: top-right corner of the screen
                card.setFrameOrigin(CGPoint(
                    x: visible.maxX - cardSize.width - 16,
                    y: visible.maxY - cardSize.height - 16))
            }

        case 2, 3:
            // Center in the work area (doesn't block thumbnails or keyboard input)
            card.setFrameOrigin(CGPoint(
                x: waFrame.midX - cardSize.width / 2,
                y: waFrame.midY - cardSize.height / 2))

        default:
            break
        }
    }

    // MARK: - Action Detection

    private func setupDetection(for step: Int) {
        guard let wa = guideWorkArea else { return }
        clearStepObservers()

        switch step {
        case 0: // Move work area — detect position change > 20pt
            let initialOrigin = wa.frame.origin
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: wa, queue: .main
            ) { [weak self] _ in
                guard let self, let wa = self.guideWorkArea else { return }
                let dx = abs(wa.frame.origin.x - initialOrigin.x)
                let dy = abs(wa.frame.origin.y - initialOrigin.y)
                if dx > 20 || dy > 20 { self.advanceStep() }
            }
            stepObservers = [obs]

        case 1: // Resize work area — detect size change > 20pt
            let initialSize = wa.frame.size
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: wa, queue: .main
            ) { [weak self] _ in
                guard let self, let wa = self.guideWorkArea else { return }
                let dw = abs(wa.frame.size.width - initialSize.width)
                let dh = abs(wa.frame.size.height - initialSize.height)
                if dw > 20 || dh > 20 { self.advanceStep() }
            }
            stepObservers = [obs]

        case 2: // Click any thumbnail
            let obs = NotificationCenter.default.addObserver(
                forName: .glanceThumbnailClicked, object: nil, queue: .main
            ) { [weak self] _ in self?.advanceStep() }
            stepObservers = [obs]

        case 3: // Tap Option key to enter hint mode
            let obs = NotificationCenter.default.addObserver(
                forName: .glanceOptionKeyPressed, object: nil, queue: .main
            ) { [weak self] _ in self?.advanceStep() }
            stepObservers = [obs]

        default:
            break
        }
    }

    private func clearStepObservers() {
        for obs in stepObservers { NotificationCenter.default.removeObserver(obs) }
        stepObservers.removeAll()
    }

    private func advanceStep() {
        clearStepObservers()

        if let card = currentCard {
            let c = card
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                c.animator().alphaValue = 0
            }, completionHandler: {
                c.orderOut(nil)
            })
            currentCard = nil
        }

        currentStep += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showCurrentStep()
        }
    }

    @objc private func skipStep() {
        advanceStep()
    }

    // MARK: - Guide Card UI

    private func makeGuideCard(step: Int, title: String, message: String) -> NSWindow {
        let card = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        card.isOpaque = false
        card.backgroundColor = .clear
        card.level = .floating
        card.collectionBehavior = [.canJoinAllSpaces, .stationary]
        card.isReleasedWhenClosed = false

        let container = NSVisualEffectView(frame: card.contentView!.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        container.layer?.borderWidth = 1
        container.autoresizingMask = [.width, .height]
        card.contentView?.addSubview(container)

        // Step progress "Step 1 of 4"
        let stepLabel = NSTextField(labelWithString: "Step \(step + 1) of \(Self.totalSteps)")
        stepLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stepLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stepLabel)

        // Badge
        let badge = NSTextField(labelWithString: "\(step + 1)")
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.layer?.cornerRadius = 12
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let msgLabel = NSTextField(wrappingLabelWithString: message)
        msgLabel.font = .systemFont(ofSize: 13)
        msgLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        msgLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(msgLabel)

        // Skip button (subtle, text-only)
        let skipBtn = NSButton(title: "Skip", target: self, action: #selector(skipStep))
        skipBtn.isBordered = false
        skipBtn.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        skipBtn.font = .systemFont(ofSize: 12)
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(skipBtn)

        NSLayoutConstraint.activate([
            stepLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stepLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),

            msgLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            msgLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            msgLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            skipBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            skipBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return card
    }

    // MARK: - Guide Completion

    private func completeGuide() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        clearStepObservers()

        if let card = currentCard {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                card.animator().alphaValue = 0
            }, completionHandler: { [weak card] in
                card?.orderOut(nil)
            })
            currentCard = nil
        }

        guideCompletion?()
    }
}
