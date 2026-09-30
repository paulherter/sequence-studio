import SSCore

public enum VideoCodec: String, Sendable, Codable, CaseIterable { case h264, hevc }

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

public enum AudioCodec: String, Sendable, Codable { case aac }

public struct AudioSettings: Sendable, Hashable, Codable {
    public var enabled: Bool = true
    public var codec: AudioCodec = .aac
    public var sampleRate: Int = 48_000
    public var channels: Int = 2
    public var bitrate: Int = 192_000
    /// Model only: target integrated loudness in LUFS (e.g. -14). nil = off.
    public var loudnessTarget: Int? = nil
    public init() {}
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
        if video.bitrate.averageBitsPerSecond <= 0 { r.insert(.nonPositiveBitrate) }
        if let m = video.bitrate.maxBitsPerSecond, m < video.bitrate.averageBitsPerSecond { r.insert(.nonPositiveBitrate) }
        if video.keyframeInterval <= 0 { r.insert(.invalidKeyframeInterval) }
        if video.frameDuration.value <= 0 { r.insert(.invalidFrameDuration) }
        if audio.enabled && (audio.channels <= 0 || audio.sampleRate <= 0 || audio.bitrate <= 0) { r.insert(.invalidAudio) }
        return r
    }

    /// Rough output size in bytes: (video + audio bitrate) * duration / 8, truncated.
    public func estimatedFileSize(duration: Time) -> Int64 {
        let bps = Int64(video.bitrate.averageBitsPerSecond) + (audio.enabled ? Int64(audio.bitrate) : 0)
        return Int64((Int128(bps) * Int128(duration.value)) / (8 * Int128(duration.timescale)))
    }
}
