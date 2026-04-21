import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "ThumbnailWindow")

/// A small borderless window that displays a single thumbnail.
/// Each thumbnail is its own window so it doesn't block the center area.
final class ThumbnailWindow: NSWindow {

    let windowID: CGWindowID
    var onClick: ((WindowInfo) -> Void)?
    /// Fires when the user clicks directly on the hint pill (while hint mode
    /// shows it). Separates rename-intent from the larger switch-to-window
    /// click target.
    var onHintPillClicked: ((CGWindowID) -> Void)?
    var onDragMoved: ((CGWindowID, CGPoint) -> Void)?
    var onDragComplete: ((CGWindowID) -> Void)?
    var onHoverStart: ((CGWindowID) -> Void)?
    var onHoverEnd: ((CGWindowID) -> Void)?
    /// Fires when an external file/text drag hovers long enough to trigger spring-loading.
    var onDragSpringLoad: ((CGWindowID) -> Void)?
    /// Fires when a pin button on the thumbnail is clicked. Parameter: which side to pin to.
    var onPinClicked: ((WindowInfo, ThumbnailView.PinnedSide) -> Void)?

    var isActiveWindow: Bool {
        get { thumbnailView.isActiveWindow }
        set { thumbnailView.isActiveWindow = newValue }
    }

    var pinnedSide: ThumbnailView.PinnedSide {
        get { thumbnailView.pinnedSide }
        set { thumbnailView.pinnedSide = newValue }
    }

    private let thumbnailView: ThumbnailView
    private var isDragging = false
    private var dragStartMouseLocation: CGPoint = .zero
    private var dragStartWindowOrigin: CGPoint = .zero
    private static let dragThreshold: CGFloat = 5

    init(windowInfo: WindowInfo, frame: CGRect) {
        self.windowID = windowInfo.windowID
        self.thumbnailView = ThumbnailView(frame: NSRect(origin: .zero, size: frame.size))

        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false

        self.contentView = thumbnailView
        thumbnailView.windowInfo = windowInfo
        thumbnailView.onHoverStart = { [weak self] in
            guard let self else { return }
            self.onHoverStart?(self.windowID)
        }
        thumbnailView.onHoverEnd = { [weak self] in
            guard let self else { return }
            self.onHoverEnd?(self.windowID)
        }
        thumbnailView.onSpringLoadActivated = { [weak self] in
            guard let self else { return }
            self.onDragSpringLoad?(self.windowID)
        }
        thumbnailView.onPinLeftClicked = { [weak self] in
            guard let self, let info = self.thumbnailView.windowInfo else { return }
            self.onPinClicked?(info, .left)
        }
        thumbnailView.onPinRightClicked = { [weak self] in
            guard let self, let info = self.thumbnailView.windowInfo else { return }
            self.onPinClicked?(info, .right)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - dragStartMouseLocation.x
        let dy = currentMouse.y - dragStartMouseLocation.y

        if !isDragging {
            if sqrt(dx * dx + dy * dy) > Self.dragThreshold {
                isDragging = true
                // Bring to front while dragging
                self.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                self.alphaValue = 0.8
            }
        }

        if isDragging {
            let newOrigin = CGPoint(
                x: dragStartWindowOrigin.x + dx,
                y: dragStartWindowOrigin.y + dy
            )
            setFrameOrigin(newOrigin)
            // Report position continuously during drag
            let center = CGPoint(x: frame.midX, y: frame.midY)
            onDragMoved?(windowID, center)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            self.level = .floating
            self.alphaValue = 1.0
            onDragComplete?(windowID)
        } else {
            // It was a click, not a drag. If the click landed on the hint
            // pill (while hint mode is active), treat it as rename-intent
            // rather than switch-to-window.
            if let pillRect = thumbnailView.hintPillRect {
                let localPoint = event.locationInWindow  // contentView fills the window
                if pillRect.contains(localPoint) {
                    onHintPillClicked?(windowID)
                    return
                }
            }
            guard let info = thumbnailView.windowInfo else { return }
            logger.warning("Thumbnail clicked: \(info.displayName)")
            onClick?(info)
        }
    }

    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { }
    }

    func updateWindowInfo(_ info: WindowInfo) {
        thumbnailView.windowInfo = info
    }

    func updateImage(_ image: CGImage) {
        thumbnailView.updateImage(image)
    }

    func showHint(_ character: String, style: ThumbnailView.HintStyle) {
        thumbnailView.showHint(character, style: style)
    }

    func hintStyle() -> ThumbnailView.HintStyle {
        thumbnailView.currentHintStyle
    }

    func hideHint() {
        thumbnailView.hideHint()
    }

    func showHintPinIcon() {
        thumbnailView.showHintPinIcon()
    }

    func updateMRUGlow(rank: Int?) {
        thumbnailView.updateMRUGlow(rank: rank)
    }

    func animateTo(frame newFrame: CGRect, duration: TimeInterval = 0.15) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }
}
