import Foundation

/// The app-wide list of library folders, kept in user defaults (never in a project). Every project shows the same list.
public enum LibraryFolderStore {
    public static let key = "sq.library.folders"
    /// Key used before the list was named `sq.*`; read once, then moved.
    public static let legacyKey = "library.watchedFolders"

    public static func load(_ defaults: UserDefaults = .standard) -> [WatchedFolder] {
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([WatchedFolder].self, from: data)) ?? []
        }
        guard let old = defaults.data(forKey: legacyKey) else { return [] }
        let folders = (try? JSONDecoder().decode([WatchedFolder].self, from: old)) ?? []
        defaults.set(old, forKey: key)
        defaults.removeObject(forKey: legacyKey)
        return folders
    }

    public static func save(_ folders: [WatchedFolder], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: key) }
    }
}
