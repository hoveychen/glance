import AppKit
import ObjectiveC
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "VirtualDisplay")

/// Creates and manages a hidden virtual display where non-main windows are moved to.
/// Windows on the virtual display can still be captured via CGWindowListCreateImage.
final class VirtualDisplayManager {

    static let shared = VirtualDisplayManager()

    /// The virtual display object (retained to keep it alive).
    private var virtualDisplay: AnyObject?

    /// The CGDirectDisplayID of the virtual display, used for reliable screen matching.
    private(set) var displayID: CGDirectDisplayID = 0

    /// AX-coordinate origin of the virtual display.
    private(set) var origin: CGPoint = .zero

    /// Size of the virtual display in points.
    private(set) var size: CGSize = .zero

    /// Whether the virtual display is currently active.
    var isActive: Bool { virtualDisplay != nil }

    private init() {}

    // MARK: - Public

    /// Create the virtual display. Returns true on success.
    @discardableResult
    func create() -> Bool {
        guard virtualDisplay == nil else { return true }

        guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else {
            logger.warning("CGVirtualDisplay classes not found")
            return false
        }

        logger.warning("Creating virtual display...")

        // 1. Create descriptor
        let descObj = descClass.alloc().perform(NSSelectorFromString("init"))!
            .takeUnretainedValue()

        let queue = DispatchQueue(label: "com.hoveychen.Glance.vd")
        descObj.perform(NSSelectorFromString("setDispatchQueue:"), with: queue)
        descObj.perform(NSSelectorFromString("setName:"), with: "Glance" as NSString)

        // Use NSNumber for UInt32 setters via perform
        descObj.perform(NSSelectorFromString("setMaxPixelsWide:"), with: NSNumber(value: 3840))
        descObj.perform(NSSelectorFromString("setMaxPixelsHigh:"), with: NSNumber(value: 2160))
        descObj.perform(NSSelectorFromString("setProductID:"), with: NSNumber(value: 0xFACE))
        descObj.perform(NSSelectorFromString("setVendorID:"), with: NSNumber(value: 0xBEEF))
        descObj.perform(NSSelectorFromString("setSerialNum:"), with: NSNumber(value: 1))

        // setSizeInMillimeters: takes a CGSize struct — use NSInvocation
        setSizeInMillimeters(on: descObj, size: CGSize(width: 600, height: 340))

        logger.warning("Descriptor configured")

        // 2. Create display mode — initWithWidth:height:refreshRate: needs NSInvocation
        let modeAllocated = modeClass.alloc()
        guard let modeObj = createDisplayMode(
            allocated: modeAllocated, width: 3840, height: 2160, refreshRate: 60.0
        ) else {
            logger.warning("Failed to create display mode")
            return false
        }
        logger.warning("Display mode created")

        // 3. Create settings
        let settingsObj = settingsClass.alloc().perform(NSSelectorFromString("init"))!
            .takeUnretainedValue()
        settingsObj.perform(NSSelectorFromString("setModes:"), with: [modeObj] as NSArray)
        settingsObj.perform(NSSelectorFromString("setHiDPI:"), with: NSNumber(value: 0))
        logger.warning("Settings configured")

        // 4. Create virtual display
        guard let vdResult = displayClass.alloc()
            .perform(NSSelectorFromString("initWithDescriptor:"), with: descObj) else {
            logger.warning("Failed to create virtual display (initWithDescriptor: returned nil)")
            return false
        }
        let vdObj = vdResult.takeUnretainedValue()

        // Apply settings
        vdObj.perform(NSSelectorFromString("applySettings:"), with: settingsObj)

        virtualDisplay = vdObj

        // Extract the CGDirectDisplayID via IMP casting (the property returns UInt32)
        displayID = getDisplayID(from: vdObj)
        logger.warning("Virtual display created, displayID=\(self.displayID)")

        // Poll for the virtual display to appear in NSScreen.screens (up to 5 seconds).
        // The system needs time to register the new display.
        var found = false
        for attempt in 1...10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            refreshScreenCoordinates()
            if origin != .zero {
                logger.warning("Virtual display detected after \(attempt * 500)ms")
                found = true
                break
            }
        }
        if !found {
            logger.error("Virtual display not detected in NSScreen.screens after 5s. Screens: \(NSScreen.screens.map { "\($0.localizedName) id=\(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0) frame=\($0.frame)" }.joined(separator: ", "))")
            destroy()
            return false
        }

        return true
    }

    /// Destroy the virtual display. Windows will return to the main screen.
    func destroy() {
        virtualDisplay = nil
        displayID = 0
        origin = .zero
        size = .zero
        logger.warning("Virtual display destroyed")
    }

    /// Refresh the virtual screen coordinates from NSScreen.
    /// Uses CGDirectDisplayID for reliable matching, falls back to name.
    func refreshScreenCoordinates() {
        guard isActive else { return }

        let vScreen: NSScreen? = findVirtualScreen()
        guard let vScreen else {
            logger.warning("Virtual display not found in NSScreen.screens (displayID=\(self.displayID))")
            return
        }

        let vf = vScreen.frame
        // Primary screen height for AppKit→CG coordinate conversion
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        origin = CGPoint(x: vf.origin.x, y: primaryH - vf.origin.y - vf.height)
        size = vf.size
        logger.warning("Virtual screen at AX origin=(\(self.origin.x), \(self.origin.y)) size=\(self.size.width)x\(self.size.height)")
    }

    /// Find the NSScreen corresponding to the virtual display.
    /// Tries displayID first (most reliable), then falls back to name matching.
    func findVirtualScreen() -> NSScreen? {
        // Method 1: Match by CGDirectDisplayID (most reliable)
        if displayID != 0 {
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
                return screen
            }
        }
        // Method 2: Match by localizedName
        if let screen = NSScreen.screens.first(where: { $0.localizedName == "Glance" }) {
            return screen
        }
        // Method 3: Find a screen with exactly our configured resolution that isn't the primary
        if let screen = NSScreen.screens.dropFirst().first(where: {
            let w = $0.frame.width
            let h = $0.frame.height
            // We created 3840×2160, but NSScreen reports in points (may be halved for HiDPI)
            return (w == 3840 && h == 2160) || (w == 1920 && h == 1080)
        }) {
            return screen
        }
        return nil
    }

    /// Whether a given NSScreen is the virtual display.
    func isVirtualDisplay(_ screen: NSScreen) -> Bool {
        if displayID != 0 {
            return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
        return screen.localizedName == "Glance"
    }

    /// Assigned parking slots — guarantees each window gets a unique position.
    private var parkingSlots: [CGWindowID: Int] = [:]
    private var nextSlot: Int = 0

    /// Returns a unique position on the virtual display for a given window ID.
    /// Each window is assigned a distinct slot so same-PID windows never collide.
    func parkingPosition(for windowID: CGWindowID) -> CGPoint {
        let slot: Int
        if let existing = parkingSlots[windowID] {
            slot = existing
        } else {
            slot = nextSlot
            parkingSlots[windowID] = slot
            nextSlot += 1
        }
        let col = slot % 10
        let row = slot / 10
        return CGPoint(
            x: origin.x + CGFloat(col) * 350 + 50,
            y: origin.y + CGFloat(row) * 250 + 50
        )
    }

    /// Release a parking slot when a window is unparked.
    func releaseSlot(for windowID: CGWindowID) {
        parkingSlots.removeValue(forKey: windowID)
    }

    // MARK: - Private (NSInvocation helpers for struct/multi-arg selectors)

    /// Extract the CGDirectDisplayID from a CGVirtualDisplay object.
    private func getDisplayID(from vdObj: AnyObject) -> CGDirectDisplayID {
        let sel = NSSelectorFromString("displayID")
        guard let method = class_getInstanceMethod(type(of: vdObj), sel) else { return 0 }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt32
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(vdObj, sel)
    }

    private func setSizeInMillimeters(on obj: AnyObject, size: CGSize) {
        let sel = NSSelectorFromString("setSizeInMillimeters:")
        guard let method = class_getInstanceMethod(type(of: obj), sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, CGSize) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(obj, sel, size)
    }

    private func createDisplayMode(allocated: AnyObject, width: UInt32, height: UInt32, refreshRate: Double) -> AnyObject? {
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let method = class_getInstanceMethod(type(of: allocated), sel) else { return nil }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(allocated, sel, width, height, refreshRate)
    }
}
