import Foundation
import SQProxy
import SQCore
import SQExport

/// Preferences of the Settings window, persisted in UserDefaults. Every read validates, so a hand-edited or stale value
/// falls back to the default instead of reaching the app.
public struct AppSettings: Sendable, Equatable {
    // General
    /// Seconds between autosaves of a changed project.
    public var autosaveInterval: TimeInterval
    /// Offer to restore the last autosave after an unclean quit.
    public var offerRecovery: Bool
    /// Ask the update address (`UpdateCheck.feedURL`) for a newer version at launch. Inert while that address is empty.
    public var checkForUpdates: Bool = true
    /// The first-run welcome sheet was shown (or skipped); it never appears again.
    public var onboardingSeen: Bool = false
    // Playback
    public var defaultQuality: MonitorQuality
    /// Seconds played before / after the marked range (Shift+Space) or the playhead (Shift+K Play Around). Premiere
    /// defaults: 3 s before, 2 s after (Preferences > Playback).
    public var prerollSeconds: Int = 3
    public var postrollSeconds: Int = 2
    /// Project panel Hover Scrub (Shift+H toggles).
    public var hoverScrub: Bool = true
    /// Dropped-frame dot in the Program monitor.
    public var dropIndicator: Bool = true
    /// Audio scrubbing (Shift+S): sound while dragging the playhead. Off by default (the maintainer, 2026-10-01); video scrubbing is always on.
    public var audioScrubbing: Bool = false
    /// Edit mode a new sequence starts in (`sq.newSequenceEditMode`): Normal, or Fast Cut (magnetic main track).
    public var newSequenceEditMode: TimelineEditMode = .normal
    /// Sequence > Selection Follows Playhead (`sq.selectionFollowsPlayhead`), off by default (it replaced a hand-picked clip whenever playback or a scrub crossed a clip edge).
    public var selectionFollowsPlayhead: Bool = false
    /// Preview quality Auto: the monitors start at the size `MemoryBudget.autoPreviewQuality` picks for this Mac (half on
    /// 8 GB Macs) and drop lower under memory pressure. Off = start at `defaultQuality` and stay there.
    public var previewQualityAuto: Bool = true
    /// Frame cache of both monitors in GB; 0 = Auto (scaled to the Mac's RAM, `MemoryBudget`).
    public var frameCacheGB: Int = 0
    /// Background work (proxy generation while editing). Off = only on request.
    public var backgroundWork: Bool = true
    /// Preview render cache: heavy stretches of the timeline are rendered to disk while idle and played from there.
    public var renderCache: Bool = true
    /// Disk the render cache may use, in GB (`renderCacheCapChoices`).
    public var renderCacheCapGB: Int = 10
    public static let renderCacheCapChoices = [2, 5, 10, 20, 50]
    /// H.264 / HEVC encoder speed of every export on this Mac. Quality by default; small Macs only get a suggestion
    /// in the Export dialog (`EncoderSpeed.suggested`), never a silent change.
    public var exportEncoderSpeed: EncoderSpeed = .quality
    /// CoreAudio device UID; nil = system default output.
    public var audioOutputUID: String?
    // Media
    /// Folder for proxies and render cache; nil = the default folder.
    public var cacheFolder: URL?
    /// Cache size cap in gigabytes.
    public var cacheCapGB: Int
    /// Look for project media that is still growing (a recording in progress) or was re-rendered, and refresh its length,
    /// thumbnails and waveform (`sq.media.refreshGrowing`). Off = only when the app comes to the front.
    public var refreshGrowingFiles: Bool = true
    /// Global "use proxies for export" (`sq.proxy.export`, `ProxySettingsStore.useProxiesForExport`): the render reads ready
    /// proxies instead of the originals. Off by default.
    public var useProxiesForExport: Bool = false
    // Text
    /// Length of a new text layer and of a caption added by hand, in seconds (Premiere: 5 s for a title).
    public var defaultTextSeconds: Int = 5
    /// Default TRANSCRIPTION language (BCP-47) of the Captions panel; a project may override it.
    public var captionLanguage: String = AppSettings.defaultCaptionLanguage
    /// After a transcription, switch to the language the text is in and run it again (`CaptionLanguageGuess`).
    public var captionAutoLanguage: Bool = true
    /// Factory default: the system language mapped to a supported transcription language (English if unsupported).
    public static let defaultCaptionLanguage = derivedCaptionLanguage(preferred: Locale.preferredLanguages)
    /// Transcription languages the Captions panel offers; the factory default is picked from this list.
    public static let supportedCaptionLanguages = ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"]

    /// First preferred language that has a supported transcription language (exact region first, else the same
    /// language in any region); "en-US" when none matches.
    public static func derivedCaptionLanguage(preferred: [String],
                                              supported: [String] = supportedCaptionLanguages) -> String {
        for p in preferred {
            let id = p.replacingOccurrences(of: "_", with: "-")
            if let exact = supported.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { return exact }
            let code = Locale(identifier: id).language.languageCode?.identifier ?? String(id.prefix(while: { $0 != "-" }))
            if let same = supported.first(where: { $0.prefix(while: { $0 != "-" }).lowercased() == code.lowercased() }) { return same }
        }
        return "en-US"
    }
    public static let textDurationChoices = [1, 2, 3, 4, 5, 8, 10, 15, 30]

    public static let autosaveChoices: [TimeInterval] = [60, 120, 300, 600, 900]
    public static let cacheCapChoices = [10, 20, 50, 100, 250]
    public static let rollChoices = [0, 1, 2, 3, 4, 5, 6, 8, 10]

    /// A quality picked by hand in a monitor: fixed from now on, remembered across projects.
    public func choosingFixedQuality(_ q: MonitorQuality) -> AppSettings {
        var s = self
        s.previewQualityAuto = false
        s.defaultQuality = q
        return s
    }

    /// Monitor quality at launch / project open.
    public func startQuality(auto: MonitorQuality) -> MonitorQuality { previewQualityAuto ? auto : defaultQuality }

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

    /// Where the proxy cache lives: the default location until the user picks a folder, then `<folder>/Proxies`.
    /// Read at launch; a folder change applies at the next launch (the old cache stays where it was).
    public var proxyCacheDirectory: URL {
        locations.proxyDirectory
    }

    /// Cache, scratch and projects roots (scratch and projects picks live in their own `sq.storage.*` keys).
    public var locations: StorageLocations { locations(from: .standard) }

    public func locations(from d: UserDefaults) -> StorageLocations {
        var l = StorageLocations.load(from: d)
        l.cacheFolder = cacheFolder
        return l
    }

    /// The cache size cap in bytes (decimal gigabytes, like the 50 GB default of `ProxySettings`).
    public var cacheCapBytes: Int64 { Int64(max(cacheCapGB, 1)) * 1_000_000_000 }
    public var renderCacheCapBytes: Int64 { Int64(max(renderCacheCapGB, 1)) * 1_000_000_000 }

    public enum Key {
        static let autosave = "settings.autosaveInterval"
        static let recovery = "settings.offerRecovery"
        public static let quality = "settings.defaultQuality"
        public static let audio = "settings.audioOutputUID"
        public static let cache = "settings.cacheFolder"
        public static let cap = "settings.cacheCapGB"
        static let preroll = "settings.prerollSeconds"
        static let postroll = "settings.postrollSeconds"
        public static let hoverScrub = "settings.hoverScrub"
        static let dropIndicator = "sq.playback.dropIndicator"
        static let textSeconds = "settings.defaultTextSeconds"
        static let audioScrubbing = "sq.audioScrubbing"       // same key the Shift+S toggle has always written
        /// Retired: Delete follows the sequence mode. The stored value is ignored and removed on save.
        static let retiredRippleDelete = "sq.delete.ripple"
        static let newSequenceEditMode = "sq.newSequenceEditMode"
        static let selectionFollows = "sq.selectionFollowsPlayhead"
        public static let captionLanguage = "sq.captions.language"
        static let captionAutoLanguage = "sq.captions.autoLanguage"
        static let projectLanguagePrefix = "sq.captions.language."
        static let qualityAuto = "sq.playback.previewQualityAuto"
        static let frameCache = "sq.playback.frameCacheGB"
        static let backgroundWork = "sq.playback.backgroundWork"
        static let renderCache = "sq.playback.renderCache"
        static let renderCacheCap = "sq.playback.renderCacheCapGB"
        public static let encoderSpeed = "sq.export.encoderSpeed"
        public static let checkForUpdates = "sq.updates.check"
        public static let onboardingSeen = "sq.onboarding.seen"
        public static let refreshGrowing = "sq.media.refreshGrowing"
        public static let proxiesForExport = ProxySettingsStore.exportKey
    }

    public static func load(from d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings.standard
        if d.object(forKey: Key.autosave) != nil {
            let v = d.double(forKey: Key.autosave)
            if v.isFinite, v >= 30, v <= 3600 { s.autosaveInterval = v }
        }
        if d.object(forKey: Key.recovery) != nil { s.offerRecovery = d.bool(forKey: Key.recovery) }
        let storedQuality = d.string(forKey: Key.quality).flatMap(MonitorQuality.stored)
        if let q = storedQuality { s.defaultQuality = q }
        // A 1/2 or 1/4 remembered before Auto existed stays fixed; a stored "full" was written by every save of older
        // builds (the default, not a choice), so it means Auto.
        s.previewQualityAuto = d.object(forKey: Key.qualityAuto) != nil ? d.bool(forKey: Key.qualityAuto)
            : (storedQuality ?? .full) == .full
        if d.object(forKey: Key.frameCache) != nil { let v = d.integer(forKey: Key.frameCache); if (0...1024).contains(v) { s.frameCacheGB = v } }
        if d.object(forKey: Key.backgroundWork) != nil { s.backgroundWork = d.bool(forKey: Key.backgroundWork) }
        if d.object(forKey: Key.renderCache) != nil { s.renderCache = d.bool(forKey: Key.renderCache) }
        if d.object(forKey: Key.renderCacheCap) != nil { let v = d.integer(forKey: Key.renderCacheCap); if (1...1000).contains(v) { s.renderCacheCapGB = v } }
        if d.object(forKey: Key.checkForUpdates) != nil { s.checkForUpdates = d.bool(forKey: Key.checkForUpdates) }
        s.onboardingSeen = d.bool(forKey: Key.onboardingSeen)
        if d.object(forKey: Key.refreshGrowing) != nil { s.refreshGrowingFiles = d.bool(forKey: Key.refreshGrowing) }
        s.useProxiesForExport = d.bool(forKey: Key.proxiesForExport)
        if let v = d.string(forKey: Key.encoderSpeed).flatMap(EncoderSpeed.init(rawValue:)) { s.exportEncoderSpeed = v }
        if let u = d.string(forKey: Key.audio), !u.isEmpty { s.audioOutputUID = u }
        if let p = d.string(forKey: Key.cache), StorageLocations.isAbsolutePath(p) { s.cacheFolder = URL(fileURLWithPath: p, isDirectory: true) }
        if d.object(forKey: Key.cap) != nil {
            let v = d.integer(forKey: Key.cap)
            if v >= 1, v <= 10_000 { s.cacheCapGB = v }
        }
        if d.object(forKey: Key.preroll) != nil { let v = d.integer(forKey: Key.preroll); if (0...60).contains(v) { s.prerollSeconds = v } }
        if d.object(forKey: Key.postroll) != nil { let v = d.integer(forKey: Key.postroll); if (0...60).contains(v) { s.postrollSeconds = v } }
        if d.object(forKey: Key.hoverScrub) != nil { s.hoverScrub = d.bool(forKey: Key.hoverScrub) }
        if d.object(forKey: Key.dropIndicator) != nil { s.dropIndicator = d.bool(forKey: Key.dropIndicator) }
        if d.object(forKey: Key.audioScrubbing) != nil { s.audioScrubbing = d.bool(forKey: Key.audioScrubbing) }
        if let m = d.string(forKey: Key.newSequenceEditMode).flatMap(TimelineEditMode.init(rawValue:)) { s.newSequenceEditMode = m }
        if d.object(forKey: Key.selectionFollows) != nil { s.selectionFollowsPlayhead = d.bool(forKey: Key.selectionFollows) }
        if let l = d.string(forKey: Key.captionLanguage), Self.isValidLanguage(l) { s.captionLanguage = l }
        if d.object(forKey: Key.captionAutoLanguage) != nil { s.captionAutoLanguage = d.bool(forKey: Key.captionAutoLanguage) }
        if d.object(forKey: Key.textSeconds) != nil {
            let v = d.integer(forKey: Key.textSeconds)
            if v >= 1, v <= 600 { s.defaultTextSeconds = v }
        }
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        d.set(autosaveInterval, forKey: Key.autosave)
        d.set(offerRecovery, forKey: Key.recovery)
        // Only a fixed choice is stored; Auto leaves no quality behind.
        if previewQualityAuto { d.removeObject(forKey: Key.quality) } else { d.set(defaultQuality.rawValue, forKey: Key.quality) }
        if let audioOutputUID { d.set(audioOutputUID, forKey: Key.audio) } else { d.removeObject(forKey: Key.audio) }
        if let cacheFolder { d.set(cacheFolder.path, forKey: Key.cache) } else { d.removeObject(forKey: Key.cache) }
        d.set(cacheCapGB, forKey: Key.cap)
        d.set(prerollSeconds, forKey: Key.preroll)
        d.set(postrollSeconds, forKey: Key.postroll)
        d.set(hoverScrub, forKey: Key.hoverScrub)
        d.set(dropIndicator, forKey: Key.dropIndicator)
        d.set(defaultTextSeconds, forKey: Key.textSeconds)
        d.set(audioScrubbing, forKey: Key.audioScrubbing)
        d.removeObject(forKey: Key.retiredRippleDelete)
        d.set(newSequenceEditMode.rawValue, forKey: Key.newSequenceEditMode)
        d.set(selectionFollowsPlayhead, forKey: Key.selectionFollows)
        d.set(captionLanguage, forKey: Key.captionLanguage)
        d.set(captionAutoLanguage, forKey: Key.captionAutoLanguage)
        d.set(previewQualityAuto, forKey: Key.qualityAuto)
        d.set(frameCacheGB, forKey: Key.frameCache)
        d.set(backgroundWork, forKey: Key.backgroundWork)
        d.set(renderCache, forKey: Key.renderCache)
        d.set(renderCacheCapGB, forKey: Key.renderCacheCap)
        d.set(exportEncoderSpeed.rawValue, forKey: Key.encoderSpeed)
        d.set(checkForUpdates, forKey: Key.checkForUpdates)
        d.set(onboardingSeen, forKey: Key.onboardingSeen)
        d.set(refreshGrowingFiles, forKey: Key.refreshGrowing)
        d.set(useProxiesForExport, forKey: Key.proxiesForExport)
    }

    /// A BCP-47 identifier as the language list uses it ("de-DE"): letters and hyphens, 2 to 12 characters.
    static func isValidLanguage(_ l: String) -> Bool {
        (2...12).contains(l.count) && l.allSatisfy { $0.isLetter || $0 == "-" }
    }

    /// Transcription language of one project: its override when set, else the default from Settings.
    public static func captionLanguage(forProject id: UUID, from d: UserDefaults = .standard) -> String {
        if let l = d.string(forKey: Key.projectLanguagePrefix + id.uuidString), isValidLanguage(l) { return l }
        return load(from: d).captionLanguage
    }

    /// Stores (or with nil removes) the per-project override.
    public static func setCaptionLanguage(_ l: String?, forProject id: UUID, to d: UserDefaults = .standard) {
        let key = Key.projectLanguagePrefix + id.uuidString
        if let l, isValidLanguage(l) { d.set(l, forKey: key) } else { d.removeObject(forKey: key) }
    }
}
