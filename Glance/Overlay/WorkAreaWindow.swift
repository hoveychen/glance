import AppKit

// MARK: - Split Divider View

/// A thin draggable divider handle between the main and reference panels.
private final class SplitDividerView: NSView {

    var onDrag: ((CGFloat) -> Void)?  // reports delta-x in points

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    private var dragStartX: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = NSEvent.mouseLocation.x - dragStartX
        dragStartX = NSEvent.mouseLocation.x
        onDrag?(deltaX)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle vertical line
        NSColor.white.withAlphaComponent(0.2).setFill()
        let lineW: CGFloat = 2
        let lineRect = CGRect(x: (bounds.width - lineW) / 2, y: 4,
                              width: lineW, height: bounds.height - 8)
        NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1).fill()
    }
}

/// A draggable, resizable frosted-glass "desk" where the main window is placed.
final class WorkAreaWindow: NSWindow {

    var onExit: (() -> Void)?
    var onQuickSwitch: (() -> Void)?
    var onUnpinReference: (() -> Void)?
    /// Called when the user drags the split divider. Parameter is the new split ratio.
    var onSplitRatioChanged: ((CGFloat) -> Void)?

    init(frame: CGRect) {
        super.init(
            contentRect: Self.clampToScreens(frame),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)  // Below all normal windows
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Frosted glass effect
        let effectView = NSVisualEffectView(frame: contentView!.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effectView.layer?.borderWidth = 1
        effectView.autoresizingMask = [.width, .height]
        contentView?.addSubview(effectView)

        // Subtle label
        let label = NSTextField(labelWithString: "Work Area")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.3)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -8)
        ])

        // Exit button in bottom-left
        let exitButton = NSButton(title: "✕ Exit", target: self, action: #selector(exitClicked))
        exitButton.bezelStyle = .recessed
        exitButton.isBordered = false
        exitButton.font = .systemFont(ofSize: 11, weight: .medium)
        exitButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            exitButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        // Quick-switch button in bottom-right
        let switchButton = NSButton(title: "⇥ Switch (⌥)", target: self, action: #selector(switchClicked))
        switchButton.bezelStyle = .recessed
        switchButton.isBordered = false
        switchButton.font = .systemFont(ofSize: 11, weight: .medium)
        switchButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(switchButton)
        NSLayoutConstraint.activate([
            switchButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            switchButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        // Unpin reference button (hidden by default)
        unpinButton = NSButton(title: "✕ Unpin Ref", target: self, action: #selector(unpinClicked))
        unpinButton.bezelStyle = .recessed
        unpinButton.isBordered = false
        unpinButton.font = .systemFont(ofSize: 11, weight: .medium)
        unpinButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        unpinButton.translatesAutoresizingMaskIntoConstraints = false
        unpinButton.isHidden = true
        effectView.addSubview(unpinButton)
        NSLayoutConstraint.activate([
            unpinButton.trailingAnchor.constraint(equalTo: switchButton.leadingAnchor, constant: -12),
            unpinButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        // Split divider (hidden by default)
        dividerView = SplitDividerView()
        dividerView.isHidden = true
        dividerView.onDrag = { [weak self] deltaX in
            self?.handleDividerDrag(deltaX: deltaX)
        }
        effectView.addSubview(dividerView)

        minSize = NSSize(width: 400, height: 300)
        self.delegate = self
    }

    // Re-entrancy guard for the delegate clamp path.
    private var isReclamping = false
    // Debounce timer so we only clamp once the user stops dragging/resizing.
    private var settleTimer: Timer?
    private static let settleInterval: TimeInterval = 0.15

    private func scheduleReclamp() {
        guard !isReclamping else { return }
        settleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.settleInterval, repeats: false) { [weak self] _ in
            self?.reclampNow()
        }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    private func reclampNow() {
        let clamped = Self.clampToScreens(frame)
        guard clamped != frame else { return }
        isReclamping = true
        setFrame(clamped, display: true, animate: false)
        isReclamping = false
    }

    private var unpinButton: NSButton!
    private var dividerView: SplitDividerView!

    /// The current split ratio (fraction of usable width for the main window).
    /// Clamped to [0.3, 0.8] to prevent either panel from becoming too small.
    var splitRatio: CGFloat = 0.6

    /// Whether a reference window is currently pinned.
    var referenceActive: Bool = false {
        didSet {
            unpinButton.isHidden = !referenceActive
            dividerView.isHidden = !referenceActive
            if referenceActive {
                updateDividerPosition()
            }
        }
    }

    @objc private func exitClicked() {
        onExit?()
    }

    @objc private func unpinClicked() {
        onUnpinReference?()
    }

    @objc private func switchClicked() {
        onQuickSwitch?()
    }

    // Allow becoming key so it can be resized, but not main
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Padding inside the work area where the main window should not cover.
    static let paddingTop: CGFloat = 8
    static let paddingLeft: CGFloat = 8
    static let paddingRight: CGFloat = 8
    static let paddingBottom: CGFloat = 28  // Room for "Work Area" label

    /// The full frame in CG coordinates (top-left origin).
    var cgFrame: CGRect {
        // Must use primary screen height for CG↔AppKit conversion (both coordinate
        // systems are anchored to the primary screen). NSScreen.main returns the
        // screen with keyboard focus, which is wrong when the work area is on a
        // secondary display.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: frame.origin.x,
            y: primaryH - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// The usable interior in CG coordinates (top-left origin), inset by padding.
    var usableCGFrame: CGRect {
        let full = cgFrame
        return CGRect(
            x: full.origin.x + Self.paddingLeft,
            y: full.origin.y + Self.paddingTop,
            width: full.width - Self.paddingLeft - Self.paddingRight,
            height: full.height - Self.paddingTop - Self.paddingBottom
        )
    }

    /// The frame in AppKit coordinates (bottom-left origin).
    var appKitFrame: CGRect { frame }

    // MARK: - Split Divider

    private func handleDividerDrag(deltaX: CGFloat) {
        let usableW = frame.width - Self.paddingLeft - Self.paddingRight
        guard usableW > 0 else { return }
        let ratioDelta = deltaX / usableW
        splitRatio = min(0.8, max(0.3, splitRatio + ratioDelta))
        updateDividerPosition()
        onSplitRatioChanged?(splitRatio)
    }

    private func updateDividerPosition() {
        let usableW = frame.width - Self.paddingLeft - Self.paddingRight
        let dividerW: CGFloat = Self.splitGap
        let dividerX = Self.paddingLeft + (usableW - dividerW) * splitRatio
        let dividerY = Self.paddingBottom
        let dividerH = frame.height - Self.paddingTop - Self.paddingBottom
        dividerView.frame = CGRect(x: dividerX, y: dividerY, width: dividerW, height: dividerH)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.clampToScreens(frameRect), display: flag)
        if referenceActive { updateDividerPosition() }
    }

    /// AppKit calls this during user-initiated drag/resize. Keep the work area
    /// fully on one screen with a margin — otherwise the reference/main panels
    /// computed from this frame end up off-screen, macOS AX clamps the external
    /// app windows placed there, and the next layout cycle sets them again →
    /// continuous flicker.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Intentionally return the frame unchanged during user-initiated
        // drag/resize. Clamping here (even by the frame's own center) fights
        // slow cross-screen drags: whenever an edge pokes off the current
        // screen, AppKit snaps it back before the center crosses the boundary.
        // Instead we clamp on drag-end via `windowDidMove` + settle timer.
        frameRect
    }

    /// Margin between the work-area edge and the target screen's visible frame.
    static let screenMargin: CGFloat = 12

    static func clampToScreens(_ frameRect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frameRect }

        let center = CGPoint(x: frameRect.midX, y: frameRect.midY)
        let target: NSScreen = screens.first(where: { $0.frame.contains(center) })
            ?? screens.min(by: { distanceSquared(from: center, to: $0.frame)
                              < distanceSquared(from: center, to: $1.frame) })
            ?? screens[0]

        let bounds = target.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard bounds.width > 0, bounds.height > 0 else { return frameRect }

        var result = frameRect
        result.size.width = min(result.size.width, bounds.width)
        result.size.height = min(result.size.height, bounds.height)
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        return result
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    // MARK: - Split Layout (Reference Mode)

    private static let splitGap: CGFloat = 8

    /// Left panel for the main window when a reference is pinned (CG coordinates).
    func mainPanelCGFrame(splitRatio: CGFloat) -> CGRect {
        let usable = usableCGFrame
        let mainW = (usable.width - Self.splitGap) * splitRatio
        return CGRect(x: usable.origin.x, y: usable.origin.y,
                      width: mainW, height: usable.height)
    }

    /// Right panel for the reference window (CG coordinates).
    func referencePanelCGFrame(splitRatio: CGFloat) -> CGRect {
        let usable = usableCGFrame
        let mainW = (usable.width - Self.splitGap) * splitRatio
        let refX = usable.origin.x + mainW + Self.splitGap
        let refW = usable.width - mainW - Self.splitGap
        return CGRect(x: refX, y: usable.origin.y,
                      width: refW, height: usable.height)
    }
}

extension WorkAreaWindow: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { scheduleReclamp() }
    func windowDidResize(_ notification: Notification) { scheduleReclamp() }
    func windowDidChangeScreen(_ notification: Notification) { scheduleReclamp() }
}
