import AppKit

/// A user-defined mapping from a window (identified by its bundle ID plus
/// optional title) to a reserved hint key. Reserved keys take priority over
/// auto-assigned keys, so the user can blind-press Option+<key> and reach the
/// same window regardless of layout shuffling.
struct Reservation: Codable, Equatable {
    /// The app's bundle identifier (e.g. "com.todesktop.cursor").
    var bundleId: String
    /// Exact window title to match. `nil` means "match any window of the app",
    /// useful for single-window apps.
    var titlePattern: String?
    /// The reserved hint key — a single character from the hint alphabet
    /// (digits `1`–`9` or lowercase `a`–`z`).
    var key: String
}

/// Singleton store for the user's reserved-key mappings. Persists to
/// `UserDefaults` alongside other app preferences.
final class ReservationStore {
    static let shared = ReservationStore()

    private enum Keys {
        static let reservations = "reservations"
    }

    static let didChangeNotification = Notification.Name("GlanceReservationsDidChange")

    private var cache: [Reservation]?

    private init() {}

    /// All current reservations.
    var all: [Reservation] {
        if let cache { return cache }
        let list: [Reservation] = {
            guard let data = UserDefaults.standard.data(forKey: Keys.reservations),
                  let decoded = try? JSONDecoder().decode([Reservation].self, from: data) else {
                return []
            }
            return decoded
        }()
        cache = list
        return list
    }

    /// Assign `key` to the window identified by (`bundleId`, `titlePattern`).
    /// Any existing reservation for the same window is replaced. Any other
    /// reservation already holding `key` is displaced — new overwrites old.
    func set(bundleId: String, titlePattern: String?, key: String) {
        var list = all
        list.removeAll { $0.bundleId == bundleId && $0.titlePattern == titlePattern }
        list.removeAll { $0.key == key }
        list.append(Reservation(bundleId: bundleId, titlePattern: titlePattern, key: key))
        persist(list)
    }

    /// Remove the reservation for the window identified by (`bundleId`, `titlePattern`).
    func clear(bundleId: String, titlePattern: String?) {
        var list = all
        let before = list.count
        list.removeAll { $0.bundleId == bundleId && $0.titlePattern == titlePattern }
        if list.count != before {
            persist(list)
        }
    }

    private func persist(_ list: [Reservation]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Keys.reservations)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
