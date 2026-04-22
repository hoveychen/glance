import AppKit

/// A focusable recorder view that captures a modifier+key combination when
/// clicked. While recording, a local monitor swallows the next valid keyDown
/// and returns it to the host. Esc cancels; bare keys (no modifier) are
/// rejected so the user can't accidentally bind a printable key.
final class HotkeyRecorderView: NSView {

    /// Called with the newly-captured combo when recording completes
    /// successfully. Not fired on cancel.
    var onCommit: ((ActivationHotkey) -> Void)?

    var hotkey: ActivationHotkey = .default {
        didSet { refreshTitle() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let backgroundView = NSView()
    private var isRecording = false {
        didSet { refreshAppearance() }
    }
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var localMonitor: Any?
    private var flagsMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.borderWidth = 1
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])

        refreshTitle()
        refreshAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        currentModifiers = []
        window?.makeFirstResponder(self)

        // Local keyDown/flagsChanged monitors let us capture the very next
        // keystroke without competing with the existing global hotkey.
        // Swallowing the event (returning nil) prevents the new combo from
        // incidentally triggering menus or text fields.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isRecording else { return ev }
            self.handleKeyDown(ev)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            guard let self, self.isRecording else { return ev }
            self.currentModifiers = ev.modifierFlags.intersection(ActivationHotkey.allowedModifiers)
            self.refreshTitle()
            return ev
        }
    }

    private func stopRecording() {
        isRecording = false
        currentModifiers = []
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        refreshTitle()
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Esc (keyCode 53) cancels without committing.
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        let mods = event.modifierFlags.intersection(ActivationHotkey.allowedModifiers)
        guard !mods.isEmpty else {
            // Bare key — flash the label and keep listening instead of
            // committing something un-triggerable.
            NSSound.beep()
            return
        }
        let combo = ActivationHotkey(modifiers: mods, keyCode: event.keyCode)
        hotkey = combo
        stopRecording()
        onCommit?(combo)
    }

    private func refreshTitle() {
        if isRecording {
            var preview = ""
            let m = currentModifiers.intersection(ActivationHotkey.allowedModifiers)
            if m.contains(.control) { preview += "\u{2303}" }
            if m.contains(.option)  { preview += "\u{2325}" }
            if m.contains(.shift)   { preview += "\u{21E7}" }
            if m.contains(.command) { preview += "\u{2318}" }
            let hint = NSLocalizedString("settings.shortcut.recording",
                                         value: "Press shortcut… (Esc to cancel)",
                                         comment: "Placeholder while the hotkey recorder is waiting for a keypress")
            titleLabel.stringValue = preview.isEmpty ? hint : "\(preview)…"
            titleLabel.textColor = .secondaryLabelColor
        } else {
            titleLabel.stringValue = hotkey.displayString
            titleLabel.textColor = .labelColor
        }
    }

    private func refreshAppearance() {
        let color: NSColor = isRecording ? .controlAccentColor : .separatorColor
        backgroundView.layer?.borderColor = color.cgColor
        backgroundView.layer?.backgroundColor =
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.1)
                         : NSColor.controlBackgroundColor).cgColor
    }

    deinit {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
    }
}

/// Shortcut preferences: a hint-trigger picker (the main customization — which
/// modifier key short-tap flashes the hint letters), the activation hotkey
/// recorder (toggles the work area from anywhere), and a read-only tips block.
final class ShortcutSettingsViewController: NSViewController {

    private var triggerPopup: NSPopUpButton!
    private var recorder: HotkeyRecorderView!
    private var resetButton: NSButton!
    private var tipsLabel: NSTextField!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))

        // MARK: Hint Trigger section

        let triggerHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.shortcut.hintTrigger.header",
                              value: "Hint Trigger Key",
                              comment: "Shortcut panel section — hint trigger heading"))
        triggerHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        triggerHeader.translatesAutoresizingMaskIntoConstraints = false

        let triggerExplain = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.shortcut.hintTrigger.explain",
                              value: "When Glance is active, tap this modifier key (briefly, by itself) to flash hint letters on every thumbnail and pick a window with one keystroke.",
                              comment: "Explanation above the hint trigger picker"))
        triggerExplain.font = .systemFont(ofSize: 11)
        triggerExplain.textColor = .secondaryLabelColor
        triggerExplain.translatesAutoresizingMaskIntoConstraints = false

        triggerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        triggerPopup.translatesAutoresizingMaskIntoConstraints = false
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        for key in HintTriggerKey.allCases {
            triggerPopup.addItem(withTitle: key.displayName)
            triggerPopup.lastItem?.representedObject = key.rawValue
        }
        selectCurrentTriggerInPopup()

        // MARK: Activation Hotkey section

        let activationHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.shortcut.activation.header",
                              value: "Activation Hotkey",
                              comment: "Shortcut panel section — activation hotkey heading"))
        activationHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        activationHeader.translatesAutoresizingMaskIntoConstraints = false

        let activationExplain = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.shortcut.activation.explain",
                              value: "This key combination toggles the Glance work area on and off from anywhere on your Mac. Click the field and press the new combination you want.",
                              comment: "Explanation above the hotkey recorder"))
        activationExplain.font = .systemFont(ofSize: 11)
        activationExplain.textColor = .secondaryLabelColor
        activationExplain.translatesAutoresizingMaskIntoConstraints = false

        recorder = HotkeyRecorderView()
        recorder.hotkey = Settings.shared.activationHotkey
        recorder.onCommit = { combo in
            Settings.shared.activationHotkey = combo
        }

        resetButton = NSButton(title:
            NSLocalizedString("settings.shortcut.activation.reset",
                              value: "Reset to Default",
                              comment: "Button that restores the default activation hotkey"),
                               target: self,
                               action: #selector(resetTapped))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let activationHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.shortcut.activation.hint",
                              value: "At least one of ⌃ ⌥ ⇧ ⌘ must be part of the combo. Bare keys are rejected so Glance won't trigger while you type.",
                              comment: "Hint below the hotkey recorder"))
        activationHint.font = .systemFont(ofSize: 11)
        activationHint.textColor = .secondaryLabelColor
        activationHint.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Tips section

        let tipsHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.shortcut.tips.header",
                              value: "How to Use the Hotkey",
                              comment: "Shortcut panel section — tips heading"))
        tipsHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        tipsHeader.translatesAutoresizingMaskIntoConstraints = false

        tipsLabel = NSTextField(wrappingLabelWithString: tipsBody())
        tipsLabel.font = .systemFont(ofSize: 12)
        tipsLabel.textColor = .labelColor
        tipsLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [triggerHeader, triggerExplain, triggerPopup,
                  activationHeader, activationExplain, recorder, resetButton,
                  activationHint, tipsHeader, tipsLabel] {
            root.addSubview(v!)
        }

        let leading: CGFloat = 24
        let trailing: CGFloat = -24

        NSLayoutConstraint.activate([
            triggerHeader.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            triggerHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: leading),
            triggerHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            triggerExplain.topAnchor.constraint(equalTo: triggerHeader.bottomAnchor, constant: 6),
            triggerExplain.leadingAnchor.constraint(equalTo: triggerHeader.leadingAnchor),
            triggerExplain.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            triggerPopup.topAnchor.constraint(equalTo: triggerExplain.bottomAnchor, constant: 10),
            triggerPopup.leadingAnchor.constraint(equalTo: triggerHeader.leadingAnchor),
            triggerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            activationHeader.topAnchor.constraint(equalTo: triggerPopup.bottomAnchor, constant: 28),
            activationHeader.leadingAnchor.constraint(equalTo: triggerHeader.leadingAnchor),
            activationHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            activationExplain.topAnchor.constraint(equalTo: activationHeader.bottomAnchor, constant: 6),
            activationExplain.leadingAnchor.constraint(equalTo: activationHeader.leadingAnchor),
            activationExplain.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            recorder.topAnchor.constraint(equalTo: activationExplain.bottomAnchor, constant: 12),
            recorder.leadingAnchor.constraint(equalTo: activationHeader.leadingAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 220),

            resetButton.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 10),
            resetButton.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),

            activationHint.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 8),
            activationHint.leadingAnchor.constraint(equalTo: activationHeader.leadingAnchor),
            activationHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            tipsHeader.topAnchor.constraint(equalTo: activationHint.bottomAnchor, constant: 28),
            tipsHeader.leadingAnchor.constraint(equalTo: triggerHeader.leadingAnchor),
            tipsHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            tipsLabel.topAnchor.constraint(equalTo: tipsHeader.bottomAnchor, constant: 8),
            tipsLabel.leadingAnchor.constraint(equalTo: triggerHeader.leadingAnchor),
            tipsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),
            tipsLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        ])

        view = root
        preferredContentSize = NSSize(width: 560, height: 560)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: Settings.didChangeNotification,
            object: nil
        )
    }

    private func tipsBody() -> String {
        let glyph = Settings.shared.hintTriggerKey.displayGlyph
        let fmt = NSLocalizedString("settings.shortcut.tips.bodyFormat",
            value: """
            • Press your activation hotkey to enter Glance. Press it again to exit and restore every window.
            • Once active, tap %@ by itself to flash hint letters on each thumbnail — hit a letter to swap that window into the work area.
            • In hint mode, press # first to switch to Pin mode: the next hint letter pins that window as a side reference.
            • Shift-click a hint pill (or press Shift+letter) to rename it. Typed letters become permanent reservations, so the same key always reaches the same window.
            • Drag a thumbnail onto the left / right edge of the work area to pin it. Drag a pinned window's × badge to unpin.
            """,
            comment: "Tips body. %@ is replaced with the hint trigger modifier glyph.")
        return String(format: fmt, glyph)
    }

    private func selectCurrentTriggerInPopup() {
        let raw = Settings.shared.hintTriggerKey.rawValue
        for item in triggerPopup.itemArray {
            if (item.representedObject as? String) == raw {
                triggerPopup.select(item)
                return
            }
        }
    }

    @objc private func triggerChanged() {
        guard let raw = triggerPopup.selectedItem?.representedObject as? String,
              let key = HintTriggerKey(rawValue: raw) else { return }
        Settings.shared.hintTriggerKey = key
        tipsLabel.stringValue = tipsBody()
    }

    @objc private func resetTapped() {
        Settings.shared.activationHotkey = .default
        recorder.hotkey = .default
    }

    @objc private func settingsDidChange() {
        // Keep controls in sync when another surface mutates the settings.
        let currentHotkey = Settings.shared.activationHotkey
        if recorder.hotkey != currentHotkey {
            recorder.hotkey = currentHotkey
        }
        selectCurrentTriggerInPopup()
        tipsLabel.stringValue = tipsBody()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
