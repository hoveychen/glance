import AppKit

// MARK: - Split Divider View

/// A draggable divider handle between panels. The hit area is wide for easy
/// grabbing; the visible line is a thin 2px stripe centered inside.
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
        NSColor.white.withAlphaComponent(0.2).setFill()
        let lineW: CGFloat = 2
        let lineRect = CGRect(x: (bounds.width - lineW) / 2, y: 4,
                              width: lineW, height: bounds.height - 8)
        NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1).fill()
    }
}

enum DropHintSide { case left, right }

/// A draggable, resizable frosted-glass "desk" where the main window is placed.
final class WorkAreaWindow: NSWindow {

    var onExit: (() -> Void)?
    var onQuickSwitch: (() -> Void)?
    var onUnpinLeftReference: (() -> Void)?
    var onUnpinRightReference: (() -> Void)?
    /// Called when either split divider is dragged.
    var onSplitRatioChanged: (() -> Void)?

    init(frame: CGRect) {
        super.init(
            contentRect: Self.clampToScreens(frame),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

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

        let label = NSTextField(labelWithString:
            NSLocalizedString("workArea.label",
                              value: "Work Area",
                              comment: "Faint centered label on the work area floating window"))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.3)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -8)
        ])

        let exitButton = NSButton(title:
            NSLocalizedString("workArea.exit",
                              value: "✕ Exit",
                              comment: "Work area bottom-left button: exit/close the work area"),
                                  target: self, action: #selector(exitClicked))
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

        // Unpin-left button (hidden by default) — bottom-left, next to Exit
        unpinLeftButton = NSButton(title:
            NSLocalizedString("workArea.unpinLeft",
                              value: "✕ Unpin Left",
                              comment: "Work area button: unpin the left reference window"),
                                   target: self, action: #selector(unpinLeftClicked))
        unpinLeftButton.bezelStyle = .recessed
        unpinLeftButton.isBordered = false
        unpinLeftButton.font = .systemFont(ofSize: 11, weight: .medium)
        unpinLeftButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        unpinLeftButton.translatesAutoresizingMaskIntoConstraints = false
        unpinLeftButton.isHidden = true
        effectView.addSubview(unpinLeftButton)
        NSLayoutConstraint.activate([
            unpinLeftButton.leadingAnchor.constraint(equalTo: exitButton.trailingAnchor, constant: 12),
            unpinLeftButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        let switchButton = NSButton(title:
            NSLocalizedString("workArea.quickSwitch",
                              value: "⇥ Switch (⌥)",
                              comment: "Work area bottom-right button: quick-switch between windows via Option key"),
                                    target: self, action: #selector(switchClicked))
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

        // Unpin-right button (hidden by default) — bottom-right, left of Switch
        unpinRightButton = NSButton(title:
            NSLocalizedString("workArea.unpinRight",
                              value: "✕ Unpin Right",
                              comment: "Work area button: unpin the right reference window"),
                                    target: self, action: #selector(unpinRightClicked))
        unpinRightButton.bezelStyle = .recessed
        unpinRightButton.isBordered = false
        unpinRightButton.font = .systemFont(ofSize: 11, weight: .medium)
        unpinRightButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        unpinRightButton.translatesAutoresizingMaskIntoConstraints = false
        unpinRightButton.isHidden = true
        effectView.addSubview(unpinRightButton)
        NSLayoutConstraint.activate([
            unpinRightButton.trailingAnchor.constraint(equalTo: switchButton.leadingAnchor, constant: -12),
            unpinRightButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        // Drop hint overlay (hidden by default) — shown while dragging a
        // thumbnail over the work area, so the user sees which half (left/right)
        // the window would pin to on release.
        dropHintView = NSView()
        dropHintView.wantsLayer = true
        dropHintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dropHintView.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        dropHintView.layer?.borderWidth = 2
        dropHintView.layer?.cornerRadius = 10
        dropHintView.isHidden = true
        effectView.addSubview(dropHintView)
        self.effectView = effectView

        // Left divider (hidden by default)
        leftDividerView = SplitDividerView()
        leftDividerView.isHidden = true
        leftDividerView.onDrag = { [weak self] deltaX in
            self?.handleLeftDividerDrag(deltaX: deltaX)
        }
        effectView.addSubview(leftDividerView)

        // Right divider (hidden by default)
        rightDividerView = SplitDividerView()
        rightDividerView.isHidden = true
        rightDividerView.onDrag = { [weak self] deltaX in
            self?.handleRightDividerDrag(deltaX: deltaX)
        }
        effectView.addSubview(rightDividerView)

        minSize = NSSize(width: 400, height: 300)
        self.delegate = self
    }

    // Re-entrancy guard for the delegate clamp path.
    private var isReclamping = false
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

    private var unpinLeftButton: NSButton!
    private var unpinRightButton: NSButton!
    private var leftDividerView: SplitDividerView!
    private var rightDividerView: SplitDividerView!
    private weak var effectView: NSVisualEffectView?
    private var dropHintView: NSView!
    private var dropHintSide: DropHintSide?

    /// Fraction of the available (gap-subtracted) width allocated to the left reference panel.
    /// Only used when `leftReferenceActive == true`. Clamped in `clampRatios()`.
    private(set) var leftSplitRatio: CGFloat = 0.25

    /// Fraction of the available width allocated to the right reference panel.
    /// Only used when `rightReferenceActive == true`.
    private(set) var rightSplitRatio: CGFloat = 0.3

    /// Set both split ratios at once (e.g. when restoring from UserDefaults).
    /// Values are clamped to the allowed range.
    func setSplitRatios(left: CGFloat, right: CGFloat) {
        leftSplitRatio = left
        rightSplitRatio = right
        clampRatios()
        updateDividerPositions()
    }

    var leftReferenceActive: Bool = false {
        didSet {
            unpinLeftButton.isHidden = !leftReferenceActive
            leftDividerView.isHidden = !leftReferenceActive
            clampRatios()
            updateDividerPositions()
        }
    }

    var rightReferenceActive: Bool = false {
        didSet {
            unpinRightButton.isHidden = !rightReferenceActive
            rightDividerView.isHidden = !rightReferenceActive
            clampRatios()
            updateDividerPositions()
        }
    }

    @objc private func exitClicked() { onExit?() }
    @objc private func unpinLeftClicked() { onUnpinLeftReference?() }
    @objc private func unpinRightClicked() { onUnpinRightReference?() }
    @objc private func switchClicked() { onQuickSwitch?() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Padding inside the work area where windows should not cover.
    static let paddingTop: CGFloat = 8
    static let paddingLeft: CGFloat = 8
    static let paddingRight: CGFloat = 8
    static let paddingBottom: CGFloat = 28

    /// Width of the gap between panels (also the divider hit area width).
    /// The visible divider line is a 2px stripe drawn centered inside.
    static let splitGap: CGFloat = 20

    /// Minimum/maximum fraction of available width for a single reference panel.
    private static let minRefRatio: CGFloat = 0.15
    private static let maxRefRatio: CGFloat = 0.5
    /// Main must keep at least this fraction of available width.
    private static let minMainRatio: CGFloat = 0.3

    /// The full frame in CG coordinates (top-left origin).
    var cgFrame: CGRect {
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

    var appKitFrame: CGRect { frame }

    // MARK: - Split Layout

    /// Number of gaps reserved based on which reference sides are active.
    private var activeGapCount: Int {
        (leftReferenceActive ? 1 : 0) + (rightReferenceActive ? 1 : 0)
    }

    /// Width available for the three panels themselves (gaps excluded), in usable-interior space.
    private func availablePanelWidth(usableWidth: CGFloat) -> CGFloat {
        max(0, usableWidth - CGFloat(activeGapCount) * Self.splitGap)
    }

    /// Keep both ratios within bounds and ensure main has enough room.
    private func clampRatios() {
        if leftReferenceActive {
            leftSplitRatio = min(Self.maxRefRatio, max(Self.minRefRatio, leftSplitRatio))
        }
        if rightReferenceActive {
            rightSplitRatio = min(Self.maxRefRatio, max(Self.minRefRatio, rightSplitRatio))
        }
        let left = leftReferenceActive ? leftSplitRatio : 0
        let right = rightReferenceActive ? rightSplitRatio : 0
        let mainShare = 1 - left - right
        if mainShare < Self.minMainRatio {
            // Trim whichever side is larger (or both proportionally) so main is safe.
            let excess = Self.minMainRatio - mainShare
            let total = left + right
            guard total > 0 else { return }
            if leftReferenceActive {
                leftSplitRatio = max(Self.minRefRatio, leftSplitRatio - excess * (left / total))
            }
            if rightReferenceActive {
                rightSplitRatio = max(Self.minRefRatio, rightSplitRatio - excess * (right / total))
            }
        }
    }

    private func handleLeftDividerDrag(deltaX: CGFloat) {
        let usableW = frame.width - Self.paddingLeft - Self.paddingRight
        let available = availablePanelWidth(usableWidth: usableW)
        guard available > 0 else { return }
        leftSplitRatio += deltaX / available
        clampRatios()
        updateDividerPositions()
        onSplitRatioChanged?()
    }

    private func handleRightDividerDrag(deltaX: CGFloat) {
        let usableW = frame.width - Self.paddingLeft - Self.paddingRight
        let available = availablePanelWidth(usableWidth: usableW)
        guard available > 0 else { return }
        // Dragging right divider rightward shrinks the right panel.
        rightSplitRatio -= deltaX / available
        clampRatios()
        updateDividerPositions()
        onSplitRatioChanged?()
    }

    /// Show or hide the drop hint overlay. Pass `nil` to hide.
    func updateDropHint(side: DropHintSide?) {
        dropHintSide = side
        guard let side else {
            dropHintView.isHidden = true
            return
        }
        dropHintView.isHidden = false
        updateDropHintFrame(side: side)
    }

    private func updateDropHintFrame(side: DropHintSide) {
        guard let effectView else { return }
        let inset: CGFloat = 6
        let bounds = effectView.bounds
        let halfW = (bounds.width - inset * 3) / 2
        let y = Self.paddingBottom
        let h = bounds.height - Self.paddingTop - Self.paddingBottom
        let x: CGFloat
        switch side {
        case .left:  x = inset
        case .right: x = inset + halfW + inset
        }
        dropHintView.frame = CGRect(x: x, y: y, width: halfW, height: h)
    }

    private func updateDividerPositions() {
        let usableW = frame.width - Self.paddingLeft - Self.paddingRight
        let available = availablePanelWidth(usableWidth: usableW)
        guard available > 0 else { return }

        let leftW = leftReferenceActive ? available * leftSplitRatio : 0
        let rightW = rightReferenceActive ? available * rightSplitRatio : 0
        let mainW = available - leftW - rightW

        let y = Self.paddingBottom
        let h = frame.height - Self.paddingTop - Self.paddingBottom
        let baseX = Self.paddingLeft

        if leftReferenceActive {
            let x = baseX + leftW
            leftDividerView.frame = CGRect(x: x, y: y, width: Self.splitGap, height: h)
        }
        if rightReferenceActive {
            let leftGap = leftReferenceActive ? Self.splitGap : 0
            let x = baseX + leftW + leftGap + mainW
            rightDividerView.frame = CGRect(x: x, y: y, width: Self.splitGap, height: h)
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.clampToScreens(frameRect), display: flag)
        updateDividerPositions()
        if let side = dropHintSide { updateDropHintFrame(side: side) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

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

    // MARK: - Panel Frames (CG coordinates)

    private struct PanelRects {
        let left: CGRect?
        let main: CGRect
        let right: CGRect?
    }

    private func computePanelRects() -> PanelRects {
        let usable = usableCGFrame
        let available = max(0, usable.width - CGFloat(activeGapCount) * Self.splitGap)
        let leftW = leftReferenceActive ? available * leftSplitRatio : 0
        let rightW = rightReferenceActive ? available * rightSplitRatio : 0
        let mainW = available - leftW - rightW

        var x = usable.origin.x
        var leftRect: CGRect? = nil
        if leftReferenceActive {
            leftRect = CGRect(x: x, y: usable.origin.y, width: leftW, height: usable.height)
            x += leftW + Self.splitGap
        }
        let mainRect = CGRect(x: x, y: usable.origin.y, width: mainW, height: usable.height)
        x += mainW
        var rightRect: CGRect? = nil
        if rightReferenceActive {
            x += Self.splitGap
            rightRect = CGRect(x: x, y: usable.origin.y, width: rightW, height: usable.height)
        }
        return PanelRects(left: leftRect, main: mainRect, right: rightRect)
    }

    /// Main window panel in CG coordinates. Returns full usable area if no refs are pinned.
    func mainPanelCGFrame() -> CGRect { computePanelRects().main }

    /// Left reference panel (valid when `leftReferenceActive`).
    func leftReferencePanelCGFrame() -> CGRect { computePanelRects().left ?? usableCGFrame }

    /// Right reference panel (valid when `rightReferenceActive`).
    func rightReferencePanelCGFrame() -> CGRect { computePanelRects().right ?? usableCGFrame }
}

extension WorkAreaWindow: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { scheduleReclamp() }
    func windowDidResize(_ notification: Notification) { scheduleReclamp() }
    func windowDidChangeScreen(_ notification: Notification) { scheduleReclamp() }
}
