import Foundation

/// What the export dialog remembers between exports (stored by the app in UserDefaults as JSON): the last preset and the
/// per-export choices a preset does not own. Absent keys decode to the defaults, so an older or damaged value never
/// stops the dialog from opening.
public struct ExportPreferences: Codable, Sendable, Equatable {
    public static let customPresetID = "custom"

    public var presetID: String
    public var captions: CaptionMode
    public var coverImage: CoverImageFormat?
    public var continueOnDamagedFrames: Bool
    public var audioEnabled: Bool
    public var normalizeLoudness: Bool
    public var exportAllFormats: Bool
    /// Hand-edited video and audio settings; only kept while the preset is "Custom".
    public var customVideo: VideoSettings?
    public var customAudio: AudioSettings?

    public init(presetID: String, settings: ExportSettings, exportAllFormats: Bool = false) {
        self.presetID = presetID
        captions = settings.captions
        coverImage = settings.coverImage
        continueOnDamagedFrames = settings.continueOnDamagedFrames
        audioEnabled = settings.audio.enabled
        normalizeLoudness = settings.audio.loudness != nil
        self.exportAllFormats = exportAllFormats
        let custom = presetID == Self.customPresetID
        customVideo = custom ? settings.video : nil
        customAudio = custom ? settings.audio : nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        presetID = (try? c.decode(String.self, forKey: .presetID)) ?? ExportPreset.default.id
        captions = (try? c.decode(CaptionMode.self, forKey: .captions)) ?? .none
        coverImage = try? c.decode(CoverImageFormat.self, forKey: .coverImage)
        continueOnDamagedFrames = (try? c.decode(Bool.self, forKey: .continueOnDamagedFrames)) ?? false
        audioEnabled = (try? c.decode(Bool.self, forKey: .audioEnabled)) ?? true
        normalizeLoudness = (try? c.decode(Bool.self, forKey: .normalizeLoudness)) ?? false
        exportAllFormats = (try? c.decode(Bool.self, forKey: .exportAllFormats)) ?? false
        customVideo = try? c.decode(VideoSettings.self, forKey: .customVideo)
        customAudio = try? c.decode(AudioSettings.self, forKey: .customAudio)
    }

    private enum Keys: String, CodingKey {
        case presetID, captions, coverImage, continueOnDamagedFrames, audioEnabled, normalizeLoudness, exportAllFormats
        case customVideo, customAudio
    }

    /// The preset this restores (nil for "Custom" or a preset that no longer exists).
    public var preset: ExportPreset? { ExportPreset.all.first { $0.id == presetID } }

    /// Puts the remembered choices on `settings`, which hold the preset's values. `loudness` is the target a normalized
    /// export uses here (the sequence's delivery target or the preset's platform target).
    public func apply(to settings: inout ExportSettings, loudness: LoudnessNormalization) {
        if presetID == Self.customPresetID, let v = customVideo {
            settings.video = v
            if let a = customAudio { settings.audio = a }
        }
        settings.captions = captions
        settings.coverImage = coverImage
        settings.continueOnDamagedFrames = continueOnDamagedFrames
        settings.audio.enabled = audioEnabled
        settings.audio.loudness = normalizeLoudness ? loudness : nil
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> ExportPreferences? {
        data.flatMap { try? JSONDecoder().decode(ExportPreferences.self, from: $0) }
    }
}
