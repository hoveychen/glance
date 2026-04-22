import AppKit

/// In-app override for UI language. Writes to the `AppleLanguages`
/// user-defaults key, which macOS reads at launch. `.system` removes the
/// override so the app follows the system's language preference.
enum LanguageOverride: String, CaseIterable {
    case system
    case english
    case simplifiedChinese

    var displayName: String {
        switch self {
        case .system:
            return NSLocalizedString("language.system",
                                     value: "Follow System",
                                     comment: "Language override — follow system language")
        case .english:
            return NSLocalizedString("language.english",
                                     value: "English",
                                     comment: "Language override — English")
        case .simplifiedChinese:
            return NSLocalizedString("language.simplifiedChinese",
                                     value: "简体中文",
                                     comment: "Language override — Simplified Chinese")
        }
    }

    fileprivate var appleLanguagesValue: [String]? {
        switch self {
        case .system:             return nil
        case .english:            return ["en"]
        case .simplifiedChinese:  return ["zh-Hans"]
        }
    }
}

/// How a window should be resized when swapped into the work area
/// if its native size exceeds the work area.
enum SwapResizeMode: String, CaseIterable {
    /// Scale the window down uniformly, preserving its aspect ratio.
    case preserveAspectRatio
    /// Clamp width and height independently to the work area's bounds.
    /// May distort the aspect ratio.
    case clampMax

    var displayName: String {
        switch self {
        case .preserveAspectRatio:
            return NSLocalizedString("swapResize.preserveAspectRatio",
                                     value: "Preserve Aspect Ratio",
                                     comment: "Swap resize mode — preserve aspect ratio radio title")
        case .clampMax:
            return NSLocalizedString("swapResize.clampMax",
                                     value: "Clamp Max Width / Height",
                                     comment: "Swap resize mode — clamp max radio title")
        }
    }
}

/// The single modifier key whose short-press (while Glance is active) brings
/// up hint letters on every thumbnail. The gesture itself is always a short,
/// solo tap — only *which* modifier is customizable.
enum HintTriggerKey: String, CaseIterable {
    case option
    case command
    case control
    case shift

    static let `default`: HintTriggerKey = .option

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option:  return .option
        case .command: return .command
        case .control: return .control
        case .shift:   return .shift
        }
    }

    /// Compact macOS glyph (⌥⌘⌃⇧) used in menu titles and tips.
    var displayGlyph: String {
        switch self {
        case .option:  return "\u{2325}"
        case .command: return "\u{2318}"
        case .control: return "\u{2303}"
        case .shift:   return "\u{21E7}"
        }
    }

    var displayName: String {
        switch self {
        case .option:
            return NSLocalizedString("hintTrigger.option",
                                     value: "Option (⌥)",
                                     comment: "Hint trigger key — Option")
        case .command:
            return NSLocalizedString("hintTrigger.command",
                                     value: "Command (⌘)",
                                     comment: "Hint trigger key — Command")
        case .control:
            return NSLocalizedString("hintTrigger.control",
                                     value: "Control (⌃)",
                                     comment: "Hint trigger key — Control")
        case .shift:
            return NSLocalizedString("hintTrigger.shift",
                                     value: "Shift (⇧)",
                                     comment: "Hint trigger key — Shift")
        }
    }
}

/// User-customizable global hotkey that toggles the Glance work area.
/// Stored as the raw modifier flags bitmask plus the Cocoa virtual key code.
struct ActivationHotkey: Equatable {
    var modifiers: NSEvent.ModifierFlags
    var keyCode: UInt16

    /// Only these four modifiers are allowed in a recorded combo. capsLock /
    /// function / numericPad are filtered out.
    static let allowedModifiers: NSEvent.ModifierFlags =
        [.control, .option, .shift, .command]

    /// Default combo: ⌃⌥H. keyCode 4 is Cocoa's virtual key code for H.
    static let `default` = ActivationHotkey(
        modifiers: [.control, .option],
        keyCode: 4
    )

    /// A combo is usable only if it has at least one allowed modifier —
    /// otherwise a bare key press would toggle the work area.
    var isValid: Bool {
        !modifiers.intersection(Self.allowedModifiers).isEmpty
    }

    /// Compares an incoming keyDown event against this combo. Ignores irrelevant
    /// modifier bits (capsLock, function, numericPad) so e.g. CapsLock being on
    /// doesn't break the shortcut.
    func matches(_ event: NSEvent) -> Bool {
        let incoming = event.modifierFlags.intersection(Self.allowedModifiers)
        let target = modifiers.intersection(Self.allowedModifiers)
        return incoming == target && event.keyCode == keyCode
    }

    /// Compact glyph string like "⌃⌥H" suitable for menu titles and labels.
    var displayString: String {
        var s = ""
        let m = modifiers.intersection(Self.allowedModifiers)
        if m.contains(.control) { s += "\u{2303}" }   // ⌃
        if m.contains(.option)  { s += "\u{2325}" }   // ⌥
        if m.contains(.shift)   { s += "\u{21E7}" }   // ⇧
        if m.contains(.command) { s += "\u{2318}" }   // ⌘
        s += keyCodeDisplayString(keyCode)
        return s
    }
}

/// Best-effort mapping from Cocoa virtual key code → user-visible character.
/// Covers letters, digits, and a handful of non-printing keys. Unknown codes
/// fall back to `#NN` so the field is never blank.
func keyCodeDisplayString(_ keyCode: UInt16) -> String {
    // Letters (layout-independent QWERTY positions — matches how Cocoa
    // menu equivalents render).
    let letterMap: [UInt16: String] = [
        0:"A", 11:"B", 8:"C", 2:"D", 14:"E", 3:"F", 5:"G", 4:"H",
        34:"I", 38:"J", 40:"K", 37:"L", 46:"M", 45:"N", 31:"O", 35:"P",
        12:"Q", 15:"R", 1:"S", 17:"T", 32:"U", 9:"V", 13:"W", 7:"X",
        16:"Y", 6:"Z",
    ]
    let digitMap: [UInt16: String] = [
        29:"0", 18:"1", 19:"2", 20:"3", 21:"4",
        23:"5", 22:"6", 26:"7", 28:"8", 25:"9",
    ]
    let namedMap: [UInt16: String] = [
        49: "Space",
        36: "\u{21A9}",      // ↩ Return
        48: "\u{21E5}",      // ⇥ Tab
        51: "\u{232B}",      // ⌫ Delete
        53: "Esc",
        122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6",
        98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12",
        123:"\u{2190}", 124:"\u{2192}", 125:"\u{2193}", 126:"\u{2191}",
        27:"-", 24:"=", 33:"[", 30:"]", 41:";", 39:"'",
        43:",", 47:".", 44:"/", 42:"\\", 50:"`",
    ]
    if let s = letterMap[keyCode] { return s }
    if let s = digitMap[keyCode]  { return s }
    if let s = namedMap[keyCode]  { return s }
    return "#\(keyCode)"
}

/// Centralized accessor for user-facing preferences that is observable
/// via `NSNotification`. Settings UI mutates here; subsystems read here.
final class Settings {
    static let shared = Settings()

    static let didChangeNotification = Notification.Name("GlanceSettingsDidChange")

    private enum Keys {
        static let swapResizeMode  = "swapResizeMode"
        static let showDockIcon    = "showDockIcon"
        static let mruGlowEnabled  = "mruGlowEnabled"
        static let languageOverride = "languageOverride"
        static let appleLanguages  = "AppleLanguages"
        static let activationHotkeyModifiers = "activationHotkeyModifiers"
        static let activationHotkeyKeyCode   = "activationHotkeyKeyCode"
        static let hintTriggerKey            = "hintTriggerKey"
    }

    private init() {}

    var swapResizeMode: SwapResizeMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.swapResizeMode) ?? ""
            return SwapResizeMode(rawValue: raw) ?? .preserveAspectRatio
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.swapResizeMode)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Whether the app should show an icon in the Dock. Default: true
    /// (preserves the current out-of-box behavior). When false, the app acts
    /// as an accessory (menu-bar-only) process; users can still reach it via
    /// the status bar item.
    var showDockIcon: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.showDockIcon) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.showDockIcon)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.showDockIcon)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// In-app UI language override. `.system` removes any override so macOS
    /// falls back to the system language. Changes take effect on next launch
    /// (NSBundle caches the resolved language at startup).
    var languageOverride: LanguageOverride {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.languageOverride) ?? ""
            return LanguageOverride(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.languageOverride)
            if let langs = newValue.appleLanguagesValue {
                UserDefaults.standard.set(langs, forKey: Keys.appleLanguages)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.appleLanguages)
            }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Global shortcut that toggles Glance's work area. Default: ⌃⌥H. The
    /// recorded combo must include at least one modifier; invalid values fall
    /// back to the default on read.
    var activationHotkey: ActivationHotkey {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: Keys.activationHotkeyModifiers) != nil,
                  defaults.object(forKey: Keys.activationHotkeyKeyCode) != nil
            else {
                return .default
            }
            let rawMods = UInt(bitPattern: defaults.integer(forKey: Keys.activationHotkeyModifiers))
            let keyCode = UInt16(truncatingIfNeeded: defaults.integer(forKey: Keys.activationHotkeyKeyCode))
            let candidate = ActivationHotkey(
                modifiers: NSEvent.ModifierFlags(rawValue: rawMods),
                keyCode: keyCode
            )
            return candidate.isValid ? candidate : .default
        }
        set {
            guard newValue.isValid else { return }
            let defaults = UserDefaults.standard
            defaults.set(Int(bitPattern: newValue.modifiers.rawValue),
                         forKey: Keys.activationHotkeyModifiers)
            defaults.set(Int(newValue.keyCode), forKey: Keys.activationHotkeyKeyCode)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The modifier key whose short-tap (while Glance is active) flashes the
    /// hint letters on each thumbnail. Default: Option.
    var hintTriggerKey: HintTriggerKey {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.hintTriggerKey) ?? ""
            return HintTriggerKey(rawValue: raw) ?? .default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.hintTriggerKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Whether to show a yellow halo around the 3 most recently-interacted
    /// thumbnails (brightness decreases by recency). Default: true.
    var mruGlowEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.mruGlowEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.mruGlowEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.mruGlowEnabled)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

/// Pure geometry: compute the target frame inside `workArea` for a window
/// of `windowSize`, according to `mode`. Always centered. The output is
/// clamped to never exceed the work area.
///
/// Worked examples:
///
///   workArea = (0,0,1000,800)
///
///   preserveAspectRatio:
///     winSize 500x400  -> 500x400 (fits, unchanged), centered at (250,200)
///     winSize 2000x800 -> scale by 0.5  -> 1000x400, centered at (0,200)
///     winSize 500x1600 -> scale by 0.5  -> 250x800,  centered at (375,0)
///
///   clampMax:
///     winSize 500x400  -> 500x400 (under both axes, unchanged), centered (250,200)
///     winSize 2000x600 -> 1000x600 (width clamped, height unchanged), centered (0,100)
///     winSize 1500x1200 -> 1000x800 (both clamped, ratio distorted), centered (0,0)
func computeSwapTargetFrame(
    windowSize: CGSize,
    workArea: CGRect,
    mode: SwapResizeMode
) -> CGRect {
    var w = windowSize.width
    var h = windowSize.height

    switch mode {
    case .preserveAspectRatio:
        if w > workArea.width {
            let s = workArea.width / w
            w *= s
            h *= s
        }
        if h > workArea.height {
            let s = workArea.height / h
            w *= s
            h *= s
        }
    case .clampMax:
        w = min(w, workArea.width)
        h = min(h, workArea.height)
    }

    let x = workArea.origin.x + (workArea.width  - w) / 2
    let y = workArea.origin.y + (workArea.height - h) / 2
    return CGRect(x: x, y: y, width: w, height: h)
}
