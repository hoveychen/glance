import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "Capture")

/// Manages periodic window thumbnail capture using CGWindowListCreateImage.
/// Unlike SCStream, this approach does not trigger the system recording indicator.
final class WindowCaptureManager {

    /// Windows currently being captured.
    private var trackedWindows: [CGWindowID: WindowInfo] = [:]

    /// Callback: (windowID, latestCGImage)
    private var frameCallback: ((CGWindowID, CGImage) -> Void)?

    /// Timer for periodic capture.
    private var captureTimer: Timer?

    /// Capture interval (matches the previous 3 fps SCStream config).
    private let captureInterval: TimeInterval = 1.0 / 3.0

    /// Dedicated serial queue for capture work. Using our own queue instead of
    /// the global concurrent `.userInteractive` queue bounds our thread use to 1.
    /// Why: `CGWindowListCreateImage` can block for seconds when WindowServer /
    /// ScreenCaptureKit's XPC daemon stalls. With async dispatch onto the shared
    /// concurrent pool, each timer tick spawned another blocked thread, saturating
    /// libdispatch's 64-thread soft limit and hanging the whole app (quit included).
    private let captureQueue = DispatchQueue(label: "com.hoveychen.Glance.capture", qos: .userInteractive)

    /// True while a batch is in flight. Read/written only on the main thread.
    /// Timer ticks that fire while a batch is still running are dropped, so a
    /// slow capture never causes queue backlog.
    private var isCapturing = false

    /// Update which windows are being captured.
    func updateCaptures(for windows: [WindowInfo], onFrame: @escaping (CGWindowID, CGImage) -> Void) {
        self.frameCallback = onFrame

        let targetIDs = Set(windows.map(\.windowID))
        trackedWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })

        // Start timer if not running and we have windows to capture
        if !targetIDs.isEmpty && captureTimer == nil {
            startTimer()
        } else if targetIDs.isEmpty {
            stopTimer()
        }
    }

    func stopAll() {
        stopTimer()
        trackedWindows.removeAll()
    }

    // MARK: - Private

    private func startTimer() {
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureAllWindows()
        }
    }

    private func stopTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    private func captureAllWindows() {
        // Drop this tick if the previous batch hasn't finished — avoids piling
        // up work on the capture queue when WindowServer stalls.
        if isCapturing { return }

        // Snapshot the info we need on the main thread to avoid data races.
        // WindowInfo is a reference type whose properties may be mutated on
        // the main thread by WindowTracker while we read on a background queue.
        let snapshots: [(windowID: CGWindowID, isPrivate: Bool, displayName: String, frameW: CGFloat, frameH: CGFloat, isOnScreen: Bool)] =
            trackedWindows.map { (windowID, info) in
                (windowID, info.isPrivateBrowsing, info.displayName, info.frame.width, info.frame.height, info.isOnScreen)
            }

        isCapturing = true
        captureQueue.async { [weak self] in
            defer {
                DispatchQueue.main.async { self?.isCapturing = false }
            }
            for snap in snapshots {
                // Skip private/incognito windows to avoid the macOS
                // "trying to record a private browsing window" alert.
                if snap.isPrivate { continue }

                guard let image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    snap.windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                ) else {
                    logger.warning("CGWindowListCreateImage returned nil for \(snap.displayName) (wid \(snap.windowID)), frame=\(snap.frameW)x\(snap.frameH) onScreen=\(snap.isOnScreen)")
                    continue
                }

                if image.width <= 1 || image.height <= 1 {
                    logger.warning("Tiny image for \(snap.displayName) (wid \(snap.windowID)): \(image.width)x\(image.height)")
                    continue
                }

                DispatchQueue.main.async {
                    self?.frameCallback?(snap.windowID, image)
                }
            }
        }
    }
}
