import Foundation

/// The menu title of one autosave version (File > Autosave Versions): the time it was written, how long ago that was, and
/// "Latest" on the newest one, so the user can tell the versions apart without reading clock times.
public enum AutosaveVersionLabel {
    public static func title(date: Date, now: Date = Date(), isNewest: Bool, locale: Locale = .current) -> String {
        var absolute = Date.FormatStyle(date: .abbreviated, time: .standard)
        absolute.locale = locale
        #if canImport(Darwin)
        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .short
        // A version written in the same second as `now` reads "in 0 sec.": clamp so it is never in the future.
        let ago = relative.localizedString(for: min(date, now), relativeTo: now)
        let base = date.formatted(absolute) + " · " + ago
        #else
        // shortcut: English short wording off the Mac (corelibs has no RelativeDateTimeFormatter), upgrade with
        // localized strings when the Windows shell gets its menus.
        let s = max(0, Int(now.timeIntervalSince(date)))
        let ago = s < 60 ? "\(s) sec. ago" : s < 3600 ? "\(s / 60) min. ago" : s < 86_400 ? "\(s / 3600) hr. ago" : "\(s / 86_400) days ago"
        let base = date.formatted(absolute) + " · " + ago
        #endif
        return isNewest ? base + " · " + SQL10n.string("Latest") : base
    }

    /// A named checkpoint: its name and the time it was saved.
    public static func checkpointTitle(name: String, date: Date, locale: Locale = .current) -> String {
        var absolute = Date.FormatStyle(date: .abbreviated, time: .shortened)
        absolute.locale = locale
        return name + " · " + date.formatted(absolute)
    }
}
