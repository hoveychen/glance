import AppKit

/// Represents a tracked window with its metadata and latest captured thumbnail.
final class WindowInfo: Identifiable, Hashable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    var title: String
    var frame: CGRect
    var isOnScreen: Bool
    var latestImage: CGImage?
    /// Index into NSScreen.screens at the time the window was first discovered.
    var originalScreenIndex: Int?

    // MARK: - AX Classification (populated by WindowTracker)

    /// The Accessibility role (e.g. "AXWindow", "AXSheet").
    var axRole: String?
    /// The Accessibility subrole (e.g. "AXStandardWindow", "AXDialog", "AXFloatingWindow").
    var axSubrole: String?
    /// The CGWindowLevel / layer. 0 = normal window, >0 = overlay/menu/system.
    var windowLevel: Int = 0

    /// Whether this window should be treated as a "real" user window
    /// (suitable for thumbnailing/switching), based on AltTab-style classification.
    var isActualWindow: Bool {
        // Non-zero window level means overlay, menu, tooltip, etc.
        if windowLevel != 0 { return false }

        // Classify by AX subrole
        switch axSubrole {
        case "AXStandardWindow":
            return true
        case "AXDialog":
            // Dialogs are real windows (e.g. Save dialogs, Preferences windows).
            // They belong to their parent app but should be visible.
            return true
        case "AXFloatingWindow":
            // Floating panels (e.g. Photoshop tool palettes) — not real windows
            return false
        case "AXSystemDialog":
            // System dialogs (e.g. "App would like to access...") — transient
            return false
        case "AXSheet":
            // Sheets are attached to parent window — not independent
            return false
        case "AXUnknown", .none:
            // Unknown subrole: fall back to size heuristic (>= 100x100)
            return frame.width >= 100 && frame.height >= 100
        default:
            return false
        }
    }

    /// Whether this window is a popup/dialog that should be constrained to the
    /// work area rather than treated as a switchable window.
    /// Popups are same-PID non-standard windows: dialogs, sheets, floating panels.
    var isPopupOrDialog: Bool {
        switch axSubrole {
        case "AXDialog", "AXSheet", "AXSystemDialog":
            return true
        case "AXFloatingWindow":
            return true
        default:
            return false
        }
    }

    /// The app icon, lazily loaded and rendered to a fixed-size CGImage
    /// so it won't change with the system appearance.
    lazy var appIcon: CGImage? = {
        guard let icon = NSRunningApplication(processIdentifier: ownerPID)?.icon else { return nil }
        let pixelSize = 56  // 28pt × 2x Retina
        let size = NSSize(width: pixelSize, height: pixelSize)
        icon.size = size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }()

    init(windowID: CGWindowID, ownerPID: pid_t, ownerName: String, title: String, frame: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
    }

    var id: CGWindowID { windowID }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    /// The CGWindowSharingType value from CGWindowListCopyWindowInfo.
    /// 0 = kCGWindowSharingNone (private/non-capturable),
    /// 1 = kCGWindowSharingReadOnly, 2 = kCGWindowSharingReadWrite.
    var sharingState: Int = 2

    /// Whether this window is marked as non-shareable by the system
    /// (e.g. private/incognito browsing windows set sharingType = .none).
    var isPrivateBrowsing: Bool {
        sharingState == 0  // kCGWindowSharingNone
    }

    /// Human-readable display name for the thumbnail label.
    var displayName: String {
        if title.isEmpty {
            return ownerName
        }
        return "\(ownerName) — \(title)"
    }
}
