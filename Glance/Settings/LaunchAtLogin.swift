import Foundation
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "LaunchAtLogin")

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+). The system tracks the
/// registration state itself; callers read `isEnabled` from that source rather
/// than from UserDefaults so a user toggling it off in System Settings →
/// Login Items is reflected here on next read.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success, false on failure. On failure the caller should
    /// refresh its UI from `isEnabled` to avoid showing a stale checkbox.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            logger.error("LaunchAtLogin toggle to \(enabled, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
