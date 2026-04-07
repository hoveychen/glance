import AppKit
import ObjectiveC
import os.log

private let logger = Logger(subsystem: "com.hoveychen.HackerScreen", category: "VirtualDisplay")

/// Creates and manages a hidden virtual display where non-main windows are moved to.
/// Windows on the virtual display can still be captured via CGWindowListCreateImage.
final class VirtualDisplayManager {

    static let shared = VirtualDisplayManager()

    /// The virtual display object (retained to keep it alive).
    private var virtualDisplay: AnyObject?

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

        let queue = DispatchQueue(label: "com.hoveychen.HackerScreen.vd")
        descObj.perform(NSSelectorFromString("setDispatchQueue:"), with: queue)
        descObj.perform(NSSelectorFromString("setName:"), with: "HackerScreen" as NSString)

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
        logger.warning("Virtual display created")

        // Wait briefly for the system to register the display, then find coordinates
        // This blocks briefly but is necessary so that parkingPosition() works
        // before the first handleWindowsUpdate fires
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

        refreshScreenCoordinates()

        return true
    }

    /// Destroy the virtual display. Windows will return to the main screen.
    func destroy() {
        virtualDisplay = nil
        origin = .zero
        size = .zero
        logger.warning("Virtual display destroyed")
    }

    /// Refresh the virtual screen coordinates from NSScreen.
    func refreshScreenCoordinates() {
        guard isActive else { return }
        if let vScreen = NSScreen.screens.first(where: { $0.localizedName == "HackerScreen" }) {
            let vf = vScreen.frame
            let mainH = NSScreen.main?.frame.height ?? 0
            origin = CGPoint(x: vf.origin.x, y: mainH - vf.origin.y - vf.height)
            size = vf.size
            logger.warning("Virtual screen at AX origin=(\(self.origin.x), \(self.origin.y)) size=\(self.size.width)x\(self.size.height)")
        } else {
            logger.warning("Virtual display not found as NSScreen, using offset position (\(self.origin.x), \(self.origin.y))")
        }
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
