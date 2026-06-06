import AppKit
import IOSurface

/// Represents a tracked window with its metadata and latest captured thumbnail.
final class WindowInfo: Identifiable, Hashable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    var title: String
    var frame: CGRect
    var isOnScreen: Bool

    /// Most recent capture as a CGImage. Used by the hover-preview window
    /// (which needs a CGImage for `NSImage(cgImage:)`).
    var latestImage: CGImage?
    /// Most recent capture as an IOSurface. Used as `CALayer.contents` for
    /// thumbnails — CALayer recognises IOSurface backing and skips the
    /// `CA::Render::copy_image` materialisation on every commit.
    var latestSurface: IOSurface?
    /// Index into NSScreen.screens at the time the window was first discovered.
    var originalScreenIndex: Int?

    // MARK: - AX Classification (populated by WindowTracker)

    /// The Accessibility role (e.g. "AXWindow", "AXSheet").
    var axRole: String?
    /// The Accessibility subrole (e.g. "AXStandardWindow", "AXDialog", "AXFloatingWindow").
    var axSubrole: String?
    /// The CGWindowLevel / layer. 0 = normal window, >0 = overlay/menu/system.
    var windowLevel: Int = 0

    /// The owning app's `NSApplication.ActivationPolicy`, populated by WindowTracker.
    /// `nil` when the owning process could not be resolved (e.g. it already quit) —
    /// in that case we fall back to the existing classification rather than guessing.
    /// Used to recognise system agents (SecurityAgent credential prompts, USB
    /// authorization dialogs, helper HUDs) which are `.accessory` / `.prohibited` and
    /// must never be treated as switchable work windows.
    var ownerActivationPolicy: NSApplication.ActivationPolicy?

    /// Whether this window is tethered to another same-PID window (sidebar, watermark,
    /// HUD) and cannot be positioned independently. Tethered windows are excluded from
    /// thumbnailing, auto-swap, and individual parking — their parent carries them.
    var isTethered: Bool = false
    /// Whether tether detection has already run for this window (cached so we don't
    /// re-probe every refresh cycle).
    var tetherCheckComplete: Bool = false

    /// Whether this window should be treated as a "real" user window
    /// (suitable for thumbnailing/switching), based on AltTab-style classification.
    var isActualWindow: Bool {
        // Non-zero window level means overlay, menu, tooltip, etc.
        if windowLevel != 0 { return false }

        // Windows owned by non-regular apps (.accessory / .prohibited) are system
        // agents — credential prompts (SecurityAgent), USB authorization dialogs,
        // helper HUDs — never user-switchable work windows. These processes are
        // protected, so their AX subrole is often unreadable (nil); without this
        // guard the AXUnknown/.none branch below would mis-classify a >=100x100
        // password dialog as a real window, and the work-area pipeline would park
        // it onto the hidden virtual display — making it invisible until Glance
        // quits. handleAppActivation already refuses to swap non-regular apps via
        // the same `activationPolicy == .regular` test; mirror that here so the
        // thumbnail / park / auto-swap paths agree. `nil` (process gone) falls
        // through to the existing classification.
        if let policy = ownerActivationPolicy, policy != .regular { return false }

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

    /// The owning app's bundle identifier, used to match reserved-key
    /// mappings across window-ID reassignment and app restarts.
    var bundleId: String? {
        NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }
}
