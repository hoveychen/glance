import AppKit

/// Displays a single window thumbnail in Mission Control style.
final class ThumbnailView: NSView {

    var windowInfo: WindowInfo? {
        didSet { updateLabel() }
    }

    var isActiveWindow: Bool = false {
        didSet { updateActiveOverlay() }
    }

    var onHoverStart: (() -> Void)?
    var onHoverEnd: (() -> Void)?

    private let imageLayer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()
    private let activeOverlay = CALayer()
    private let activeLabel = CATextLayer()
    private let hintLayer = CATextLayer()
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false

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
        labelLayer.frame = CGRect(x: iconSize + gap, y: labelY, width: bounds.width - iconSize - gap, height: labelH)

        // Active overlay covers image area
        activeOverlay.frame = imageRect
        activeLabel.frame = CGRect(x: 0, y: (imageRect.height - 16) / 2, width: imageRect.width, height: 16)

        // Hint badge centered on image
        let hintSize: CGFloat = 40
        hintLayer.frame = CGRect(
            x: (bounds.width - hintSize) / 2,
            y: (imageRect.height - hintSize) / 2,
            width: hintSize, height: hintSize
        )

        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        labelLayer.contentsScale = scale
        imageLayer.contentsScale = scale
        activeLabel.contentsScale = scale
        hintLayer.contentsScale = scale
        iconLayer.contentsScale = scale

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
        if !isActiveWindow {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            imageLayer.borderColor = NSColor.systemBlue.cgColor
            imageLayer.borderWidth = 3
            CATransaction.commit()
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
        } else {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
        onHoverEnd?()
    }

    func updateImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    private func updateLabel() {
        labelLayer.string = windowInfo?.displayName ?? ""
        if let image = windowInfo?.latestImage {
            imageLayer.contents = image
        }
        if let icon = windowInfo?.appIcon {
            iconLayer.contents = icon
        }
    }

    func showHint(_ character: String) {
        hintLayer.string = character
        hintLayer.isHidden = false
    }

    func hideHint() {
        hintLayer.isHidden = true
    }

    private func updateActiveOverlay() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        activeOverlay.isHidden = !isActiveWindow
        activeLabel.isHidden = !isActiveWindow
        if isActiveWindow {
            imageLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            imageLayer.borderWidth = 2
        } else if !isMouseInside {
            imageLayer.borderWidth = 0
        }
        CATransaction.commit()
    }
}
