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
