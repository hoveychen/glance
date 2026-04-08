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

    /// Human-readable display name for the thumbnail label.
    var displayName: String {
        if title.isEmpty {
            return ownerName
        }
        return "\(ownerName) — \(title)"
    }
}
