import AppKit

/// iTerm-style preferences window: an NSToolbar at the top selects between
/// category panels swapped into the window's content view. Each panel is a
/// view controller with a fixed `preferredContentSize`; the window resizes
/// (animated) when the user changes panels.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private struct Panel {
        let identifier: NSToolbarItem.Identifier
        let label: String
        let symbol: String
        let make: () -> NSViewController
    }

    private let panels: [Panel] = [
        Panel(identifier: .init("General"),
              label: NSLocalizedString("settings.panel.general",
                                       value: "General",
                                       comment: "Settings toolbar — General panel label"),
              symbol: "gearshape",
              make: { GeneralSettingsViewController() }),
        Panel(identifier: .init("Window"),
              label: NSLocalizedString("settings.panel.window",
                                       value: "Window",
                                       comment: "Settings toolbar — Window panel label"),
              symbol: "macwindow",
              make: { WindowSettingsViewController() }),
    ]

    private var current: NSViewController?

    private convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("settings.window.title",
                                      value: "Settings",
                                      comment: "Title bar for the Settings window")
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("GlanceSettingsWindow")
        self.init(window: win)
        win.delegate = self
        configureToolbar()
        select(panels[0].identifier)
    }

    private func configureToolbar() {
        guard let window = window else { return }
        let toolbar = NSToolbar(identifier: "GlanceSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = panels.first?.identifier
        window.toolbar = toolbar
        if #available(macOS 11, *) {
            window.toolbarStyle = .preference
        }
    }

    /// Show and bring the window to the front.
    func showWindow() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ identifier: NSToolbarItem.Identifier) {
        guard let window = window,
              let panel = panels.first(where: { $0.identifier == identifier }) else { return }

        let vc = panel.make()
        let target = vc.preferredContentSize == .zero
            ? NSSize(width: 540, height: 320)
            : vc.preferredContentSize

        // Compute the new window frame so the title bar stays put while the
        // content area grows / shrinks downward (matches macOS Preferences).
        let newContentRect = NSRect(origin: .zero, size: target)
        var newFrame = window.frameRect(forContentRect: newContentRect)
        let oldFrame = window.frame
        newFrame.origin.x = oldFrame.origin.x
        newFrame.origin.y = oldFrame.maxY - newFrame.height

        current?.view.removeFromSuperview()
        current = vc

        window.contentViewController = vc
        window.setFrame(newFrame, display: true, animate: window.isVisible)
        let format = NSLocalizedString("settings.window.titleWithPanel",
                                       value: "Settings — %@",
                                       comment: "Settings window title combined with the current panel name, e.g. 'Settings — General'")
        window.title = String(format: format, panel.label)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let panel = panels.first(where: { $0.identifier == itemIdentifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = panel.label
        item.paletteLabel = panel.label
        item.image = NSImage(systemSymbolName: panel.symbol,
                             accessibilityDescription: panel.label)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panels.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panels.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panels.map(\.identifier)
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        select(sender.itemIdentifier)
    }
}
