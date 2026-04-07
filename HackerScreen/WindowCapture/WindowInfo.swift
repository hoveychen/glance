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

    /// The app icon, lazily loaded from the running process.
    lazy var appIcon: NSImage? = {
        NSRunningApplication(processIdentifier: ownerPID)?.icon
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
