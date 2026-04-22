import Foundation

/// Localized strings shown in Glance's main menu bar and status bar menu.
/// Centralized so the two menus stay in sync and translators have one
/// source to review.
enum GlanceMenuStrings {
    /// About menu item. `%@` ×2: short version, build number.
    static var aboutFormat: String {
        NSLocalizedString("menu.aboutGlanceFormat",
                          value: "About Glance %@ (%@)",
                          comment: "About menu item; first %@ is version, second is build number")
    }

    /// Main-menu form with the user's current hotkey glyphs appended.
    /// `shortcut` is a pre-formatted glyph string like "⌃⌥H".
    static func toggleFull(shortcut: String) -> String {
        let fmt = NSLocalizedString("menu.toggleGlance.fullFormat",
                                    value: "Toggle Glance  %@",
                                    comment: "Main menu: toggle Glance; %@ is the user's configured shortcut glyphs")
        return String(format: fmt, shortcut)
    }

    /// Status-bar form: shorter `Toggle (⌃⌥H)` with the current hotkey.
    static func toggleShort(shortcut: String) -> String {
        let fmt = NSLocalizedString("menu.toggleGlance.shortFormat",
                                    value: "Toggle (%@)",
                                    comment: "Status bar menu: toggle Glance; %@ is the user's configured shortcut glyphs")
        return String(format: fmt, shortcut)
    }

    static var showGuide: String {
        NSLocalizedString("menu.showGuide",
                          value: "Show Guide",
                          comment: "Menu: re-show the onboarding guide")
    }

    static var checkForUpdates: String {
        NSLocalizedString("menu.checkForUpdates",
                          value: "Check for Updates…",
                          comment: "Menu: check for Glance updates")
    }

    static var settings: String {
        NSLocalizedString("menu.settings",
                          value: "Settings…",
                          comment: "Menu: open the Settings window")
    }

    static var copyDiagnostics: String {
        NSLocalizedString("menu.copyDiagnostics",
                          value: "Copy Diagnostics",
                          comment: "Menu: copy diagnostic info to clipboard")
    }

    static var dumpSystemSample: String {
        NSLocalizedString("menu.dumpSystemSample",
                          value: "Dump System Sample…",
                          comment: "Menu: dump detailed system sample for bug reports")
    }

    static var hideGlance: String {
        NSLocalizedString("menu.hideGlance",
                          value: "Hide Glance",
                          comment: "Main menu: hide Glance (standard macOS command)")
    }

    static var hideOthers: String {
        NSLocalizedString("menu.hideOthers",
                          value: "Hide Others",
                          comment: "Main menu: hide other applications (standard macOS command)")
    }

    static var showAll: String {
        NSLocalizedString("menu.showAll",
                          value: "Show All",
                          comment: "Main menu: show all hidden applications (standard macOS command)")
    }

    static var quitGlance: String {
        NSLocalizedString("menu.quitGlance",
                          value: "Quit Glance",
                          comment: "Main menu: quit Glance")
    }

    static var quit: String {
        NSLocalizedString("menu.quit",
                          value: "Quit",
                          comment: "Status bar menu: quit (shorter form)")
    }
}
