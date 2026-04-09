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

        // Snapshot existing screen IDs before creating the virtual display,
        // so we can diff afterwards to find the newly added one.
        let screenIDsBefore = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        })

        // 1. Create descriptor
        let descObj = descClass.alloc().perform(NSSelectorFromString("init"))!
            .takeUnretainedValue()

        let queue = DispatchQueue(label: "com.hoveychen.Glance.vd")
        descObj.perform(NSSelectorFromString("setDispatchQueue:"), with: queue)
        descObj.perform(NSSelectorFromString("setName:"), with: "Glance" as NSString)

        // UInt32 setters must use IMP-based dispatch — perform(_:with:) passes
        // the NSNumber *pointer* which the callee interprets as an integer, giving
        // garbage values that can prevent the display from going online.
        setUInt32Property(on: descObj, selector: "setMaxPixelsWide:", value: 3840)
        setUInt32Property(on: descObj, selector: "setMaxPixelsHigh:", value: 2160)
        setUInt32Property(on: descObj, selector: "setProductID:", value: 0xFACE)
        setUInt32Property(on: descObj, selector: "setVendorID:", value: 0xBEEF)
        setUInt32Property(on: descObj, selector: "setSerialNum:", value: 1)

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
        setUInt32Property(on: settingsObj, selector: "setHiDPI:", value: 0)
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
        logger.warning("CGDisplayIsOnline=\(CGDisplayIsOnline(self.displayID)), CGDisplayIsActive=\(CGDisplayIsActive(self.displayID))")
        logger.warning("screenIDsBefore=\(screenIDsBefore.sorted(), privacy: .public)")

        // Poll for the virtual display to appear in NSScreen.screens (up to 5 seconds).
        // Find it by diffing screen IDs before vs after — the new one is ours.
        var found = false
        for attempt in 1...10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

            let currentScreens = NSScreen.screens
            let screenIDs = currentScreens.compactMap {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
            logger.warning("Poll #\(attempt): screenIDs=\(screenIDs, privacy: .public), looking for ID not in \(screenIDsBefore.sorted(), privacy: .public)")

            let newScreen = currentScreens.first { screen in
                guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                return !screenIDsBefore.contains(screenID)
            }
            if let newScreen {
                let newID = (newScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
                if displayID == 0 {
                    displayID = newID
                }
                let vf = newScreen.frame
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                origin = CGPoint(x: vf.origin.x, y: primaryH - vf.origin.y - vf.height)
                size = vf.size
                logger.warning("Virtual display detected after \(attempt * 500)ms, displayID=\(self.displayID), origin=(\(self.origin.x), \(self.origin.y)), size=\(self.size.width)x\(self.size.height)")
                found = true
                break
            }
        }
        if !found {
            logger.error("Virtual display not detected in NSScreen.screens after 5s. Screens: \(NSScreen.screens.map { "\($0.localizedName) id=\(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0) frame=\($0.frame)" }.joined(separator: ", "), privacy: .public)")
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

    /// Find the NSScreen corresponding to the virtual display by its displayID.
    func findVirtualScreen() -> NSScreen? {
        guard displayID != 0 else { return nil }
        return NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })
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

    private func setUInt32Property(on obj: AnyObject, selector: String, value: UInt32) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(type(of: obj), sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(obj, sel, value)
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
