import Foundation

/// Recently used colors of the picker, newest first. Persisted in UserDefaults `sq.color.recents` as hex strings
/// (`RRGGBB`, or `RRGGBBAA` when not opaque). The board's row holds six swatches.
public enum SQColorRecents {
    public static let defaultsKey = "sq.color.recents"
    public static let maxCount = 6

    /// `hex` moved to the front, duplicates removed, capped at `max`. Invalid strings are ignored.
    public static func adding(_ hex: String, to list: [String], max: Int = maxCount) -> [String] {
        guard let key = normalized(hex) else { return list }
        var out = [key] + list.filter { $0 != key }
        if out.count > max { out.removeLast(out.count - max) }
        return out
    }

    /// Uppercase `RRGGBB` / `RRGGBBAA` without `#`, or nil when `hex` is not a color.
    public static func normalized(_ hex: String) -> String? {
        guard let v = SQColorValue.parse(hex: hex) else { return nil }
        return key(for: v)
    }

    public static func key(for v: SQColorValue) -> String {
        v.a < 1 ? v.hex + String(format: "%02X", Int((v.a * 255).rounded())) : v.hex
    }

    public static func load(_ defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        return Array(raw.compactMap(normalized).prefix(maxCount))
    }

    public static func remember(_ v: SQColorValue, in defaults: UserDefaults = .standard) {
        defaults.set(adding(key(for: v), to: load(defaults)), forKey: defaultsKey)
    }
}
