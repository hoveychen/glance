import AppKit

/// Manages thumbnail windows for a single display.
/// Receives pre-computed layout slots from the coordinator (AppDelegate).
final class OverlayWindowController {

    var onThumbnailClicked: ((WindowInfo) -> Void)?
    var onThumbnailDragMoved: ((CGWindowID, CGPoint) -> Void)?
    var onThumbnailDragComplete: ((CGWindowID) -> Void)?
    var onThumbnailHoverStart: ((CGWindowID) -> Void)?
    var onThumbnailHoverEnd: ((CGWindowID) -> Void)?
    /// External file/text drag hovered long enough to trigger spring-loading.
    var onThumbnailDragSpringLoad: ((CGWindowID) -> Void)?

    /// Window being dragged — skip animating it during layout updates.
    var draggingWindowID: CGWindowID?

    /// The active (main) window ID — its thumbnail gets the active overlay.
    var activeWindowID: CGWindowID? {
        didSet {
            for (id, window) in thumbnailWindows {
                window.isActiveWindow = (id == activeWindowID)
            }
        }
    }

    let screen: NSScreen
    private var thumbnailWindows: [CGWindowID: ThumbnailWindow] = [:]

    init(screen: NSScreen) {
        self.screen = screen
    }

    func hideOverlay() {
        for (_, window) in thumbnailWindows {
            window.orderOut(nil)
        }
        thumbnailWindows.removeAll()
    }

    func updateSlots(_ slots: [WindowSlot], allWindows: [WindowInfo]) {
        let activeIDs = Set(slots.map(\.windowID))

        for (windowID, window) in thumbnailWindows where !activeIDs.contains(windowID) {
            window.orderOut(nil)
            thumbnailWindows.removeValue(forKey: windowID)
        }

        for slot in slots {
            guard let info = allWindows.first(where: { $0.windowID == slot.windowID }) else { continue }

            if let existingWindow = thumbnailWindows[slot.windowID] {
                existingWindow.updateWindowInfo(info)
                existingWindow.isActiveWindow = (slot.windowID == activeWindowID)
                // Don't animate the window being dragged — user controls its position
                if slot.windowID != draggingWindowID {
                    existingWindow.animateTo(frame: slot.rect)
                }
            } else {
                let thumbWindow = ThumbnailWindow(windowInfo: info, frame: slot.rect)
                thumbWindow.isActiveWindow = (slot.windowID == activeWindowID)
                thumbWindow.onClick = { [weak self] clickedInfo in
                    self?.onThumbnailClicked?(clickedInfo)
                }
                thumbWindow.onDragMoved = { [weak self] windowID, point in
                    self?.onThumbnailDragMoved?(windowID, point)
                }
                thumbWindow.onDragComplete = { [weak self] windowID in
                    self?.onThumbnailDragComplete?(windowID)
                }
                thumbWindow.onHoverStart = { [weak self] windowID in
                    self?.onThumbnailHoverStart?(windowID)
                }
                thumbWindow.onHoverEnd = { [weak self] windowID in
                    self?.onThumbnailHoverEnd?(windowID)
                }
                thumbWindow.onDragSpringLoad = { [weak self] windowID in
                    self?.onThumbnailDragSpringLoad?(windowID)
                }
                thumbWindow.orderFrontRegardless()
                thumbnailWindows[slot.windowID] = thumbWindow
            }
        }
    }

    func thumbnailWindowFrames() -> [(CGWindowID, CGRect)] {
        thumbnailWindows.map { ($0.key, $0.value.frame) }
    }

    func thumbnailFrame(for windowID: CGWindowID) -> CGRect? {
        thumbnailWindows[windowID]?.frame
    }

    /// Show hint labels on thumbnails. Returns mapping of character → windowID.
    func showHints(startIndex: inout Int, hintKeys: [String]) -> [String: CGWindowID] {
        var mapping: [String: CGWindowID] = [:]
        // Sort by window position (left-to-right, top-to-bottom) for predictable assignment
        let sorted = thumbnailWindows.sorted { a, b in
            if abs(a.value.frame.midY - b.value.frame.midY) > 30 {
                return a.value.frame.midY > b.value.frame.midY  // AppKit: higher Y = higher on screen
            }
            return a.value.frame.midX < b.value.frame.midX
        }
        for (id, window) in sorted {
            guard startIndex < hintKeys.count else { break }
            let key = hintKeys[startIndex]
            window.showHint(key)
            mapping[key] = id
            startIndex += 1
        }
        return mapping
    }

    func hideHints() {
        for (_, window) in thumbnailWindows {
            window.hideHint()
        }
    }

    func thumbnailUpdated(windowID: CGWindowID) {
        guard let thumbWindow = thumbnailWindows[windowID],
              let info = thumbWindow.thumbnailView,
              let image = info.windowInfo?.latestImage else { return }
        thumbWindow.updateImage(image)
    }
}

private extension ThumbnailWindow {
    var thumbnailView: ThumbnailView? {
        contentView as? ThumbnailView
    }
}
