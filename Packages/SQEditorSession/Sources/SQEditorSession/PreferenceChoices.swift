import Foundation
import SQCore
import SQPlayback
import SQUIKit

/// Preferences > Playback > Frame Cache: Auto (scaled to the machine's RAM), then fixed sizes up to half the RAM.
/// One list for the Mac window and the portable shell.
public enum FrameCacheChoices {
    /// Stored `AppSettings.frameCacheGB` per entry; 0 = Auto.
    public static func values(for b: MemoryBudget = .current()) -> [Int] { [0] + MemoryBudget.cacheChoicesGB(for: b) }

    public static func titles(for b: MemoryBudget = .current()) -> [String] {
        let auto = Double(b.autoFrameCacheBytes) / Double(MemoryBudget.gib)
        return [String(format: "Auto (%.1f GB)", auto)] + MemoryBudget.cacheChoicesGB(for: b).map { "\($0) GB" }
    }

    /// The entry of `gb`; a stored size no longer offered (less RAM now) shows Auto.
    public static func index(of gb: Int, for b: MemoryBudget = .current()) -> Int { values(for: b).firstIndex(of: gb) ?? 0 }
}

/// Preferences > Playback > Audio Output: System Default, every output device, and a stored device that is not connected.
public enum AudioOutputChoices {
    public struct Device: Sendable, Equatable {
        public var uid: String
        public var name: String
        public init(uid: String, name: String) { self.uid = uid; self.name = name }
    }

    public struct Entry: Sendable, Equatable {
        public var title: String
        /// nil = System Default.
        public var uid: String?
    }

    public static let systemDefault = "System Default"
    public static let notConnected = "Not connected (playing on System Default)"

    public static func entries(devices: [Device], stored: String?) -> [Entry] {
        var out = [Entry(title: systemDefault, uid: nil)] + devices.map { Entry(title: $0.name, uid: $0.uid) }
        if let stored, !stored.isEmpty, !devices.contains(where: { $0.uid == stored }) { out.append(Entry(title: notConnected, uid: stored)) }
        return out
    }

    public static func index(of stored: String?, in entries: [Entry]) -> Int {
        guard let stored, !stored.isEmpty else { return 0 }
        return entries.firstIndex { $0.uid == stored } ?? 0
    }
}

/// Preferences > Media > Cache, Scratch and Projects Folder: Choose… and Use Default, shared by the Mac window and the shell.
public enum StorageFolderChoice {
    /// Copies the proxies of the old cache folder into the new one (never moves them).
    public typealias Migrate = @Sendable (_ old: URL, _ new: URL) -> Void
    /// Set at launch by an app that switches its proxy cache at once (Windows `WinProxies.moveCache`): a folder change hands
    /// it the old and new proxy folder instead of the background copy, and the note drops "at the next launch".
    /// shortcut: the Mac still switches at the next launch (AutoProxyService keeps one cache); set this there once its
    /// cache can be swapped.
    nonisolated(unsafe) public static var movesProxiesAtOnce: Migrate?
    public static let migrateInBackground: Migrate = { old, new in
        Task.detached(priority: .utility) { _ = StorageLocations.migrate(from: old, to: new) }
    }

    /// Sets (url) or resets (nil) the cache folder: validated for a tenth of the cache size, saved, the waveform, analysis
    /// and preview roots moved, the proxies copied over. Returns the note under the row ("" when nothing to say), or the
    /// problem with the folder (nothing changed then).
    @discardableResult
    public static func setCacheFolder(_ url: URL?, settings s: inout AppSettings, defaults d: UserDefaults = .standard,
                                      migrate: Migrate = migrateInBackground) -> String {
        let old = s.locations(from: d).proxyDirectory
        if let url, let problem = StorageLocations.validate(url, requiredBytes: Int64(s.cacheCapGB) * 1_000_000_000 / 10) {
            return problem.message
        }
        s.cacheFolder = url
        s.save(to: d)
        let l = s.locations(from: d)
        l.applyWaveformDirectory()
        l.applyAnalysisAndPreviewRoots()
        let new = l.proxyDirectory
        guard old.standardizedFileURL != new.standardizedFileURL else { return "" }
        let was = shortPath(old)
        if let mover = movesProxiesAtOnce {
            mover(old, new)
            return SQL10n.format("Proxies already made are copied from %@; the original stays there.", was)
        }
        migrate(old, new)
        return SQL10n.format("Applies at the next launch. Proxies already made are copied from %@; the original stays there.", was)
    }

    /// Sets (url) or resets (nil) the scratch or projects folder. nil when saved, else the problem with the folder.
    public static func setFolder(scratch: Bool, _ url: URL?, defaults d: UserDefaults = .standard) -> String? {
        if let url, let problem = StorageLocations.validate(url) { return problem.message }
        var l = StorageLocations.load(from: d)
        if scratch { l.scratchFolder = url } else { l.projectsFolder = url }
        l.save(to: d)
        return nil
    }
}

/// Preferences > Editing > "Your effect and transition defaults": the kinds with a user default in three groups.
extension EffectDefaults {
    public enum Group: Int, CaseIterable, Sendable {
        case effects, videoTransitions, audioTransitions
        public var title: String {
            switch self {
            case .effects: "Effects"
            case .videoTransitions: "Video Transitions"
            case .audioTransitions: "Audio Transitions"
            }
        }
    }

    public enum Entry: Hashable, Sendable {
        case effect(String), transition(TransitionKind)
        public var title: String {
            switch self {
            case .effect(let k): EffectCatalog.title(for: k)
            case .transition(let k): k.name
            }
        }
    }

    public static let emptyGroupText = "None yet. Right-click an effect or transition and choose Use as Default."
    public static let settingsHelp = "New effects and transitions of these kinds start with your values. Presets you apply still win. Restore Factory deletes your default; instances already in a project keep their values."

    /// The entries of `g`, sorted by title.
    public func entries(in g: Group) -> [Entry] {
        let transitions = self.transitions.keys.compactMap(TransitionKind.init(rawValue:))
        let list: [Entry] = switch g {
        case .effects: effects.keys.map { .effect($0) }
        case .videoTransitions: transitions.filter { $0.trackKind == .video }.map { .transition($0) }
        case .audioTransitions: transitions.filter { $0.trackKind != .video }.map { .transition($0) }
        }
        return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Restore Factory of one entry.
    public mutating func remove(_ e: Entry) {
        switch e {
        case .effect(let k): removeDefault(effect: k)
        case .transition(let k): removeDefault(transition: k)
        }
    }
}

extension StorageFolderChoice {
    /// `path` with the home folder as `~` (the Mac `abbreviatingWithTildeInPath`, also on Windows).
    public static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        guard !home.isEmpty, p == home || p.hasPrefix(home.hasSuffix("/") ? home : home + "/") else { return p }
        return "~" + p.dropFirst(home.count)
    }
}
