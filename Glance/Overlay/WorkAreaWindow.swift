import AppKit

/// A draggable, resizable frosted-glass "desk" where the main window is placed.
final class WorkAreaWindow: NSWindow {

    var onExit: (() -> Void)?
    var onQuickSwitch: (() -> Void)?

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)  // Below all normal windows
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Frosted glass effect
        let effectView = NSVisualEffectView(frame: contentView!.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effectView.layer?.borderWidth = 1
        effectView.autoresizingMask = [.width, .height]
        contentView?.addSubview(effectView)

        // Subtle label
        let label = NSTextField(labelWithString: "Work Area")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.3)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -8)
        ])

        // Exit button in bottom-left
        let exitButton = NSButton(title: "✕ Exit", target: self, action: #selector(exitClicked))
        exitButton.bezelStyle = .recessed
        exitButton.isBordered = false
        exitButton.font = .systemFont(ofSize: 11, weight: .medium)
        exitButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            exitButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        // Quick-switch button in bottom-right
        let switchButton = NSButton(title: "⇥ Switch (⌥)", target: self, action: #selector(switchClicked))
        switchButton.bezelStyle = .recessed
        switchButton.isBordered = false
        switchButton.font = .systemFont(ofSize: 11, weight: .medium)
        switchButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(switchButton)
        NSLayoutConstraint.activate([
            switchButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            switchButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        minSize = NSSize(width: 400, height: 300)
    }

    @objc private func exitClicked() {
        onExit?()
    }

    @objc private func switchClicked() {
        onQuickSwitch?()
    }

    // Allow becoming key so it can be resized, but not main
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Padding inside the work area where the main window should not cover.
    static let paddingTop: CGFloat = 8
    static let paddingLeft: CGFloat = 8
    static let paddingRight: CGFloat = 8
    static let paddingBottom: CGFloat = 28  // Room for "Work Area" label

    /// The full frame in CG coordinates (top-left origin).
    var cgFrame: CGRect {
        // Must use primary screen height for CG↔AppKit conversion (both coordinate
        // systems are anchored to the primary screen). NSScreen.main returns the
        // screen with keyboard focus, which is wrong when the work area is on a
        // secondary display.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: frame.origin.x,
            y: primaryH - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// The usable interior in CG coordinates (top-left origin), inset by padding.
    var usableCGFrame: CGRect {
        let full = cgFrame
        return CGRect(
            x: full.origin.x + Self.paddingLeft,
            y: full.origin.y + Self.paddingTop,
            width: full.width - Self.paddingLeft - Self.paddingRight,
            height: full.height - Self.paddingTop - Self.paddingBottom
        )
    }

    /// The frame in AppKit coordinates (bottom-left origin).
    var appKitFrame: CGRect { frame }
}
