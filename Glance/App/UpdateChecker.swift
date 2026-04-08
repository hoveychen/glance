import AppKit
import os.log

private let logger = Logger(subsystem: "com.hoveychen.Glance", category: "UpdateChecker")

final class UpdateChecker {

    static let shared = UpdateChecker()

    private let repo = "hoveychen/glance"
    private let checkIntervalSeconds: TimeInterval = 24 * 60 * 60  // 1 day

    private init() {}

    // MARK: - Public

    /// Check for updates automatically (once per day).
    func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheckTime")
        let now = Date().timeIntervalSince1970
        guard now - lastCheck >= checkIntervalSeconds else {
            logger.info("Skipping update check – last checked \(Int(now - lastCheck))s ago.")
            return
        }
        check(silent: true)
    }

    /// Check for updates explicitly (always hits the API, always shows result).
    func checkNow() {
        check(silent: false)
    }

    // MARK: - Private

    private func check(silent: Bool) {
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(data: data, response: response, error: error, silent: silent)
            }
        }.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, silent: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheckTime")

        if let error {
            logger.error("Update check failed: \(error.localizedDescription)")
            if !silent {
                showAlert(
                    title: "Update Check Failed",
                    message: "Could not connect to GitHub.\n\(error.localizedDescription)",
                    showDownload: false
                )
            }
            return
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            logger.error("Update check: failed to parse response.")
            if !silent {
                showAlert(title: "Update Check Failed", message: "Could not parse the release information from GitHub.", showDownload: false)
            }
            return
        }

        let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let htmlURL = json["html_url"] as? String

        logger.info("Current version: \(currentVersion), latest: \(latestVersion)")

        if compareVersions(latestVersion, isNewerThan: currentVersion) {
            let body = (json["body"] as? String)
            showUpdateAvailable(latestVersion: latestVersion, releaseNotes: body, htmlURL: htmlURL)
        } else if !silent {
            showAlert(
                title: "You're Up to Date",
                message: "Glance \(currentVersion) is the latest version.",
                showDownload: false
            )
        }
    }

    /// Simple numeric version comparison (e.g. "1.2.3" > "1.2.0").
    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // MARK: - UI

    private func showUpdateAvailable(latestVersion: String, releaseNotes: String?, htmlURL: String?) {
        let alert = NSAlert()
        alert.messageText = "New Version Available"
        alert.informativeText = "Glance \(latestVersion) is available. You are currently running \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")."
        if let notes = releaseNotes, !notes.isEmpty {
            alert.informativeText += "\n\nRelease notes:\n\(notes)"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let downloadURL = htmlURL ?? "https://github.com/\(repo)/releases/latest"
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showAlert(title: String, message: String, showDownload: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        if showDownload {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "https://github.com/\(repo)/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
