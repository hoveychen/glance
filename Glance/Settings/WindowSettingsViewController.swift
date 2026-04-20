import AppKit

/// Window-related preferences. Currently exposes the swap resize mode:
/// preserve aspect ratio (default) vs. clamp width / height independently.
final class WindowSettingsViewController: NSViewController {

    private var preserveButton: NSButton!
    private var clampButton: NSButton!
    private var mruGlowCheckbox: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 360))

        let header = NSTextField(labelWithString:
            NSLocalizedString("settings.window.swapResize.header",
                              value: "Swap Resize Behavior",
                              comment: "Window settings section heading"))
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        let explain = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.window.swapResize.explain",
                              value: "When a window is swapped into the Glance work area and is larger than the work area, choose how Glance fits it in.",
                              comment: "Explanation paragraph above the swap-resize radio buttons"))
        explain.font = .systemFont(ofSize: 11, weight: .regular)
        explain.textColor = .secondaryLabelColor
        explain.translatesAutoresizingMaskIntoConstraints = false

        preserveButton = NSButton(radioButtonWithTitle: SwapResizeMode.preserveAspectRatio.displayName,
                                  target: self, action: #selector(modeChanged(_:)))
        preserveButton.identifier = NSUserInterfaceItemIdentifier(SwapResizeMode.preserveAspectRatio.rawValue)
        preserveButton.translatesAutoresizingMaskIntoConstraints = false

        let preserveHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.window.swapResize.preserve.hint",
                              value: "Scale the window down uniformly so it fits, keeping its original proportions. Recommended for most apps.",
                              comment: "Hint for the preserve-aspect-ratio swap-resize option"))
        preserveHint.font = .systemFont(ofSize: 11)
        preserveHint.textColor = .secondaryLabelColor
        preserveHint.translatesAutoresizingMaskIntoConstraints = false

        clampButton = NSButton(radioButtonWithTitle: SwapResizeMode.clampMax.displayName,
                               target: self, action: #selector(modeChanged(_:)))
        clampButton.identifier = NSUserInterfaceItemIdentifier(SwapResizeMode.clampMax.rawValue)
        clampButton.translatesAutoresizingMaskIntoConstraints = false

        let clampHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.window.swapResize.clamp.hint",
                              value: "Clip the window's width and height independently to the work area. Useful when an app behaves better at full work-area size than at a scaled-down version.",
                              comment: "Hint for the clamp-max swap-resize option"))
        clampHint.font = .systemFont(ofSize: 11)
        clampHint.textColor = .secondaryLabelColor
        clampHint.translatesAutoresizingMaskIntoConstraints = false

        let mruHeader = NSTextField(labelWithString:
            NSLocalizedString("settings.window.mruGlow.header",
                              value: "Recent Thumbnail Highlight",
                              comment: "Window settings section heading for MRU glow"))
        mruHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        mruHeader.translatesAutoresizingMaskIntoConstraints = false

        mruGlowCheckbox = NSButton(checkboxWithTitle:
            NSLocalizedString("settings.window.mruGlow.toggle",
                              value: "Highlight recently used thumbnails",
                              comment: "Checkbox: enable MRU recency glow on thumbnails"),
            target: self, action: #selector(mruGlowToggled(_:)))
        mruGlowCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let mruHint = NSTextField(wrappingLabelWithString:
            NSLocalizedString("settings.window.mruGlow.hint",
                              value: "Adds a yellow halo around the 3 most recently clicked, dragged, or pinned thumbnails. The newest glows brightest; older ones dim. Helps locate what you were just working on when many windows are open.",
                              comment: "Hint text for MRU glow checkbox"))
        mruHint.font = .systemFont(ofSize: 11)
        mruHint.textColor = .secondaryLabelColor
        mruHint.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, explain, preserveButton, preserveHint, clampButton, clampHint,
                  mruHeader, mruGlowCheckbox, mruHint] {
            root.addSubview(v!)
        }

        let leading: CGFloat = 24
        let hintIndent: CGFloat = 22
        let trailing: CGFloat = -24

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: leading),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            explain.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            explain.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            explain.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            preserveButton.topAnchor.constraint(equalTo: explain.bottomAnchor, constant: 16),
            preserveButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            preserveHint.topAnchor.constraint(equalTo: preserveButton.bottomAnchor, constant: 2),
            preserveHint.leadingAnchor.constraint(equalTo: preserveButton.leadingAnchor, constant: hintIndent),
            preserveHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            clampButton.topAnchor.constraint(equalTo: preserveHint.bottomAnchor, constant: 14),
            clampButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            clampHint.topAnchor.constraint(equalTo: clampButton.bottomAnchor, constant: 2),
            clampHint.leadingAnchor.constraint(equalTo: clampButton.leadingAnchor, constant: hintIndent),
            clampHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            mruHeader.topAnchor.constraint(equalTo: clampHint.bottomAnchor, constant: 28),
            mruHeader.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            mruHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),

            mruGlowCheckbox.topAnchor.constraint(equalTo: mruHeader.bottomAnchor, constant: 10),
            mruGlowCheckbox.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            mruHint.topAnchor.constraint(equalTo: mruGlowCheckbox.bottomAnchor, constant: 4),
            mruHint.leadingAnchor.constraint(equalTo: mruGlowCheckbox.leadingAnchor, constant: hintIndent),
            mruHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: trailing),
            mruHint.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        ])

        view = root
        preferredContentSize = NSSize(width: 540, height: 360)

        syncFromSettings()
    }

    private func syncFromSettings() {
        let mode = Settings.shared.swapResizeMode
        preserveButton.state = (mode == .preserveAspectRatio) ? .on : .off
        clampButton.state    = (mode == .clampMax)            ? .on : .off
        mruGlowCheckbox.state = Settings.shared.mruGlowEnabled ? .on : .off
    }

    @objc private func modeChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let mode = SwapResizeMode(rawValue: raw) else { return }
        Settings.shared.swapResizeMode = mode
        syncFromSettings()
    }

    @objc private func mruGlowToggled(_ sender: NSButton) {
        Settings.shared.mruGlowEnabled = (sender.state == .on)
    }
}
