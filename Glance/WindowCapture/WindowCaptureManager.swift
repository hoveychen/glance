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
        let windows = trackedWindows

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for (windowID, info) in windows {
                guard let image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                ) else {
                    logger.warning("CGWindowListCreateImage returned nil for \(info.displayName) (wid \(windowID)), frame=\(info.frame.width)x\(info.frame.height) onScreen=\(info.isOnScreen)")
                    continue
                }

                if image.width <= 1 || image.height <= 1 {
                    logger.warning("Tiny image for \(info.displayName) (wid \(windowID)): \(image.width)x\(image.height)")
                    continue
                }

                DispatchQueue.main.async {
                    self?.frameCallback?(windowID, image)
                }
            }
        }
    }
}
