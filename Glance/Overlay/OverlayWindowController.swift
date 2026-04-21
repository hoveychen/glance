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
    /// Pin button clicked on a thumbnail — with the side the user chose.
    var onThumbnailPinClicked: ((WindowInfo, ThumbnailView.PinnedSide) -> Void)?
    /// Hint pill clicked — user wants to rename the reservation for this
    /// window. Routed to edit mode by the coordinator.
    var onThumbnailHintPillClicked: ((CGWindowID) -> Void)?

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

    /// Pinned left reference window ID — its thumbnail gets the "pinned left" overlay.
    var pinnedLeftReferenceWindowID: CGWindowID? {
        didSet { refreshPinnedSides() }
    }

    /// Pinned right reference window ID — its thumbnail gets the "pinned right" overlay.
    var pinnedRightReferenceWindowID: CGWindowID? {
        didSet { refreshPinnedSides() }
    }

    private func pinnedSide(for id: CGWindowID) -> ThumbnailView.PinnedSide {
        if id == pinnedLeftReferenceWindowID { return .left }
        if id == pinnedRightReferenceWindowID { return .right }
        return .none
    }

    private func refreshPinnedSides() {
        for (id, window) in thumbnailWindows {
            window.pinnedSide = pinnedSide(for: id)
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
                existingWindow.pinnedSide = pinnedSide(for: slot.windowID)
                // Don't animate the window being dragged — user controls its position
                if slot.windowID != draggingWindowID {
                    existingWindow.animateTo(frame: slot.rect)
                }
            } else {
                let thumbWindow = ThumbnailWindow(windowInfo: info, frame: slot.rect)
                thumbWindow.isActiveWindow = (slot.windowID == activeWindowID)
                thumbWindow.pinnedSide = pinnedSide(for: slot.windowID)
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
                thumbWindow.onPinClicked = { [weak self] windowInfo, side in
                    self?.onThumbnailPinClicked?(windowInfo, side)
                }
                thumbWindow.onHintPillClicked = { [weak self] windowID in
                    self?.onThumbnailHintPillClicked?(windowID)
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

    /// Show hint labels on thumbnails. Preassigned entries take their key
    /// regardless of grid position; the rest draw from `hintKeys` in grid
    /// order, consuming from `startIndex`. Returns mapping of character →
    /// windowID for all assignments made by this controller.
    func showHints(
        startIndex: inout Int,
        hintKeys: [String],
        preassigned: [CGWindowID: String] = [:]
    ) -> [String: CGWindowID] {
        var mapping: [String: CGWindowID] = [:]
        // Sort by window position (left-to-right, top-to-bottom) so the
        // auto-assigned fill walks the grid deterministically.
        let sorted = thumbnailWindows.sorted { a, b in
            if abs(a.value.frame.midY - b.value.frame.midY) > 30 {
                return a.value.frame.midY > b.value.frame.midY  // AppKit: higher Y = higher on screen
            }
            return a.value.frame.midX < b.value.frame.midX
        }
        for (id, window) in sorted {
            if let reservedKey = preassigned[id] {
                window.showHint(reservedKey, style: .reserved)
                mapping[reservedKey] = id
                continue
            }
            guard startIndex < hintKeys.count else { continue }
            let key = hintKeys[startIndex]
            window.showHint(key, style: .auto)
            mapping[key] = id
            startIndex += 1
        }
        return mapping
    }

    /// Switch a single thumbnail's pill into editing mode, optionally keeping
    /// the currently displayed character. Used when the user Shift+<key>s or
    /// clicks a pill to rename it.
    func setHintEditing(windowID: CGWindowID, character: String) {
        guard let window = thumbnailWindows[windowID] else { return }
        window.showHint(character, style: .editing)
    }

    /// Restore a thumbnail's pill to a non-editing style after edit-mode exits.
    func setHintStyle(windowID: CGWindowID, character: String, reserved: Bool) {
        guard let window = thumbnailWindows[windowID] else { return }
        window.showHint(character, style: reserved ? .reserved : .auto)
    }

    func hideHints() {
        for (_, window) in thumbnailWindows {
            window.hideHint()
        }
    }

    /// Update hint badges to show pin icon alongside the key character.
    func showHintPinMode() {
        for (_, window) in thumbnailWindows {
            window.showHintPinIcon()
        }
    }

    /// Apply MRU glow ranks to thumbnails. `mruList` is ordered newest-first.
    /// Thumbnails not in the list have their glow cleared.
    func updateMRUGlow(mruList: [CGWindowID], enabled: Bool) {
        for (id, window) in thumbnailWindows {
            if enabled, let rank = mruList.firstIndex(of: id) {
                window.updateMRUGlow(rank: rank)
            } else {
                window.updateMRUGlow(rank: nil)
            }
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
