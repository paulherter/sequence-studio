import Foundation

/// One-time migration of UserDefaults keys written by older builds (`ss.*`) to their `sq.*` names.
public enum DefaultsMigration {
    public static let legacyPrefix = "ss."
    public static let prefix = "sq."

    /// Copies every `ss.<rest>` value to `sq.<rest>` (an existing `sq.` value wins) and removes the old key.
    /// Returns the number of keys migrated. Cheap and idempotent, so it may run at every launch.
    @discardableResult
    public static func migrateLegacyKeys(in defaults: UserDefaults = .standard) -> Int {
        var n = 0
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(legacyPrefix) {
            let new = prefix + key.dropFirst(legacyPrefix.count)
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: key)
            n += 1
        }
        return n
    }
}
