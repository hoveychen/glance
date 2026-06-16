import AppKit

/// Stable identity for a docked tab, used to restore docked / pinned state
/// across window-ID reassignment and app relaunch. Window IDs are not stable
/// between launches, so we persist (bundleId + title) the same way
/// `ReservationStore` keys reserved hint keys.
struct TabIdentity: Codable, Equatable {
    /// The owning app's bundle identifier (e.g. "com.google.Chrome").
    var bundleId: String
    /// The window title at dock time. `nil` matches any window of the app
    /// (useful for single-window apps whose title we don't care about).
    var title: String?
}

/// A persisted docked tab. Array order in the store IS the tab order.
struct TabRecord: Codable, Equatable {
    var identity: TabIdentity
    /// Whether this tab is pinned (Chrome-style: icon-only, kept at the left,
    /// not closable). Pinned tabs always sort before unpinned ones.
    var pinned: Bool
}

/// Singleton store for the user's work-area tab set. Persists to `UserDefaults`
/// alongside the other app preferences. The store owns *persistent identity and
/// pin state*; the live `CGWindowID` ↔ identity mapping is maintained by the
/// coordinator (`AppDelegate`).
final class WorkAreaTabStore {
    static let shared = WorkAreaTabStore()

    private enum Keys {
        static let tabs = "workAreaTabs"
    }

    private var cache: [TabRecord]?

    private init() {}

    /// All persisted tab records, in tab order.
    var records: [TabRecord] {
        if let cache { return cache }
        let list: [TabRecord] = {
            guard let data = UserDefaults.standard.data(forKey: Keys.tabs),
                  let decoded = try? JSONDecoder().decode([TabRecord].self, from: data) else {
                return []
            }
            return decoded
        }()
        cache = list
        return list
    }

    /// Replace the full persisted tab set.
    func save(_ list: [TabRecord]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Keys.tabs)
        }
    }

    // MARK: - Pure ordering logic (no I/O — easy to reason about / test)

    /// Arrange a docked-tab order so that pinned tabs come first (in their
    /// existing relative order) and unpinned tabs follow (in their existing
    /// relative order). This is a stable partition: a tab never jumps past
    /// same-section siblings just because another tab's pin state changed.
    ///
    /// Mirrors Chrome: pinning moves a tab to the end of the pinned section,
    /// unpinning moves it to the start of the unpinned section.
    static func arrange<ID: Hashable>(order: [ID], pinned: Set<ID>) -> [ID] {
        let pinnedPart = order.filter { pinned.contains($0) }
        let unpinnedPart = order.filter { !pinned.contains($0) }
        return pinnedPart + unpinnedPart
    }

    /// Insert `id` into `order` at `index`, removing any existing occurrence
    /// first so a re-dock / reorder doesn't duplicate the entry. `index` is
    /// clamped to the bounds of the resulting array.
    static func insert<ID: Equatable>(_ id: ID, into order: [ID], at index: Int) -> [ID] {
        var result = order
        result.removeAll { $0 == id }
        let clamped = max(0, min(index, result.count))
        result.insert(id, at: clamped)
        return result
    }
}
