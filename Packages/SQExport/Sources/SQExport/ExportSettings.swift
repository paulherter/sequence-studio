import Foundation
import SQCore
#if canImport(SQRender)
import SQRender
#endif

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264, hevc
    /// Intra-frame mastering codecs (FourCC 'apch', 'apcn', 'ap4h'); bitrate, profile and keyframe interval do not apply.
    case prores422HQ, prores422, prores4444
    case prores422LT, prores422Proxy

    public var isMastering: Bool { isProRes }
    public var isProRes: Bool {
        switch self { case .h264, .hevc: false; default: true }
    }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .prores422HQ: "ProRes 422 HQ"
        case .prores422: "ProRes 422"
        case .prores422LT: "ProRes 422 LT"
        case .prores422Proxy: "ProRes 422 Proxy"
        case .prores4444: "ProRes 4444"
        }
    }
}

/// Encoder speed of H.264 / HEVC (ProRes ignores it). A per-Mac preference (AppSettings `sq.export.encoderSpeed`),
/// not part of a preset's look: Quality is the default and is never changed silently; small Macs only get a suggestion.
/// Mapping in `ExportWriter.videoOutputSettings`:
/// - quality: no extra VideoToolbox keys (the encoder's own defaults, unchanged output).
/// - balanced: PrioritizeEncodingSpeedOverQuality, RealTime false, MaximizePowerEfficiency false (Apple's "offline
///   transcode the user waits for"); B-frames as set. Exception: constant bitrate with `ConstantBitRate` leaves RealTime unset
///   (not real time, drops no frame; see `ExportWriter.speedEncoderProperties`).
/// - fast: balanced plus no B-frames and ReferenceBufferCount 1 (fewest reference frames: less memory, least work).
public enum EncoderSpeed: String, Sendable, Codable, CaseIterable {
    case quality, balanced, fast

    public var displayName: String {
        switch self {
        case .quality: "Quality"
        case .balanced: "Balanced"
        case .fast: "Fast"
        }
    }

    /// The speed to suggest (never apply) on this Mac: Balanced at 8 GB of memory or less, else nil.
    public static func suggested(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> EncoderSpeed? {
        physicalMemory <= 8 << 30 ? .balanced : nil
    }
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

/// How the encoder spends the target bitrate (H.264 / HEVC; ProRes has no rate control, see `available(for:)`).
/// - vbr: a single-pass average target, optionally with a data-rate cap (`BitrateMode.maxBitsPerSecond`).
/// - cbr: constant bitrate for broadcast delivery. VideoToolbox `ConstantBitRate` where the encoder has it (the
///   hardware encoders on Apple silicon), else the average target with a 1 s data-rate limit at the target
///   (`ExportWriter.constantBitrateFallback`). Either way through the export's own compression session.
public enum BitrateKind: String, Sendable, Codable, CaseIterable {
    case vbr, cbr
    public var title: String {
        switch self { case .vbr: "VBR"; case .cbr: "CBR" }
    }
    /// Tooltip line of the mode.
    public var help: String {
        switch self {
        case .vbr: "VBR: the bitrate follows the picture around Target, busy scenes get more. Maximum caps it."
        case .cbr: "CBR: the bitrate stays at Target the whole time, for broadcast delivery."
        }
    }
    /// Target field applies to every mode; Maximum only to VBR.
    public var showsMaximum: Bool { self != .cbr }
    /// The modes a codec offers: none for the intra-frame mastering codecs (no switch is shown).
    public static func available(for codec: VideoCodec) -> [BitrateKind] { codec.isMastering ? [] : allCases }
}

public struct VideoSettings: Sendable, Hashable, Codable {
    public var codec: VideoCodec = .h264
    public var width: Int = 1080
    public var height: Int = 1920
    public var frameDuration: Time = Time(1, 30)
    public var profile: VideoProfile = .automatic
    public var bitrate: BitrateMode = .average(12_000_000)
    /// VBR or CBR. A stored Maximum is kept while CBR is on (the encoder ignores it) and applies again in VBR.
    public var bitrateKind: BitrateKind {
        get { constantBitrate == true ? .cbr : .vbr }
        set { constantBitrate = newValue == .cbr ? true : nil }
    }
    /// Stored optional (key absent for VBR) so settings and presets written before it decode as VBR and VBR encodes
    /// exactly as before.
    private var constantBitrate: Bool? = nil
    /// Whether the encoder runs at constant bitrate: CBR on a codec that has rate control.
    public var usesConstantBitrate: Bool { bitrateKind == .cbr && !codec.isMastering && constantQualityStore == nil }
    /// Constant quality (0...1, VideoToolbox quality scale; 0.5 is about CRF 23) instead of a target bitrate: the file size
    /// follows the picture. Stored optional (key absent = bitrate mode) so settings and presets written before it decode
    /// as before. Ignored for ProRes (it has no rate control).
    public var constantQuality: Double? {
        get { codec.isMastering ? nil : constantQualityStore }
        set { constantQualityStore = newValue.map { min(max($0, 0.05), 1) } }
    }
    private var constantQualityStore: Double? = nil
    public var usesConstantQuality: Bool { constantQuality != nil }
    /// Max frames between keyframes.
    public var keyframeInterval: Int = 60
    public var hardwareEncoding: Bool = true
    /// B-frames (frame reordering) for H.264 / HEVC. On the VideoToolbox hardware encoders (M1 Max) they are
    /// quality-neutral at equal bitrate and cost no speed (EngineBench M6, RESULTS.md); on by default.
    /// Ignored for the Baseline profile and intra-only codecs.
    public var allowsFrameReordering: Bool = true
    /// ProRes 4444 only: write the compositor's coverage into the alpha channel (straight color, rendered over
    /// transparent instead of black). Ignored by every other codec; off by default.
    public var preservesAlpha: Bool = false
    /// Shape of one stored pixel, written as the file's pixel aspect (pasp) when it is not square. Stored optional (key
    /// absent for square) so settings and presets written before it decode as square and encode exactly as before.
    public var pixelAspectStore: PixelAspect? = nil
    public var pixelAspect: PixelAspect {
        get { pixelAspectStore ?? .square }
        set { pixelAspectStore = newValue.isSquare ? nil : newValue }
    }
    public init() {}

    /// Bits per component of the encoded picture: 10 for HEVC Main 10 and ProRes 422 (ProRes 4444 is 12-bit in the
    /// bitstream, fed from a 16-bit source), 8 otherwise.
    public var bitDepth: Int {
        if codec.isProRes { return codec == .prores4444 ? 12 : 10 }
        return codec == .hevc && profile == .main10 ? 10 : 8
    }

    private enum CodingKeys: String, CodingKey {
        case codec, width, height, frameDuration, profile, bitrate, keyframeInterval, hardwareEncoding, allowsFrameReordering
        case preservesAlpha, constantBitrate
        case constantQualityStore = "constantQuality"
        case pixelAspectStore = "pixelAspect"
    }

    /// Tolerant decoding: settings written before a key existed keep its default (B-frames on).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? codec
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        frameDuration = try c.decodeIfPresent(Time.self, forKey: .frameDuration) ?? frameDuration
        profile = try c.decodeIfPresent(VideoProfile.self, forKey: .profile) ?? profile
        bitrate = try c.decodeIfPresent(BitrateMode.self, forKey: .bitrate) ?? bitrate
        keyframeInterval = try c.decodeIfPresent(Int.self, forKey: .keyframeInterval) ?? keyframeInterval
        hardwareEncoding = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncoding) ?? hardwareEncoding
        allowsFrameReordering = try c.decodeIfPresent(Bool.self, forKey: .allowsFrameReordering) ?? allowsFrameReordering
        preservesAlpha = try c.decodeIfPresent(Bool.self, forKey: .preservesAlpha) ?? preservesAlpha
        constantBitrate = try c.decodeIfPresent(Bool.self, forKey: .constantBitrate) == true ? true : nil
        if let a = try? c.decodeIfPresent(PixelAspect.self, forKey: .pixelAspectStore), !a.isSquare { pixelAspectStore = a }
        constantQualityStore = try c.decodeIfPresent(Double.self, forKey: .constantQualityStore)
    }
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

/// Two-pass loudness normalization: one linear gain = target - measured integrated loudness,
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
    /// nil = no normalization.
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

/// "Also save cover image": a still of the cover frame written next to the video.
public enum CoverImageFormat: String, Sendable, Codable, CaseIterable {
    case png, jpg
    public var fileExtension: String { rawValue }
}

/// Audio-only delivery: the file holds the mixed audio and no picture. MP3 is not offered (the system has no MP3 encoder).
public enum AudioFileFormat: String, Sendable, Codable, CaseIterable {
    /// AAC in an MPEG-4 audio file.
    case m4a
    /// Uncompressed little-endian integer PCM in a WAVE file.
    case wav
    /// Lossless FLAC (written through AVAudioFile; 16 or 24 bit).
    case flac
    public var fileExtension: String { rawValue }
    public var codec: AudioCodec { self == .m4a ? .aac : .pcm }
    public var displayName: String {
        switch self { case .m4a: "M4A (AAC)"; case .wav: "WAV (PCM)"; case .flac: "FLAC (lossless)" }
    }
}

/// Output that is not one video file: an animated GIF, or a folder of numbered still images (one per frame).
public enum FrameOutput: Sendable, Hashable, Codable {
    case gif
    case sequence(FrameStillFormat)

    public var displayName: String {
        switch self {
        case .gif: "Animated GIF"
        case .sequence(let f): "Image sequence · \(f.displayName)"
        }
    }
}

public enum CaptionMode: String, Sendable, Codable {
    case none, burnIn, sidecarSRT, sidecarVTT, sidecarITT
    /// Extension of the sidecar file (nil = no sidecar).
    public var sidecarExtension: String? {
        switch self {
        case .sidecarSRT: "srt"
        case .sidecarVTT: "vtt"
        case .sidecarITT: "itt"
        case .none, .burnIn: nil
        }
    }

    /// Writes the cues in this mode's sidecar format (no-op for modes without a sidecar).
    public func writeSidecar(_ cues: [SRTCue], range: RangeSelection, language: String = "en", to url: URL) throws {
        switch self {
        case .sidecarSRT: try SRTWriter.write(cues, range: range, to: url)
        case .sidecarVTT: try VTTWriter.write(cues, range: range, to: url)
        case .sidecarITT: try ITTWriter.write(cues, language: language, range: range, to: url)
        case .none, .burnIn: break
        }
    }
}

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
    /// W5.1: the sequence's format variant to render (nil = the sequence's own format). The source provider evaluates
    /// `Project.variantView(of:variant:)`; absent in older settings and presets.
    public var variant: FormatVariant.ID? = nil
    /// Also save the cover frame as a still next to the video (nil = off). Absent in older settings and presets.
    public var coverImage: CoverImageFormat? = nil
    /// Sequence time of the cover frame (the "Cover" marker, see `CoverFrame`); nil = the first exported frame.
    public var coverTime: Time? = nil
    /// A source frame that cannot be decoded is drawn as the damaged placeholder (like the Program monitor) instead of
    /// stopping the export with the clip and time. Off by default.
    public var continueOnDamagedFrames: Bool {
        get { damagedFrames ?? false }
        set { damagedFrames = newValue ? true : nil }
    }
    /// Stored optional so settings and presets written before it decode unchanged.
    private var damagedFrames: Bool? = nil
    /// H.264 / HEVC encoder speed; Quality by default. Set from AppSettings by the app (a per-Mac preference).
    public var encoderSpeed: EncoderSpeed {
        get { speed ?? .quality }
        set { speed = newValue == .quality ? nil : newValue }
    }
    /// Stored optional (key absent at Quality) so settings and presets encode exactly as before.
    private var speed: EncoderSpeed? = nil
    /// "Best quality at size": H.264 / HEVC encoded in several VideoToolbox passes (BeginPass / EndPass with a
    /// MultiPassStorage) at the average bitrate. Stored optional (key absent = one pass) so settings and presets written
    /// before it decode and encode exactly as before.
    public var multiPass: Bool {
        get { multiPassStore ?? false }
        set { multiPassStore = newValue ? true : nil }
    }
    private var multiPassStore: Bool? = nil
    /// Whether the export runs multi-pass: only a bitrate target has a size to hold (not CBR, not constant quality, not ProRes),
    /// and only the software encoder does it. Measured on Apple silicon (2026-10-17): the hardware H.264 / HEVC encoders take the
    /// `MultiPassStorage` but then stop with a session malfunction (-17691); the software H.264 encoder runs it, without
    /// B-frames (CompleteFrames fails with them); the software HEVC encoder takes no storage and encodes one pass.
    public var usesMultiPass: Bool {
        multiPass && !video.hardwareEncoding && !video.codec.isMastering && !video.usesConstantBitrate && !video.usesConstantQuality
            && audioOnly == nil && frameOutput == nil
    }
    /// Audio-only export (no picture): nil = a video file. Stored optional so older settings and presets decode unchanged.
    public var audioOnly: AudioFileFormat? = nil
    /// GIF or numbered image sequence instead of a video file (nil = a video file). Stored optional, like `audioOnly`.
    public var frameOutput: FrameOutput? = nil
    /// Title, comment, creation date and chapters written into the file (nil = none). Stored optional like `audioOnly`.
    public var metadata: ExportMetadata? = nil
    /// HDR to SDR trim for this export (exposure gain, gamut compression); nil = the default tone map. Independent of the
    /// project; stored optional so settings and presets written before it decode and encode unchanged.
    public var hdrToSDR: HDRToSDR? = nil
    /// HDR delivery tags (HLG/PQ, Rec.2020) with MDCV/CLLI metadata; nil = SDR Rec.709. Applies to HEVC only (forced Main 10).
    public var hdrDelivery: HDRDelivery? = nil
    public init() {}

    /// The audio settings the writer uses: an audio-only file's format decides the codec.
    public var effectiveAudio: AudioSettings {
        var a = audio
        if let f = audioOnly { a.codec = f.codec }
        return a
    }

    /// Settings with what an audio-only file cannot carry switched off (burned-in captions, cover image).
    public var forDelivery: ExportSettings {
        guard audioOnly != nil || frameOutput != nil else { return self }
        var s = self
        if s.captions == .burnIn { s.captions = .none }
        s.coverImage = nil; s.coverTime = nil
        return s
    }

    public func validate() -> Set<ExportSettingsIssue> {
        var r = Set<ExportSettingsIssue>()
        if audioOnly != nil {
            if !audio.enabled { r.insert(.invalidAudio) }
        } else if frameOutput != nil {
            // Pictures have no chroma subsampling: any positive size, no bitrate, no keyframes, no audio.
            if video.width <= 0 || video.height <= 0 { r.insert(.oddDimensions) }
        } else if video.width <= 0 || video.height <= 0 || video.width % 2 != 0 || video.height % 2 != 0 { r.insert(.oddDimensions) }
        if audioOnly == nil, frameOutput == nil, !video.codec.isMastering {
            if video.bitrate.averageBitsPerSecond <= 0 { r.insert(.nonPositiveBitrate) }
            if let m = video.bitrate.maxBitsPerSecond, m < video.bitrate.averageBitsPerSecond { r.insert(.nonPositiveBitrate) }
            if video.keyframeInterval <= 0 { r.insert(.invalidKeyframeInterval) }
        }
        if audioOnly == nil, video.frameDuration.value <= 0 { r.insert(.invalidFrameDuration) }
        let a = effectiveAudio
        if frameOutput != nil { return r }
        if a.enabled && (a.channels <= 0 || a.sampleRate <= 0
                         || (a.codec == .aac && a.bitrate <= 0)
                         || (a.codec == .pcm && ![16, 24, 32].contains(a.pcmBitDepth))
                         || (audioOnly == .flac && ![16, 24].contains(a.pcmBitDepth))) { r.insert(.invalidAudio) }
        return r
    }

    /// ProRes 422 HQ reference rate: 220 Mbit/s at 1920x1080, 29.97 fps (Apple's published target); scales with pixels and frame rate.
    static let proRes422HQReferenceBitsPerSecond: Int128 = 220_000_000

    /// Apple's published target rates at 1920x1080, 29.97 fps: 422 147, 422 HQ 220, 4444 330 Mbit/s (EXP-04, per profile).
    static func proResReferenceBitsPerSecond(_ codec: VideoCodec) -> Int128 {
        switch codec {
        case .prores422: 147_000_000
        case .prores422LT: 102_000_000
        case .prores422Proxy: 45_000_000
        case .prores4444: 330_000_000
        default: proRes422HQReferenceBitsPerSecond
        }
    }

    /// Estimated video bitrate in bits per second. Mastering codecs have no bitrate setting, so ProRes is derived from its reference rate.
    public var estimatedVideoBitsPerSecond: Int64 {
        guard audioOnly == nil, frameOutput == nil else { return 0 }
        guard video.codec.isMastering else { return Int64(video.bitrate.averageBitsPerSecond) }
        guard video.frameDuration.value > 0, video.width > 0, video.height > 0 else { return 0 }
        // ref * (w*h / (1920*1080)) * (fps / (30000/1001))
        let num = Self.proResReferenceBitsPerSecond(video.codec) * Int128(video.width) * Int128(video.height)
            * Int128(video.frameDuration.timescale) * 1001
        let den = Int128(1920 * 1080) * Int128(video.frameDuration.value) * 30000
        return Int64(num / den)
    }

    /// Audio bits per second: PCM from its format, AAC from its bitrate.
    public var estimatedAudioBitsPerSecond: Int64 {
        let audio = effectiveAudio
        guard audio.enabled, frameOutput == nil else { return 0 }
        // FLAC: about 60 percent of the PCM rate for mixed program material.
        if audioOnly == .flac { return Int64(audio.sampleRate) * Int64(audio.channels) * Int64(audio.pcmBitDepth) * 6 / 10 }
        if audio.codec == .pcm { return Int64(audio.sampleRate) * Int64(audio.channels) * Int64(audio.pcmBitDepth) }
        return Int64(audio.bitrate)
    }

    /// Rough output size in bytes: (video + audio bitrate) * duration / 8, truncated.
    public func estimatedFileSize(duration: Time) -> Int64 {
        let bps = estimatedVideoBitsPerSecond + estimatedAudioBitsPerSecond
        return Int64((Int128(bps) * Int128(duration.value)) / (8 * Int128(duration.timescale)))
    }
}

public extension ExportSettings {
    /// Container file extension: MOV for mastering codecs, MP4 otherwise.
    var fileExtension: String {
        switch frameOutput {
        case .gif?: return "gif"
        case .sequence?: return ""        // a folder
        case nil: return audioOnly?.fileExtension ?? (video.codec.isMastering ? "mov" : "mp4")
        }
    }

    /// Pixel format the frame source renders for this codec, so no 8-bit BGRA step sits in front of a 10-bit encoder:
    /// 4:2:0 8-bit for H.264 / HEVC Main, 4:2:0 10-bit for HEVC Main 10, 4:2:2 10-bit for ProRes 422 (HQ),
    /// 4:4:4:4 16-bit for ProRes 4444 (opaque, or with the compositor's coverage as straight alpha when `preservesAlpha`).
    /// The HDR delivery tags when they apply: HEVC video only (needs 10 bits); ProRes, H.264, pictures and audio stay SDR.
    var appliedHDRDelivery: HDRDelivery? {
        video.codec == .hevc && audioOnly == nil && frameOutput == nil ? hdrDelivery : nil
    }

    var sourcePixelFormat: ExportPixelFormat {
        switch frameOutput {
        case .sequence?: return .rgbaHalf
        case .gif?: return .bgra8
        case nil: break
        }
        switch video.codec {
        case .h264: return .yuv420v
        case .hevc: return video.profile == .main10 || appliedHDRDelivery != nil ? .yuv420v10 : .yuv420v
        case .prores422HQ, .prores422, .prores422LT, .prores422Proxy: return .yuv422v10
        case .prores4444: return video.preservesAlpha ? .ayuv4444Alpha : .ayuv4444
        }
    }

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

/// Export-time HDR to SDR conversion options: the tone map itself is always on for HDR sources; this trims it for the file
/// (a brighter or darker result, colors outside Rec.709 eased in instead of clipped). Applies to sources without a LUT-based
/// input conversion. Not HDR tagging: the file stays SDR Rec.709.
public struct HDRToSDR: Sendable, Hashable, Codable {
    /// Gain in stops before the roll-off, -4...4.
    public var exposureStops: Double
    public var compressesGamut: Bool
    public init(exposureStops: Double = 0, compressesGamut: Bool = true) {
        self.exposureStops = min(max(exposureStops, -4), 4); self.compressesGamut = compressesGamut
    }
    /// Neutral values: same output as no setting except for the gamut compression.
    public var isDefault: Bool { exposureStops == 0 && !compressesGamut }
    #if canImport(SQRender)
    public func applied(to base: ToneMapping) -> ToneMapping {
        var t = base
        t.exposureStops = Float(exposureStops)
        t.compressesGamut = compressesGamut
        return t
    }
    #endif
}
