import AppKit

/// A Chrome-style horizontal tab strip rendered at the top of the work area.
///
/// Each docked window is one tab. Pinned tabs are icon-only and kept at the
/// left; regular tabs show icon + title + a close button. The active tab
/// (whose window occupies the main panel) is highlighted.
///
/// Rendering is plain `draw(_:)` + manual hit-testing — the strip repaints
/// rarely, so it doesn't need the IOSurface/CALayer machinery `ThumbnailView`
/// uses for live window contents.
final class TabStripView: NSView {

    struct Tab: Equatable {
        let windowID: CGWindowID
        var title: String
        var icon: CGImage?
        var isActive: Bool
        var isPinned: Bool

        // Icon identity isn't compared (CGImage has no cheap value equality);
        // a title/active/pin change is what should trigger a repaint.
        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.windowID == rhs.windowID
                && lhs.title == rhs.title
                && lhs.isActive == rhs.isActive
                && lhs.isPinned == rhs.isPinned
        }
    }

    /// Tabs in display order (the coordinator is responsible for putting pinned
    /// tabs first — see `WorkAreaTabStore.arrange`).
    var tabs: [Tab] = [] {
        didSet {
            guard tabs != oldValue else { return }
            relayoutTabs()
            needsDisplay = true
        }
    }

    /// Fires when a tab body is clicked — activate that window.
    var onSelect: ((CGWindowID) -> Void)?
    /// Fires when a tab's close button is clicked — undock that window.
    var onClose: ((CGWindowID) -> Void)?
    /// Fires when the user toggles pin state (via context menu).
    var onTogglePin: ((CGWindowID) -> Void)?
    /// Fires when a tab is dropped at a new index after a drag-reorder.
    var onReorder: ((CGWindowID, Int) -> Void)?

    // MARK: - Layout constants

    /// Overall strip height. The work area reserves exactly this much at top.
    static let height: CGFloat = 38

    private let pinnedWidth: CGFloat = 40
    private let regularMin: CGFloat = 72
    private let regularMax: CGFloat = 220
    private let tabGap: CGFloat = 4
    private let vInset: CGFloat = 5
    private let hInset: CGFloat = 8
    private let iconSize: CGFloat = 16
    private let closeSize: CGFloat = 15
    private let cornerRadius: CGFloat = 7

    // MARK: - Computed per-layout geometry

    private struct TabFrame {
        let windowID: CGWindowID
        let rect: CGRect
        let closeRect: CGRect?
        let isPinned: Bool
    }
    private var tabFrames: [TabFrame] = []

    private var hoveredID: CGWindowID?
    private var hoveredCloseID: CGWindowID?
    private var trackingArea: NSTrackingArea?

    // Drag-reorder state.
    private var pressedID: CGWindowID?
    private var pressOrigin: CGPoint = .zero
    private var isReordering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool { false }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func layout() {
        super.layout()
        relayoutTabs()
    }

    // MARK: - Geometry

    private func relayoutTabs() {
        tabFrames.removeAll()
        guard !tabs.isEmpty, bounds.width > 0 else { return }

        let pinnedCount = tabs.filter(\.isPinned).count
        let regularCount = tabs.count - pinnedCount

        let totalGap = CGFloat(max(0, tabs.count - 1)) * tabGap
        let pinnedTotal = CGFloat(pinnedCount) * pinnedWidth
        let availableForRegular = bounds.width - hInset * 2 - totalGap - pinnedTotal

        let regularWidth: CGFloat = {
            guard regularCount > 0 else { return 0 }
            let raw = availableForRegular / CGFloat(regularCount)
            return max(regularMin, min(regularMax, raw))
        }()

        let y = vInset
        let h = bounds.height - vInset * 2
        var x = hInset

        for tab in tabs {
            let w = tab.isPinned ? pinnedWidth : regularWidth
            let rect = CGRect(x: x, y: y, width: w, height: h)
            var closeRect: CGRect? = nil
            if !tab.isPinned {
                // Close button sits at the trailing edge, vertically centered.
                let cx = rect.maxX - closeSize - 6
                let cy = rect.midY - closeSize / 2
                closeRect = CGRect(x: cx, y: cy, width: closeSize, height: closeSize)
            }
            tabFrames.append(TabFrame(windowID: tab.windowID, rect: rect,
                                      closeRect: closeRect, isPinned: tab.isPinned))
            x += w + tabGap
        }
    }

    private func tabFrame(at point: CGPoint) -> TabFrame? {
        tabFrames.first { $0.rect.contains(point) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        for (idx, frame) in tabFrames.enumerated() {
            guard idx < tabs.count else { break }
            let tab = tabs[idx]
            draw(tab: tab, frame: frame)
        }
    }

    private func draw(tab: Tab, frame: TabFrame) {
        let rect = frame.rect
        let isHovered = hoveredID == tab.windowID

        // Background. Dark pills (not light) so white text stays legible no
        // matter what the frosted-glass material lets through from the
        // wallpaper behind it. A subtle light border keeps each tab's edge
        // visible even on a dark background where the fill blends in.
        let bgColor: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat
        if tab.isActive {
            bgColor = NSColor.black.withAlphaComponent(0.38)
            borderColor = NSColor.white.withAlphaComponent(0.32)
            borderWidth = 1
        } else if isHovered {
            bgColor = NSColor.black.withAlphaComponent(0.24)
            borderColor = NSColor.white.withAlphaComponent(0.14)
            borderWidth = 1
        } else {
            bgColor = NSColor.black.withAlphaComponent(0.14)
            borderColor = NSColor.white.withAlphaComponent(0.10)
            borderWidth = 1
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = borderWidth
        path.stroke()

        // Icon
        var contentX = rect.minX + 8
        if let icon = tab.icon {
            let iconRect = CGRect(x: contentX, y: rect.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
            NSImage(cgImage: icon, size: NSSize(width: iconSize, height: iconSize))
                .draw(in: iconRect)
            contentX = iconRect.maxX + 6
        }

        // Title (regular tabs only — pinned tabs are icon-only)
        if !tab.isPinned {
            let titleRightEdge = (frame.closeRect?.minX ?? rect.maxX) - 4
            let titleWidth = max(0, titleRightEdge - contentX)
            if titleWidth > 4 {
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                let textColor = tab.isActive
                    ? NSColor.white
                    : NSColor.white.withAlphaComponent(0.85)
                // Dark halo so the white title stays readable even when the
                // pill is light (light wallpaper bleeding through the glass).
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
                shadow.shadowBlurRadius = 2.5
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: tab.isActive ? .medium : .regular),
                    .foregroundColor: textColor,
                    .paragraphStyle: para,
                    .shadow: shadow,
                ]
                let str = NSAttributedString(string: tab.title, attributes: attrs)
                let textH = str.size().height
                let textRect = CGRect(x: contentX, y: rect.midY - textH / 2,
                                      width: titleWidth, height: textH)
                str.draw(in: textRect)
            }

            // Close button (shown when active or hovered)
            if let closeRect = frame.closeRect, tab.isActive || isHovered {
                let closeHover = hoveredCloseID == tab.windowID
                if closeHover {
                    NSColor.white.withAlphaComponent(0.18).setFill()
                    NSBezierPath(ovalIn: closeRect).fill()
                }
                NSGraphicsContext.current?.saveGraphicsState()
                let glyphShadow = NSShadow()
                glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
                glyphShadow.shadowBlurRadius = 2
                glyphShadow.shadowOffset = NSSize(width: 0, height: -1)
                glyphShadow.set()
                let glyph = NSBezierPath()
                let inset: CGFloat = 4.5
                let r = closeRect.insetBy(dx: inset, dy: inset)
                glyph.move(to: CGPoint(x: r.minX, y: r.minY))
                glyph.line(to: CGPoint(x: r.maxX, y: r.maxY))
                glyph.move(to: CGPoint(x: r.minX, y: r.maxY))
                glyph.line(to: CGPoint(x: r.maxX, y: r.minY))
                glyph.lineWidth = 1.3
                glyph.lineCapStyle = .round
                NSColor.white.withAlphaComponent(closeHover ? 0.95 : 0.7).setStroke()
                glyph.stroke()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hoveredID != nil || hoveredCloseID != nil {
            hoveredID = nil
            hoveredCloseID = nil
            needsDisplay = true
        }
    }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let frame = tabFrame(at: p)
        let newHover = frame?.windowID
        let newClose: CGWindowID? = {
            guard let frame, let closeRect = frame.closeRect, closeRect.contains(p) else { return nil }
            return frame.windowID
        }()
        if newHover != hoveredID || newClose != hoveredCloseID {
            hoveredID = newHover
            hoveredCloseID = newClose
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let frame = tabFrame(at: p) else { return }
        // Close-button hit takes priority.
        if let closeRect = frame.closeRect, closeRect.contains(p) {
            onClose?(frame.windowID)
            return
        }
        pressedID = frame.windowID
        pressOrigin = p
        isReordering = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedID else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isReordering, abs(p.x - pressOrigin.x) < 6 { return }
        isReordering = true

        // Find the index whose center the pointer has crossed.
        guard let fromIdx = tabs.firstIndex(where: { $0.windowID == pressedID }) else { return }
        var targetIdx = fromIdx
        for (idx, f) in tabFrames.enumerated() {
            if p.x < f.rect.midX { targetIdx = idx; break }
            targetIdx = idx
        }
        if targetIdx != fromIdx {
            onReorder?(pressedID, targetIdx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedID = nil; isReordering = false }
        guard let pressedID, !isReordering else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let frame = tabFrame(at: p), frame.windowID == pressedID {
            onSelect?(pressedID)
        }
    }

    // MARK: - Context menu (pin / unpin / close)

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let frame = tabFrame(at: p),
              let tab = tabs.first(where: { $0.windowID == frame.windowID }) else { return nil }
        let menu = NSMenu()
        let pinItem = NSMenuItem(
            title: tab.isPinned
                ? NSLocalizedString("tab.unpin", value: "Unpin Tab", comment: "Tab context menu: unpin")
                : NSLocalizedString("tab.pin", value: "Pin Tab", comment: "Tab context menu: pin"),
            action: #selector(contextPinToggle(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = tab.windowID
        menu.addItem(pinItem)

        if !tab.isPinned {
            let closeItem = NSMenuItem(
                title: NSLocalizedString("tab.close", value: "Close Tab", comment: "Tab context menu: close"),
                action: #selector(contextClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = tab.windowID
            menu.addItem(closeItem)
        }
        return menu
    }

    @objc private func contextPinToggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        onTogglePin?(id)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        onClose?(id)
    }
}
