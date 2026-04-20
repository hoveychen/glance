import AppKit

/// General preferences: launch-at-login, Dock icon visibility, and UI language.
final class GeneralSettingsViewController: NSViewController {

    private var launchAtLoginButton: NSButton!
    private var showDockIconButton: NSButton!
    private var languagePopup: NSPopUpButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 340))

        let startupHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.general.startup.header",
                              value: "Startup",
                              comment: "General settings section — Startup heading"))
        startupHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        startupHeader.translatesAutoresizingMaskIntoConstraints = false

        launchAtLoginButton = NSButton(checkboxWithTitle:
            NSLocalizedString("settings.general.launchAtLogin",
                              value: "Launch Glance at login",
                              comment: "Checkbox: auto-start Glance at user login"),
                                       target: self,
                                       action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginButton.translatesAutoresizingMaskIntoConstraints = false

        let launchHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.general.launchAtLogin.hint",
                              value: "Start Glance automatically when you sign in. You can also manage this in System Settings → General → Login Items.",
                              comment: "Hint below the launch-at-login checkbox"))
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.textColor = .secondaryLabelColor
        launchHint.translatesAutoresizingMaskIntoConstraints = false

        let appearanceHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.general.appearance.header",
                              value: "Appearance",
                              comment: "General settings section — Appearance heading"))
        appearanceHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        appearanceHeader.translatesAutoresizingMaskIntoConstraints = false

        showDockIconButton = NSButton(checkboxWithTitle:
            NSLocalizedString("settings.general.showDockIcon",
                              value: "Show Glance icon in the Dock",
                              comment: "Checkbox: show Glance in the Dock"),
                                      target: self,
                                      action: #selector(showDockIconToggled(_:)))
        showDockIconButton.translatesAutoresizingMaskIntoConstraints = false

        let dockHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.general.showDockIcon.hint",
                              value: "When off, Glance runs as a menu bar app. You can still reach it from the status bar icon.",
                              comment: "Hint below the show-Dock-icon checkbox"))
        dockHint.font = .systemFont(ofSize: 11)
        dockHint.textColor = .secondaryLabelColor
        dockHint.translatesAutoresizingMaskIntoConstraints = false

        let languageHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.general.language.header",
                              value: "Language",
                              comment: "General settings section — Language heading"))
        languageHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        languageHeader.translatesAutoresizingMaskIntoConstraints = false

        let languageLabel = NSTextField(labelWithString:
            NSLocalizedString("settings.general.language.label",
                              value: "Display language:",
                              comment: "Label preceding the language popup"))
        languageLabel.translatesAutoresizingMaskIntoConstraints = false

        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        for mode in LanguageOverride.allCases {
            languagePopup.addItem(withTitle: mode.displayName)
            languagePopup.lastItem?.representedObject = mode
        }

        let languageHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.general.language.hint",
                              value: "Changes take effect after Glance restarts.",
                              comment: "Hint below the language popup"))
        languageHint.font = .systemFont(ofSize: 11)
        languageHint.textColor = .secondaryLabelColor
        languageHint.translatesAutoresizingMaskIntoConstraints = false

        for v in [startupHeader, launchAtLoginButton, launchHint,
                  appearanceHeader, showDockIconButton, dockHint,
                  languageHeader, languageLabel, languagePopup, languageHint] {
            root.addSubview(v!)
        }

        let leading: CGFloat = 24
        let hintIndent: CGFloat = 22
        let trailing: CGFloat = -24

        NSLayoutConstraint.activate([
            startupHeader.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            startupHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: leading),
            startupHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            launchAtLoginButton.topAnchor.constraint(equalTo: startupHeader.bottomAnchor, constant: 10),
            launchAtLoginButton.leadingAnchor.constraint(equalTo: startupHeader.leadingAnchor),

            launchHint.topAnchor.constraint(equalTo: launchAtLoginButton.bottomAnchor, constant: 2),
            launchHint.leadingAnchor.constraint(equalTo: launchAtLoginButton.leadingAnchor, constant: hintIndent),
            launchHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            appearanceHeader.topAnchor.constraint(equalTo: launchHint.bottomAnchor, constant: 20),
            appearanceHeader.leadingAnchor.constraint(equalTo: startupHeader.leadingAnchor),
            appearanceHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            showDockIconButton.topAnchor.constraint(equalTo: appearanceHeader.bottomAnchor, constant: 10),
            showDockIconButton.leadingAnchor.constraint(equalTo: appearanceHeader.leadingAnchor),

            dockHint.topAnchor.constraint(equalTo: showDockIconButton.bottomAnchor, constant: 2),
            dockHint.leadingAnchor.constraint(equalTo: showDockIconButton.leadingAnchor, constant: hintIndent),
            dockHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            languageHeader.topAnchor.constraint(equalTo: dockHint.bottomAnchor, constant: 20),
            languageHeader.leadingAnchor.constraint(equalTo: startupHeader.leadingAnchor),
            languageHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            languageLabel.topAnchor.constraint(equalTo: languageHeader.bottomAnchor, constant: 10),
            languageLabel.leadingAnchor.constraint(equalTo: languageHeader.leadingAnchor),
            languageLabel.centerYAnchor.constraint(equalTo: languagePopup.centerYAnchor),

            languagePopup.leadingAnchor.constraint(equalTo: languageLabel.trailingAnchor, constant: 8),
            languagePopup.topAnchor.constraint(equalTo: languageHeader.bottomAnchor, constant: 8),

            languageHint.topAnchor.constraint(equalTo: languagePopup.bottomAnchor, constant: 4),
            languageHint.leadingAnchor.constraint(equalTo: languageHeader.leadingAnchor),
            languageHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),
            languageHint.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        ])

        view = root
        preferredContentSize = NSSize(width: 540, height: 340)

        syncFromSettings()
    }

    private func syncFromSettings() {
        launchAtLoginButton.state = LaunchAtLogin.isEnabled ? .on : .off
        showDockIconButton.state  = Settings.shared.showDockIcon ? .on : .off
        let current = Settings.shared.languageOverride
        if let idx = LanguageOverride.allCases.firstIndex(of: current) {
            languagePopup.selectItem(at: idx)
        }
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let wantEnabled = (sender.state == .on)
        let ok = LaunchAtLogin.setEnabled(wantEnabled)
        if !ok {
            // Revert the checkbox to whatever the system actually reports.
            syncFromSettings()
            NSSound.beep()
        }
    }

    @objc private func showDockIconToggled(_ sender: NSButton) {
        Settings.shared.showDockIcon = (sender.state == .on)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let mode = item.representedObject as? LanguageOverride else { return }
        let previous = Settings.shared.languageOverride
        guard mode != previous else { return }
        Settings.shared.languageOverride = mode
        promptRestart()
    }

    private func promptRestart() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("settings.general.language.restart.title",
                                              value: "Restart Glance to apply the new language?",
                                              comment: "Alert title after changing language")
        alert.informativeText = NSLocalizedString("settings.general.language.restart.body",
                                                  value: "The interface language updates the next time Glance launches.",
                                                  comment: "Alert body after changing language")
        alert.addButton(withTitle: NSLocalizedString("settings.general.language.restart.now",
                                                     value: "Restart Now",
                                                     comment: "Alert button — restart immediately"))
        alert.addButton(withTitle: NSLocalizedString("settings.general.language.restart.later",
                                                     value: "Later",
                                                     comment: "Alert button — restart later"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
