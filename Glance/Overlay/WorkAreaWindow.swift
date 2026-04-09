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
            contentRect: frame,
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
        super.setFrame(frameRect, display: flag)
        if referenceActive { updateDividerPosition() }
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
