import AppKit
import IOSurface
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "Capture")

/// Manages window thumbnail capture using CGWindowListCreateImage.
/// Unlike SCStream, this approach does not trigger the system recording indicator.
///
/// Capture cadence is **per-window** and event-driven, not a flat global FPS:
/// idle background thumbnails refresh at 0.5 FPS, the active or hovered window
/// at 2 FPS, and a window that just appeared / regained focus runs at 5 FPS
/// for one second before falling back. A single master tick scans the schedule
/// and dispatches due captures onto a serial capture queue.
final class WindowCaptureManager {

    private struct CaptureState {
        var info: WindowInfo
        var nextDueAt: CFAbsoluteTime
        var burstUntil: CFAbsoluteTime
        var inFlight: Bool
    }

    /// Windows currently being scheduled. All reads/writes happen on the main thread.
    private var states: [CGWindowID: CaptureState] = [:]
    private var activeWindowID: CGWindowID?
    private var hoverWindowID: CGWindowID?

    /// Callback: (windowID, latestCGImage, latestSurface).
    /// `cgImage` is the original SkyLight result, used for the hover-preview
    /// path that wants a CGImage. `surface` is an IOSurface materialised on the
    /// capture queue — `CALayer.contents = surface` skips CoreAnimation's
    /// per-commit `copy_image` because the surface is GPU-shareable as-is.
    private var frameCallback: ((CGWindowID, CGImage, IOSurface) -> Void)?

    /// Master tick — scans schedule and dispatches due captures. Not the capture
    /// rate itself; that lives in the per-window `nextDueAt`.
    private var masterTimer: Timer?
    private let tickInterval: TimeInterval = 0.1

    private let baselineInterval: TimeInterval = 2.0  // 0.5 FPS for idle background windows
    private let focusInterval: TimeInterval = 0.5     // 2 FPS for the active / hovered window
    private let burstInterval: TimeInterval = 0.2     // 5 FPS during burst
    private let burstDuration: TimeInterval = 1.0     // burst lasts 1 s after the trigger

    /// Dedicated serial queue for capture work. Using our own queue instead of
    /// the global concurrent `.userInteractive` queue bounds our thread use to 1.
    /// Why: `CGWindowListCreateImage` can block for seconds when WindowServer /
    /// ScreenCaptureKit's XPC daemon stalls. With async dispatch onto the shared
    /// concurrent pool, each timer tick spawned another blocked thread, saturating
    /// libdispatch's 64-thread soft limit and hanging the whole app (quit included).
    private let captureQueue = DispatchQueue(label: "com.hoveychen.Glance.capture", qos: .userInteractive)

    /// Update which windows are being captured. New windows get a one-shot burst
    /// so their first thumbnail appears immediately.
    func updateCaptures(for windows: [WindowInfo], onFrame: @escaping (CGWindowID, CGImage, IOSurface) -> Void) {
        self.frameCallback = onFrame

        let targetIDs = Set(windows.map(\.windowID))
        for id in Array(states.keys) where !targetIDs.contains(id) {
            states.removeValue(forKey: id)
        }
        if !targetIDs.contains(activeWindowID ?? 0) { activeWindowID = nil }
        if !targetIDs.contains(hoverWindowID ?? 0) { hoverWindowID = nil }

        let now = CFAbsoluteTimeGetCurrent()
        for info in windows {
            if var existing = states[info.windowID] {
                existing.info = info
                states[info.windowID] = existing
            } else {
                states[info.windowID] = CaptureState(
                    info: info,
                    nextDueAt: now,
                    burstUntil: now + burstDuration,
                    inFlight: false
                )
            }
        }

        if !states.isEmpty && masterTimer == nil {
            startTimer()
        } else if states.isEmpty {
            stopTimer()
        }
    }

    /// Mark the active main window. The active window captures at 2 FPS instead
    /// of the 0.5 FPS baseline.
    func setActiveWindow(_ windowID: CGWindowID?) {
        activeWindowID = windowID
    }

    /// Mark the hovered thumbnail. Hovered window captures at 2 FPS so the user
    /// gets a fresh preview while inspecting.
    func setHoverWindow(_ windowID: CGWindowID?) {
        hoverWindowID = windowID
    }

    /// Trigger a 1-second 5 FPS burst on the given window. Call when a window is
    /// newly discovered, regains focus, or is moved/resized.
    func burst(_ windowID: CGWindowID) {
        guard var state = states[windowID] else { return }
        let now = CFAbsoluteTimeGetCurrent()
        state.burstUntil = now + burstDuration
        state.nextDueAt = min(state.nextDueAt, now)
        states[windowID] = state
    }

    func stopAll() {
        stopTimer()
        states.removeAll()
        activeWindowID = nil
        hoverWindowID = nil
    }

    // MARK: - Private

    private func startTimer() {
        masterTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        masterTimer?.invalidate()
        masterTimer = nil
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()

        var dueIDs: [CGWindowID] = []
        for (windowID, state) in states {
            if state.inFlight { continue }
            if state.nextDueAt > now { continue }
            dueIDs.append(windowID)
        }
        if dueIDs.isEmpty { return }

        for windowID in dueIDs {
            guard var state = states[windowID] else { continue }

            // Skip private/incognito windows entirely — saves the API call and
            // avoids the macOS "private browsing window" alert. Push their
            // next-due far enough out that we don't loop on them every tick.
            if state.info.isPrivateBrowsing {
                state.nextDueAt = now + baselineInterval
                states[windowID] = state
                continue
            }

            // Snapshot the values we need on the capture queue. WindowInfo is
            // a reference type that may be mutated on the main thread.
            let snap = (
                windowID: windowID,
                displayName: state.info.displayName,
                frameW: state.info.frame.width,
                frameH: state.info.frame.height,
                isOnScreen: state.info.isOnScreen
            )

            let interval = currentInterval(for: windowID, now: now, burstUntil: state.burstUntil)
            state.inFlight = true
            state.nextDueAt = now + interval
            states[windowID] = state

            captureQueue.async { [weak self] in
                self?.captureOne(snap)
            }
        }
    }

    private func currentInterval(for windowID: CGWindowID, now: CFAbsoluteTime, burstUntil: CFAbsoluteTime) -> TimeInterval {
        if burstUntil > now { return burstInterval }
        if windowID == activeWindowID || windowID == hoverWindowID { return focusInterval }
        return baselineInterval
    }

    private func captureOne(_ snap: (windowID: CGWindowID, displayName: String, frameW: CGFloat, frameH: CGFloat, isOnScreen: Bool)) {
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            snap.windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )

        // Materialise the SkyLight CGImage onto an IOSurface here, on the
        // capture queue. The implicit `ctx.draw` triggers exactly one mach_msg
        // to SkyLight to fetch bytes (same as before), plus any ICC conversion
        // — but it happens here instead of on the main thread during
        // `CA::Transaction::commit()`. Once the surface is GPU-shareable,
        // CoreAnimation can hand it straight to the compositor.
        let surface: IOSurface? = {
            guard let image else { return nil }
            return Self.makeIOSurface(from: image)
        }()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if var state = self.states[snap.windowID] {
                state.inFlight = false
                self.states[snap.windowID] = state
            }
            guard let image else {
                logger.warning("CGWindowListCreateImage returned nil for \(snap.displayName) (wid \(snap.windowID)), frame=\(snap.frameW)x\(snap.frameH) onScreen=\(snap.isOnScreen)")
                return
            }
            if image.width <= 1 || image.height <= 1 {
                logger.warning("Tiny image for \(snap.displayName) (wid \(snap.windowID)): \(image.width)x\(image.height)")
                return
            }
            guard let surface else {
                logger.warning("IOSurface materialise failed for \(snap.displayName) (wid \(snap.windowID))")
                return
            }
            self.frameCallback?(snap.windowID, image, surface)
        }
    }

    /// Render `image` onto a fresh IOSurface using sRGB / 32BGRA. The resulting
    /// surface is what we hand to `CALayer.contents`. ARC owns it — once the
    /// next capture's surface replaces it on the layer, the old one drops out.
    private static func makeIOSurface(from image: CGImage) -> IOSurface? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerElement = 4
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerElement)
        let totalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, height * bytesPerRow)
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: bytesPerElement,
            .bytesPerRow: bytesPerRow,
            .allocSize: totalBytes,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }

        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }

        // 32BGRA layout in memory matches little-endian 32-bit word with
        // premultiplied alpha in the high byte. sRGB destination causes any
        // P3 / generic-RGB source to be ICC-converted here, on the capture
        // queue, rather than during CoreAnimation's main-thread commit.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGImageByteOrderInfo.order32Little.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: IOSurfaceGetBaseAddress(surface),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }
}
