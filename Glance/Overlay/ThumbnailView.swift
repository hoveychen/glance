import AppKit

/// Displays a single window thumbnail in Mission Control style.
final class ThumbnailView: NSView {

    var windowInfo: WindowInfo? {
        didSet { updateLabel() }
    }

    var isActiveWindow: Bool = false {
        didSet { updateActiveOverlay() }
    }

    enum PinnedSide { case none, left, right }

    var pinnedSide: PinnedSide = .none {
        didSet { updatePinnedOverlay() }
    }

    /// Back-compat convenience: true if this window is pinned to either side.
    var isPinnedReference: Bool { pinnedSide != .none }

    var onHoverStart: (() -> Void)?
    var onHoverEnd: (() -> Void)?
    /// Fires when a file/text drag hovers long enough to trigger spring-loading.
    var onSpringLoadActivated: (() -> Void)?
    /// Fires when the pin-left button is clicked.
    var onPinLeftClicked: (() -> Void)?
    /// Fires when the pin-right button is clicked.
    var onPinRightClicked: (() -> Void)?

    private let imageLayer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()
    private let activeOverlay = CALayer()
    private let activeLabel = CATextLayer()
    private let pinnedOverlay = CALayer()
    private let pinnedLabel = CATextLayer()
    private let hintLayer = CATextLayer()
    private let privatePlaceholder = CALayer()
    private let privateLockLabel = CATextLayer()
    private let privateSizeLabel = CATextLayer()
    private var pinLeftButton: NSButton!
    private var pinRightButton: NSButton!
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var springLoadTimer: Timer?
    private var isDragHovering = false

    /// Seconds to hover with a drag before switching the window to the work area.
    private static let springLoadDelay: TimeInterval = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// Must match the layout engine's headerHeight.
    static let headerHeight: CGFloat = 32

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0

        // Accept external file / text drags for spring-loading (hover-to-switch).
        registerForDraggedTypes([
            .fileURL, .URL, .string,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])

        // Thumbnail image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 8
        imageLayer.masksToBounds = true
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.4
        imageLayer.shadowRadius = 4
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(imageLayer)

        // App icon
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.masksToBounds = true
        layer?.addSublayer(iconLayer)

        // Title — white text, no shadow, left-aligned
        labelLayer.fontSize = 13
        labelLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelLayer.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        labelLayer.backgroundColor = NSColor.clear.cgColor
        labelLayer.alignmentMode = .left
        labelLayer.truncationMode = .end
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(labelLayer)

        // Active overlay
        activeOverlay.backgroundColor = NSColor(white: 0.2, alpha: 0.6).cgColor
        activeOverlay.cornerRadius = 8
        activeOverlay.isHidden = true
        layer?.addSublayer(activeOverlay)

        activeLabel.string = "● Active"
        activeLabel.fontSize = 11
        activeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        activeLabel.foregroundColor = NSColor.white.cgColor
        activeLabel.backgroundColor = NSColor.clear.cgColor
        activeLabel.alignmentMode = .center
        activeLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        activeLabel.isHidden = true
        layer?.addSublayer(activeLabel)

        // Pinned overlay
        pinnedOverlay.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.15, blue: 0.3, alpha: 0.5).cgColor
        pinnedOverlay.cornerRadius = 8
        pinnedOverlay.isHidden = true
        layer?.addSublayer(pinnedOverlay)

        pinnedLabel.string = "📌 Pinned"
        pinnedLabel.fontSize = 11
        pinnedLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pinnedLabel.foregroundColor = NSColor.white.cgColor
        pinnedLabel.backgroundColor = NSColor.clear.cgColor
        pinnedLabel.alignmentMode = .center
        pinnedLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        pinnedLabel.isHidden = true
        layer?.addSublayer(pinnedLabel)

        // Pin-left & pin-right buttons (shown on hover, hidden for active window).
        // "rectangle.lefthalf.filled" visually represents pinning to the left slot.
        pinLeftButton = Self.makePinButton(
            symbol: "rectangle.lefthalf.filled",
            accessibility: "Pin as Left Reference",
            target: self, action: #selector(pinLeftButtonClicked)
        )
        addSubview(pinLeftButton)

        pinRightButton = Self.makePinButton(
            symbol: "rectangle.righthalf.filled",
            accessibility: "Pin as Right Reference",
            target: self, action: #selector(pinRightButtonClicked)
        )
        addSubview(pinRightButton)

        // Hint badge
        hintLayer.fontSize = 28
        hintLayer.font = NSFont.monospacedSystemFont(ofSize: 28, weight: .bold)
        hintLayer.foregroundColor = NSColor.white.cgColor
        hintLayer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
        hintLayer.alignmentMode = .center
        hintLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        hintLayer.cornerRadius = 6
        hintLayer.isHidden = true
        layer?.addSublayer(hintLayer)

        // Private browsing placeholder
        privatePlaceholder.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        privatePlaceholder.cornerRadius = 8
        privatePlaceholder.masksToBounds = true
        privatePlaceholder.isHidden = true
        layer?.addSublayer(privatePlaceholder)

        privateLockLabel.string = "🔒 Private"
        privateLockLabel.fontSize = 14
        privateLockLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        privateLockLabel.foregroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        privateLockLabel.backgroundColor = NSColor.clear.cgColor
        privateLockLabel.alignmentMode = .center
        privateLockLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        privateLockLabel.isHidden = true
        layer?.addSublayer(privateLockLabel)

        privateSizeLabel.fontSize = 12
        privateSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        privateSizeLabel.foregroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        privateSizeLabel.backgroundColor = NSColor.clear.cgColor
        privateSizeLabel.alignmentMode = .center
        privateSizeLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        privateSizeLabel.isHidden = true
        layer?.addSublayer(privateSizeLabel)
    }

    @objc private func pinLeftButtonClicked() { onPinLeftClicked?() }
    @objc private func pinRightButtonClicked() { onPinRightClicked?() }

    private static func makePinButton(symbol: String, accessibility: String, target: AnyObject, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: target, action: action)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.isTransparent = false
        (btn.cell as? NSButtonCell)?.backgroundColor = .clear
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .white
        btn.alphaValue = 0
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let hH = Self.headerHeight
        let imageRect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - hH)
        imageLayer.frame = imageRect

        // Icon + label above the image, left-aligned
        let iconSize: CGFloat = 28
        let gap: CGFloat = 6
        let labelH: CGFloat = 16
        let iconY = bounds.height - hH + (hH - iconSize) / 2
        let labelY = bounds.height - hH + (hH - labelH) / 2

        iconLayer.frame = CGRect(x: 0, y: iconY, width: iconSize, height: iconSize)

        // Pin buttons at the right end of the header: [leftPin][rightPin]
        let pinSize: CGFloat = 22
        let pinGap: CGFloat = 2
        let pinRightX = bounds.width - pinSize - 2
        let pinLeftX = pinRightX - pinSize - pinGap
        let pinY = bounds.height - hH + (hH - pinSize) / 2
        pinLeftButton.frame = CGRect(x: pinLeftX, y: pinY, width: pinSize, height: pinSize)
        pinRightButton.frame = CGRect(x: pinRightX, y: pinY, width: pinSize, height: pinSize)

        let totalPinsW = pinSize * 2 + pinGap + 6
        let labelW = bounds.width - iconSize - gap - totalPinsW
        labelLayer.frame = CGRect(x: iconSize + gap, y: labelY, width: labelW, height: labelH)

        // Active / Pinned overlay covers image area
        activeOverlay.frame = imageRect
        activeLabel.frame = CGRect(x: 0, y: (imageRect.height - 16) / 2, width: imageRect.width, height: 16)
        pinnedOverlay.frame = imageRect
        pinnedLabel.frame = CGRect(x: 0, y: (imageRect.height - 16) / 2, width: imageRect.width, height: 16)

        // Hint badge centered on image
        let hintSize: CGFloat = 40
        hintLayer.frame = CGRect(
            x: (bounds.width - hintSize) / 2,
            y: (imageRect.height - hintSize) / 2,
            width: hintSize, height: hintSize
        )

        // Private browsing placeholder covers image area
        privatePlaceholder.frame = imageRect
        let lockH: CGFloat = 18
        let sizeH: CGFloat = 16
        let gap2: CGFloat = 4
        let totalH = lockH + gap2 + sizeH
        let lockY = (imageRect.height - totalH) / 2 + sizeH + gap2
        let sizeY = (imageRect.height - totalH) / 2
        privateLockLabel.frame = CGRect(x: 0, y: lockY, width: imageRect.width, height: lockH)
        privateSizeLabel.frame = CGRect(x: 0, y: sizeY, width: imageRect.width, height: sizeH)

        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        labelLayer.contentsScale = scale
        imageLayer.contentsScale = scale
        activeLabel.contentsScale = scale
        pinnedLabel.contentsScale = scale
        hintLayer.contentsScale = scale
        iconLayer.contentsScale = scale
        privateLockLabel.contentsScale = scale
        privateSizeLabel.contentsScale = scale

        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            if existing.rect == bounds { return }
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        if !isActiveWindow && !isPinnedReference {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            imageLayer.borderColor = NSColor.systemBlue.cgColor
            imageLayer.borderWidth = 3
            CATransaction.commit()
        }
        // Show pin buttons on hover (not for active window)
        if !isActiveWindow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pinLeftButton.animator().alphaValue = 1
                pinRightButton.animator().alphaValue = 1
            }
        }
        onHoverStart?()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if isActiveWindow {
            imageLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else if isPinnedReference {
            imageLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pinLeftButton.animator().alphaValue = 0
            pinRightButton.animator().alphaValue = 0
        }
        onHoverEnd?()
    }

    func updateImage(_ image: CGImage) {
        guard windowInfo?.isPrivateBrowsing != true else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    private func updateLabel() {
        labelLayer.string = windowInfo?.displayName ?? ""
        if let icon = windowInfo?.appIcon {
            iconLayer.contents = icon
        }

        let isPrivate = windowInfo?.isPrivateBrowsing == true
        privatePlaceholder.isHidden = !isPrivate
        privateLockLabel.isHidden = !isPrivate
        privateSizeLabel.isHidden = !isPrivate
        imageLayer.isHidden = isPrivate

        if isPrivate, let info = windowInfo {
            let w = Int(info.frame.width)
            let h = Int(info.frame.height)
            privateSizeLabel.string = "\(w) × \(h)"
        } else if let image = windowInfo?.latestImage {
            imageLayer.contents = image
        }
    }

    func showHint(_ character: String) {
        hintLayer.string = character
        hintLayer.isHidden = false
    }

    func hideHint() {
        hintLayer.isHidden = true
    }

    /// Update the hint badge to indicate pin mode (prepend pin icon).
    func showHintPinIcon() {
        guard !hintLayer.isHidden, let current = hintLayer.string as? String else { return }
        // Avoid double-prepending
        if !current.hasPrefix("📌") {
            hintLayer.string = "📌\(current)"
            // Widen the badge to fit the pin icon
            let wider = hintLayer.frame.width + 34
            hintLayer.frame = CGRect(
                x: (bounds.width - wider) / 2,
                y: hintLayer.frame.origin.y,
                width: wider,
                height: hintLayer.frame.height
            )
        }
    }

    private func updateActiveOverlay() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        activeOverlay.isHidden = !isActiveWindow
        activeLabel.isHidden = !isActiveWindow
        if isActiveWindow {
            imageLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else if !isPinnedReference && !isMouseInside {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
    }

    private func updatePinnedOverlay() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        pinnedOverlay.isHidden = !isPinnedReference
        pinnedLabel.isHidden = !isPinnedReference
        switch pinnedSide {
        case .left:  pinnedLabel.string = "📌 Pinned Left"
        case .right: pinnedLabel.string = "📌 Pinned Right"
        case .none:  pinnedLabel.string = "📌 Pinned"
        }
        if isPinnedReference {
            imageLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else if !isActiveWindow && !isMouseInside {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
    }

    // MARK: - Spring-Loading (Drag Hover to Switch)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // No point spring-loading the window that's already in the work area.
        if isActiveWindow { return [] }
        isDragHovering = true
        showDragHighlight()
        startSpringLoadTimer()
        return .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragHovering ? .generic : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cleanupDragState()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        cleanupDragState()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cleanupDragState()
        return false   // We never accept the drop — the real window will.
    }

    private func startSpringLoadTimer() {
        springLoadTimer?.invalidate()
        // Must add to .common modes — during a drag the run loop is in
        // .eventTracking mode, so a default-mode timer would never fire.
        let timer = Timer(timeInterval: Self.springLoadDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cleanupDragState()
            self.onSpringLoadActivated?()
        }
        RunLoop.current.add(timer, forMode: .common)
        springLoadTimer = timer
    }

    private func cleanupDragState() {
        springLoadTimer?.invalidate()
        springLoadTimer = nil
        guard isDragHovering else { return }
        isDragHovering = false
        hideDragHighlight()
    }

    private func showDragHighlight() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        imageLayer.borderColor = NSColor.systemOrange.cgColor
        imageLayer.borderWidth = 3
        CATransaction.commit()
    }

    private func hideDragHighlight() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if isActiveWindow {
            imageLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else if isMouseInside {
            imageLayer.borderColor = NSColor.systemBlue.cgColor
            imageLayer.borderWidth = 3
        } else {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
    }
}
