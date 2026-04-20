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
                let title = NSLocalizedString("update.checkFailed.title",
                                              value: "Update Check Failed",
                                              comment: "Alert title when update check cannot reach GitHub or parse the response")
                let bodyFormat = NSLocalizedString("update.checkFailed.network",
                                                   value: "Could not connect to GitHub.\n%@",
                                                   comment: "Alert body for network failure; %@ is the underlying error description")
                showAlert(
                    title: title,
                    message: String(format: bodyFormat, error.localizedDescription),
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
                showAlert(
                    title: NSLocalizedString("update.checkFailed.title",
                                             value: "Update Check Failed",
                                             comment: "Alert title when update check cannot reach GitHub or parse the response"),
                    message: NSLocalizedString("update.checkFailed.parse",
                                               value: "Could not parse the release information from GitHub.",
                                               comment: "Alert body when the GitHub release JSON is malformed"),
                    showDownload: false
                )
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
            let bodyFormat = NSLocalizedString("update.upToDate.bodyFormat",
                                               value: "Glance %@ is the latest version.",
                                               comment: "Alert body when the installed build is already latest; %@ is version")
            showAlert(
                title: NSLocalizedString("update.upToDate.title",
                                         value: "You're Up to Date",
                                         comment: "Alert title when the installed build is already latest"),
                message: String(format: bodyFormat, currentVersion),
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
        alert.messageText = NSLocalizedString("update.available.title",
                                              value: "New Version Available",
                                              comment: "Alert title when a newer release is available on GitHub")
        let bodyFormat = NSLocalizedString("update.available.bodyFormat",
                                           value: "Glance %1$@ is available. You are currently running %2$@.",
                                           comment: "Alert body for new version; %1$@ latest, %2$@ current")
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        alert.informativeText = String(format: bodyFormat, latestVersion, currentVersion)
        if let notes = releaseNotes, !notes.isEmpty {
            let notesFormat = NSLocalizedString("update.available.releaseNotesFormat",
                                                value: "\n\nRelease notes:\n%@",
                                                comment: "Appended to the update-available alert; %@ is the raw release notes body")
            alert.informativeText += String(format: notesFormat, notes)
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("update.button.download",
                                                     value: "Download",
                                                     comment: "Update alert button — open release page"))
        alert.addButton(withTitle: NSLocalizedString("update.button.later",
                                                     value: "Later",
                                                     comment: "Update alert button — dismiss"))

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
        let okTitle = NSLocalizedString("common.ok",
                                        value: "OK",
                                        comment: "Generic OK button used in alerts")
        if showDownload {
            alert.addButton(withTitle: NSLocalizedString("update.button.download",
                                                         value: "Download",
                                                         comment: "Update alert button — open release page"))
            alert.addButton(withTitle: okTitle)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "https://github.com/\(repo)/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            alert.addButton(withTitle: okTitle)
            alert.runModal()
        }
    }
}
