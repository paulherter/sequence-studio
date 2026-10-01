import Foundation
import SQCore

/// Preferences of the Settings window, persisted in UserDefaults. Every read validates, so a hand-edited or stale value
/// falls back to the default instead of reaching the app.
public struct AppSettings: Sendable, Equatable {
    // General
    /// Seconds between autosaves of a changed project.
    public var autosaveInterval: TimeInterval
    /// Offer to restore the last autosave after an unclean quit.
    public var offerRecovery: Bool
    // Playback
    public var defaultQuality: MonitorQuality
    /// Seconds played before / after the marked range (Shift+Space) or the playhead (Shift+K Play Around). Premiere
    /// defaults: 3 s before, 2 s after (Preferences > Playback).
    public var prerollSeconds: Int = 3
    public var postrollSeconds: Int = 2
    /// Project panel Hover Scrub (Shift+H toggles).
    public var hoverScrub: Bool = true
    /// CoreAudio device UID; nil = system default output.
    public var audioOutputUID: String?
    // Media
    /// Folder for proxies and render cache; nil = the default folder.
    public var cacheFolder: URL?
    /// Cache size cap in gigabytes.
    public var cacheCapGB: Int

    public static let autosaveChoices: [TimeInterval] = [60, 120, 300, 600, 900]
    public static let cacheCapChoices = [10, 20, 50, 100, 250]
    public static let rollChoices = [0, 1, 2, 3, 4, 5, 6, 8, 10]

    public var preroll: Time { Time(Int64(prerollSeconds), 1) }
    public var postroll: Time { Time(Int64(postrollSeconds), 1) }
    public static let standard = AppSettings(autosaveInterval: 300, offerRecovery: true, defaultQuality: .full,
                                             audioOutputUID: nil, cacheFolder: nil, cacheCapGB: 50)

    public init(autosaveInterval: TimeInterval, offerRecovery: Bool, defaultQuality: MonitorQuality,
                audioOutputUID: String?, cacheFolder: URL?, cacheCapGB: Int) {
        self.autosaveInterval = autosaveInterval; self.offerRecovery = offerRecovery
        self.defaultQuality = defaultQuality; self.audioOutputUID = audioOutputUID
        self.cacheFolder = cacheFolder; self.cacheCapGB = cacheCapGB
    }

    /// Default cache folder: ~/Library/Caches/Sequence Studio.
    public static var defaultCacheFolder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Sequence Studio", isDirectory: true)
    }

    public var effectiveCacheFolder: URL { cacheFolder ?? Self.defaultCacheFolder }

    enum Key {
        static let autosave = "settings.autosaveInterval"
        static let recovery = "settings.offerRecovery"
        static let quality = "settings.defaultQuality"
        static let audio = "settings.audioOutputUID"
        static let cache = "settings.cacheFolder"
        static let cap = "settings.cacheCapGB"
        static let preroll = "settings.prerollSeconds"
        static let postroll = "settings.postrollSeconds"
        static let hoverScrub = "settings.hoverScrub"
    }

    public static func load(from d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings.standard
        if d.object(forKey: Key.autosave) != nil {
            let v = d.double(forKey: Key.autosave)
            if v.isFinite, v >= 30, v <= 3600 { s.autosaveInterval = v }
        }
        if d.object(forKey: Key.recovery) != nil { s.offerRecovery = d.bool(forKey: Key.recovery) }
        if let q = d.string(forKey: Key.quality).flatMap(MonitorQuality.init(rawValue:)) { s.defaultQuality = q }
        if let u = d.string(forKey: Key.audio), !u.isEmpty { s.audioOutputUID = u }
        if let p = d.string(forKey: Key.cache), p.hasPrefix("/") { s.cacheFolder = URL(fileURLWithPath: p, isDirectory: true) }
        if d.object(forKey: Key.cap) != nil {
            let v = d.integer(forKey: Key.cap)
            if v >= 1, v <= 10_000 { s.cacheCapGB = v }
        }
        if d.object(forKey: Key.preroll) != nil { let v = d.integer(forKey: Key.preroll); if (0...60).contains(v) { s.prerollSeconds = v } }
        if d.object(forKey: Key.postroll) != nil { let v = d.integer(forKey: Key.postroll); if (0...60).contains(v) { s.postrollSeconds = v } }
        if d.object(forKey: Key.hoverScrub) != nil { s.hoverScrub = d.bool(forKey: Key.hoverScrub) }
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        d.set(autosaveInterval, forKey: Key.autosave)
        d.set(offerRecovery, forKey: Key.recovery)
        d.set(defaultQuality.rawValue, forKey: Key.quality)
        if let audioOutputUID { d.set(audioOutputUID, forKey: Key.audio) } else { d.removeObject(forKey: Key.audio) }
        if let cacheFolder { d.set(cacheFolder.path, forKey: Key.cache) } else { d.removeObject(forKey: Key.cache) }
        d.set(cacheCapGB, forKey: Key.cap)
        d.set(prerollSeconds, forKey: Key.preroll)
        d.set(postrollSeconds, forKey: Key.postroll)
        d.set(hoverScrub, forKey: Key.hoverScrub)
    }
}

/// Rows of the read-only Keyboard tab, built from the command map.
public enum KeyboardListing {
    public struct Row: Equatable, Sendable {
        public var command: String
        public var shortcut: String
        public var scope: String
    }

    /// Display text of a binding, e.g. "⇧⌘Z" or "Space".
    public static func text(for b: KeyBinding) -> String {
        var s = ""
        if b.modifiers.contains(.control) { s += "⌃" }
        if b.modifiers.contains(.option) { s += "⌥" }
        if b.modifiers.contains(.shift) { s += "⇧" }
        if b.modifiers.contains(.command) { s += "⌘" }
        switch b.key {
        case .char(let c): s += String(c).uppercased()
        case .space: s += "Space"
        case .left: s += "←"
        case .right: s += "→"
        case .up: s += "↑"
        case .down: s += "↓"
        case .home: s += "Home"
        case .end: s += "End"
        case .delete: s += "⌫"
        case .function(let n): s += "F\(n)"
        }
        return s
    }

    public static func rows(_ map: CommandMap) -> [Row] {
        map.entries.map {
            Row(command: $0.command.title, shortcut: text(for: $0.binding), scope: "\($0.scope)".capitalized)
        }
        .sorted { ($0.command, $0.shortcut) < ($1.command, $1.shortcut) }
    }

    /// Human name of the scope a binding is active in.
    public static func scopeName(_ s: CommandScope) -> String {
        switch s {
        case .global: "Everywhere"
        case .timeline: "Timeline"
        case .program: "Program Monitor"
        case .source: "Source Monitor"
        case .project: "Project Panel"
        }
    }

    /// Rows of the Keyboard Shortcuts window: every binding, sorted by command name, scopes in plain words.
    public static func windowRows(_ map: CommandMap) -> [Row] {
        map.entries.map { Row(command: $0.command.title, shortcut: text(for: $0.binding), scope: scopeName($0.scope)) }
            .sorted { ($0.command, $0.shortcut) < ($1.command, $1.shortcut) }
    }

    /// Case-insensitive search over command, scope and shortcut; modifier symbols also match their names
    /// ("cmd shift z" finds ⇧⌘Z). Every word of the query must match.
    public static func filter(_ rows: [Row], query: String) -> [Row] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { r in
            let keys = r.shortcut.replacingOccurrences(of: "⌃", with: " control ").replacingOccurrences(of: "⌥", with: " option alt ")
                .replacingOccurrences(of: "⇧", with: " shift ").replacingOccurrences(of: "⌘", with: " command cmd ")
            let hay = (r.command + " " + r.scope + " " + r.shortcut + " " + keys).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
