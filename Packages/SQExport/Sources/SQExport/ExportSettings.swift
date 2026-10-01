import SQCore

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264, hevc
    /// Intra-frame mastering codec (FourCC 'apch'); bitrate, profile and keyframe interval do not apply.
    case prores422HQ

    public var isMastering: Bool { self == .prores422HQ }
}

public enum VideoProfile: String, Sendable, Codable { case automatic, baseline, main, high, main10 }

public enum BitrateMode: Sendable, Hashable, Codable {
    case average(Int)
    case averageAndMax(average: Int, max: Int)

    public var averageBitsPerSecond: Int {
        switch self { case .average(let a): a; case .averageAndMax(let a, _): a }
    }
    public var maxBitsPerSecond: Int? {
        switch self { case .average: nil; case .averageAndMax(_, let m): m }
    }
}

public struct VideoSettings: Sendable, Hashable, Codable {
    public var codec: VideoCodec = .h264
    public var width: Int = 1080
    public var height: Int = 1920
    public var frameDuration: Time = Time(1, 30)
    public var profile: VideoProfile = .automatic
    public var bitrate: BitrateMode = .average(12_000_000)
    /// Max frames between keyframes.
    public var keyframeInterval: Int = 60
    public var hardwareEncoding: Bool = true
    public init() {}
}

public enum ColorPrimaries: String, Sendable, Codable { case itu709 }
public enum ColorTransfer: String, Sendable, Codable { case itu709 }
public enum ColorMatrix: String, Sendable, Codable { case itu709 }

/// Output is always Rec.709, tagged 1-1-1.
public struct ColorSettings: Sendable, Hashable, Codable {
    public var primaries: ColorPrimaries
    public var transfer: ColorTransfer
    public var matrix: ColorMatrix
    public static let rec709 = ColorSettings(primaries: .itu709, transfer: .itu709, matrix: .itu709)
    public init(primaries: ColorPrimaries = .itu709, transfer: ColorTransfer = .itu709, matrix: ColorMatrix = .itu709) {
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
    }
}

/// `pcm` = uncompressed little-endian integer PCM (`AudioSettings.pcmBitDepth`), for mastering.
public enum AudioCodec: String, Sendable, Codable { case aac, pcm }

/// Two-pass loudness normalisation: one linear gain = target - measured integrated loudness,
/// limited so the resulting true peak stays at or below `truePeakCeilingDB`.
public struct LoudnessNormalization: Sendable, Hashable, Codable {
    /// Target integrated loudness in LUFS.
    public var targetLUFS: Double
    /// Maximum true peak after gain in dBTP.
    public var truePeakCeilingDB: Double
    public init(targetLUFS: Double = -14, truePeakCeilingDB: Double = -1) {
        self.targetLUFS = targetLUFS; self.truePeakCeilingDB = truePeakCeilingDB
    }
}

public struct AudioSettings: Sendable, Hashable, Codable {
    public var enabled: Bool = true
    public var codec: AudioCodec = .aac
    public var sampleRate: Int = 48_000
    public var channels: Int = 2
    /// AAC only.
    public var bitrate: Int = 192_000
    /// PCM only: 16, 24 or 32.
    public var pcmBitDepth: Int = 24
    /// nil = no normalisation.
    public var loudness: LoudnessNormalization? = nil
    public init() {}

    /// Compatibility view of `loudness` as a whole-LUFS target (not encoded). Setting keeps an existing ceiling.
    public var loudnessTarget: Int? {
        get { loudness.map { Int($0.targetLUFS.rounded()) } }
        set {
            guard let t = newValue else { loudness = nil; return }
            loudness = LoudnessNormalization(targetLUFS: Double(t),
                                             truePeakCeilingDB: loudness?.truePeakCeilingDB ?? LoudnessNormalization().truePeakCeilingDB)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, codec, sampleRate, channels, bitrate, pcmBitDepth, loudness
        case loudnessTarget   // legacy: Int LUFS, decode only
    }

    /// Tolerant decoding: missing keys keep defaults; the legacy `loudnessTarget` (Int LUFS) maps to `loudness`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        codec = try c.decodeIfPresent(AudioCodec.self, forKey: .codec) ?? codec
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? sampleRate
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? channels
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? bitrate
        pcmBitDepth = try c.decodeIfPresent(Int.self, forKey: .pcmBitDepth) ?? pcmBitDepth
        if let l = try c.decodeIfPresent(LoudnessNormalization.self, forKey: .loudness) {
            loudness = l
        } else if let legacy = try c.decodeIfPresent(Int.self, forKey: .loudnessTarget) {
            loudness = LoudnessNormalization(targetLUFS: Double(legacy))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(codec, forKey: .codec)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channels, forKey: .channels)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encode(pcmBitDepth, forKey: .pcmBitDepth)
        try c.encodeIfPresent(loudness, forKey: .loudness)
    }
}

public enum CaptionMode: String, Sendable, Codable { case none, burnIn, sidecarSRT }

public enum RangeSelection: Sendable, Hashable, Codable {
    case entireSequence
    case inOut(TimeRange)
}

public enum ExportSettingsIssue: Sendable, Hashable {
    case oddDimensions, nonPositiveBitrate, invalidKeyframeInterval, invalidFrameDuration, invalidAudio
}

public struct ExportSettings: Sendable, Hashable, Codable {
    public var video = VideoSettings()
    public var color = ColorSettings.rec709
    public var audio = AudioSettings()
    public var captions: CaptionMode = .none
    public var range: RangeSelection = .entireSequence
    public init() {}

    public func validate() -> Set<ExportSettingsIssue> {
        var r = Set<ExportSettingsIssue>()
        if video.width <= 0 || video.height <= 0 || video.width % 2 != 0 || video.height % 2 != 0 { r.insert(.oddDimensions) }
        if !video.codec.isMastering {
            if video.bitrate.averageBitsPerSecond <= 0 { r.insert(.nonPositiveBitrate) }
            if let m = video.bitrate.maxBitsPerSecond, m < video.bitrate.averageBitsPerSecond { r.insert(.nonPositiveBitrate) }
            if video.keyframeInterval <= 0 { r.insert(.invalidKeyframeInterval) }
        }
        if video.frameDuration.value <= 0 { r.insert(.invalidFrameDuration) }
        if audio.enabled && (audio.channels <= 0 || audio.sampleRate <= 0
                             || (audio.codec == .aac && audio.bitrate <= 0)
                             || (audio.codec == .pcm && ![16, 24, 32].contains(audio.pcmBitDepth))) { r.insert(.invalidAudio) }
        return r
    }

    /// Rough output size in bytes: (video + audio bitrate) * duration / 8, truncated.
    public func estimatedFileSize(duration: Time) -> Int64 {
        let bps = Int64(video.bitrate.averageBitsPerSecond) + (audio.enabled ? Int64(audio.bitrate) : 0)
        return Int64((Int128(bps) * Int128(duration.value)) / (8 * Int128(duration.timescale)))
    }
}

public extension ExportSettings {
    /// Container file extension: MOV for mastering codecs, MP4 otherwise.
    var fileExtension: String { video.codec.isMastering ? "mov" : "mp4" }

    /// "ProRes 422 HQ master": ProRes 422 HQ in MOV, Rec.709 1-1-1, 24-bit 48 kHz stereo PCM.
    /// Size and frame rate are meant to be set from the sequence.
    static var proRes422HQMaster: ExportSettings {
        var s = ExportSettings()
        s.video.codec = .prores422HQ
        s.video.width = 1920; s.video.height = 1080
        s.video.frameDuration = Time(1, 30)
        s.video.profile = .automatic
        s.video.hardwareEncoding = true
        s.color = .rec709
        s.audio.codec = .pcm
        s.audio.pcmBitDepth = 24
        s.audio.sampleRate = 48_000
        s.audio.channels = 2
        return s
    }
}
