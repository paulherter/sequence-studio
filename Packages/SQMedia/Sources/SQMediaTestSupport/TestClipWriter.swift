import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import VideoToolbox
import Foundation

public enum TestClipError: Error, Sendable { case encoderUnavailable(String), writerFailed(String) }

/// Description of a synthetic test clip. Times are rational (`CMTime`), never Double.
public struct TestClipSpec: Sendable {
    /// `prores4444Alpha` (tagged straight alpha) and `hevcAlpha` (tagged premultiplied) carry `AlphaTestPattern` instead of
    /// the frame stamp.
    public enum Codec: Sendable { case h264, hevcMain10, prores4444, prores4444Alpha, hevcAlpha }
    public var codec: Codec = .h264
    public var width = 320, height = 180
    public var frameDuration = CMTime(value: 1, timescale: 30)
    public var frameCount = 60
    /// Explicit presentation timestamps (VFR). Overrides `frameCount`/`frameDuration` spacing; must be strictly increasing.
    public var presentationTimes: [CMTime]?
    /// Shifts the first pts (start offset). The writer session starts at 0, so AVAssetReader pads the gap by repeating frame 0 at pts 0 (a leading duplicate stamp).
    public var startOffset = CMTime.zero
    /// 48 kHz float LPCM with a full-scale 1-sample impulse (all channels) at each time. nil = no audio track.
    public var audioClicks: [CMTime]?
    /// Channel count of the audio track (1 = mono, like iPhone voice clips; 2 = stereo).
    public var audioChannels = 2

    /// Writes the moov atom before the mdat (`shouldOptimizeForNetworkUse`), so a truncated copy keeps a readable head.
    public var moovAtStart = false

    /// Clockwise degrees (0/90/180/270) written as the video track's preferred transform (phone clips). Pixels stay
    /// `width` x `height`; players turn the picture.
    public var rotation = 0

    /// Pixel aspect tag (pasp) written into the video track, horizontal : vertical spacing of one pixel (H.264 / HEVC only).
    public var pixelAspect: (horizontal: Int, vertical: Int)?

    public static let audioSampleRate = 48_000

    public init() {}
    public static func fps(_ n: Int32, _ d: Int32 = 1) -> CMTime { CMTime(value: CMTimeValue(d), timescale: n) }

    /// Presentation timestamps the writer will use, frame i carrying stamp i.
    public var resolvedTimes: [CMTime] {
        if let p = presentationTimes { return p }
        return (0..<frameCount).map { CMTimeAdd(startOffset, CMTimeMultiply(frameDuration, multiplier: Int32($0))) }
    }

    /// Sample index of a click time at 48 kHz (rounded to nearest).
    public static func sampleIndex(of t: CMTime) -> Int64 {
        Int64((Double(t.value) * Double(audioSampleRate) / Double(t.timescale)).rounded())
    }
}

/// Picture of the alpha test clips: one color, alpha by column. Left half opaque, third quarter half transparent
/// (alpha 128), right quarter fully transparent. Color channels hold `color` (straight) or `color * alpha / 255`
/// (premultiplied); fully transparent pixels hold 0 either way.
public enum AlphaTestPattern {
    /// Straight color, 8-bit R, G, B.
    public static let color: (r: UInt8, g: UInt8, b: UInt8) = (230, 120, 40)

    public static func alpha(x: Int, width: Int) -> UInt8 { x < width / 2 ? 255 : x < width * 3 / 4 ? 128 : 0 }

    public static func makePixelBuffer(width: Int, height: Int, premultiplied: Bool) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let a = alpha(x: x, width: width)
                func c(_ v: UInt8) -> UInt8 {
                    a == 0 ? 0 : premultiplied ? UInt8((Int(v) * Int(a) + 127) / 255) : v
                }
                row[x * 4] = c(color.b); row[x * 4 + 1] = c(color.g); row[x * 4 + 2] = c(color.r); row[x * 4 + 3] = a
            }
        }
        return pb
    }
}

public enum TestClipWriter {
    /// Bump when the encoding below changes in a way the spec does not capture: old cache entries are then skipped.
    public static let cacheFormatVersion = 1

    /// Shared cache of encoded clips, keyed by every spec field that shapes the output: `$TMPDIR/SQTestClipCache/<sha256>.mov`.
    public static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SQTestClipCache", isDirectory: true)
    }

    /// Writes a clip into a fresh temp directory (`$TMPDIR/SQTestClip-<uuid>/clip.mov`) and returns its URL. The caller
    /// owns that file: it may be deleted, truncated or given a new modification date. Encoding happens once per spec: the
    /// result lives in `cacheDirectory` (written to a temp name, then renamed, so parallel test processes never see a
    /// half file) and every call hands out an APFS clone of it.
    public static func write(_ spec: TestClipSpec) async throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SQTestClip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.mov")
        let cached = cacheDirectory.appendingPathComponent("\(cacheKey(spec)).mov")
        if !fm.fileExists(atPath: cached.path) {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let staging = cacheDirectory.appendingPathComponent("staging-\(UUID().uuidString).mov")
            do {
                try await encode(spec, to: staging)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            // rename(2) is atomic and replaces an entry another process finished first (same content either way).
            guard rename(staging.path, cached.path) == 0 else {
                let err = errno
                try? fm.removeItem(at: staging)
                throw TestClipError.writerFailed("rename into cache: \(String(cString: strerror(err)))")
            }
        }
        try fm.copyItem(at: cached, to: url)   // a clone on APFS: no data copied
        return url
    }

    /// SHA-256 of every field that changes the encoded bytes plus the writer version and the OS (encoders differ by release).
    public static func cacheKey(_ spec: TestClipSpec) -> String {
        func t(_ x: CMTime) -> String { "\(x.value)/\(x.timescale)" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let parts: [String] = [
            "v\(cacheFormatVersion)", "os\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "codec=\(spec.codec)", "size=\(spec.width)x\(spec.height)", "fd=\(t(spec.frameDuration))", "n=\(spec.frameCount)",
            "pts=\(spec.presentationTimes.map { $0.map(t).joined(separator: ",") } ?? "nil")",
            "start=\(t(spec.startOffset))",
            "clicks=\(spec.audioClicks.map { $0.map(t).joined(separator: ",") } ?? "nil")",
            "ch=\(spec.audioChannels)", "moov=\(spec.moovAtStart)", "rot=\(spec.rotation)",
            "par=\(spec.pixelAspect.map { "\($0.horizontal):\($0.vertical)" } ?? "nil")",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: ";").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ spec: TestClipSpec, to url: URL) async throws {
        let times = spec.resolvedTimes

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let format: OSType
        writer.shouldOptimizeForNetworkUse = spec.moovAtStart
        var compression: [String: Any] = [
            AVVideoAllowFrameReorderingKey: true,
            AVVideoMaxKeyFrameIntervalKey: 12,
            AVVideoExpectedSourceFrameRateKey: Int((Double(spec.frameDuration.timescale) / Double(spec.frameDuration.value)).rounded()),
        ]
        if let par = spec.pixelAspect {
            compression[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: par.horizontal,
                                                       AVVideoPixelAspectRatioVerticalSpacingKey: par.vertical]
        }
        let codec: AVVideoCodecType
        switch spec.codec {
        case .h264:
            codec = .h264; format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevcMain10:
            codec = .hevc; format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .prores4444:
            // Intra-only; BGRA input with an opaque alpha channel (FrameStamp writes alpha 1).
            codec = .proRes4444; format = kCVPixelFormatType_32BGRA
        case .prores4444Alpha:
            codec = .proRes4444; format = kCVPixelFormatType_32BGRA
        case .hevcAlpha:
            codec = .hevcWithAlpha; format = kCVPixelFormatType_32BGRA
            compression = [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0, AVVideoQualityKey: 1.0]
        }
        var videoSettings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height]
        if spec.codec != .prores4444 && spec.codec != .prores4444Alpha { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw TestClipError.encoderUnavailable("\(spec.codec) settings rejected by AVAssetWriter")
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = false
        if spec.rotation != 0 { vIn.transform = CGAffineTransform(rotationAngle: CGFloat(spec.rotation) * .pi / 180) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if spec.audioClicks != nil {
            let s: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: TestClipSpec.audioSampleRate, AVNumberOfChannelsKey: spec.audioChannels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: s)
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }

        guard writer.startWriting() else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        // Session at 0 keeps the start offset (a session at the first pts makes the writer rebase to 0).
        writer.startSession(atSourceTime: .zero)

        // Audio plan: float32 interleaved stereo, length = clip end (last pts + one frame), chunks of 4800 frames.
        let clipEnd = CMTimeAdd(times.last ?? .zero, spec.frameDuration)
        let totalAudioFrames = spec.audioClicks == nil ? 0 : Int(TestClipSpec.sampleIndex(of: clipEnd))
        let clicks = Set((spec.audioClicks ?? []).map(TestClipSpec.sampleIndex(of:)))
        var audioPos = 0
        let chunk = 4800

        func appendNextAudio() throws {
            guard let aIn, audioPos < totalAudioFrames else { return }
            let n = min(chunk, totalAudioFrames - audioPos)
            let ch = spec.audioChannels
            var data = [Float](repeating: 0, count: n * ch)
            for c in clicks where c >= Int64(audioPos) && c < Int64(audioPos + n) {
                let k = Int(c) - audioPos
                for j in 0..<ch { data[k * ch + j] = 1 }
            }
            let sb = try makeAudioBuffer(data, frames: n, channels: ch, startFrame: audioPos)
            guard aIn.append(sb) else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "audio append") }
            audioPos += n
            if audioPos >= totalAudioFrames { aIn.markAsFinished() }   // unfinished audio stalls video interleaving
        }

        // Feed whichever input is ready; the writer's readiness is what interleaves the two tracks.
        var next = 0
        while next < times.count || audioPos < totalAudioFrames {
            var progressed = false
            if next < times.count, vIn.isReadyForMoreMediaData {
                let made = switch spec.codec {
                case .prores4444Alpha: AlphaTestPattern.makePixelBuffer(width: spec.width, height: spec.height, premultiplied: false)
                case .hevcAlpha: AlphaTestPattern.makePixelBuffer(width: spec.width, height: spec.height, premultiplied: true)
                default: FrameStamp.makePixelBuffer(width: spec.width, height: spec.height, format: format, frame: next)
                }
                guard let pb = made else {
                    throw TestClipError.writerFailed("pixel buffer")
                }
                guard adaptor.append(pb, withPresentationTime: times[next]) else {
                    let msg = writer.error?.localizedDescription ?? "video append"
                    if spec.codec == .hevcMain10 || spec.codec == .hevcAlpha { throw TestClipError.encoderUnavailable("HEVC Main10: \(msg)") }
                    throw TestClipError.writerFailed(msg)
                }
                next += 1; progressed = true
            }
            if let aIn, audioPos < totalAudioFrames, aIn.isReadyForMoreMediaData { try appendNextAudio(); progressed = true }
            if !progressed {
                if writer.status == .failed { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        vIn.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
            if spec.codec == .hevcMain10 || spec.codec == .hevcAlpha { throw TestClipError.encoderUnavailable("HEVC: \(msg)") }
            throw TestClipError.writerFailed(msg)
        }
    }

    private static func makeAudioBuffer(_ data: [Float], frames: Int, channels: Int, startFrame: Int) throws -> CMSampleBuffer {
        let bpf = UInt32(4 * channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(TestClipSpec.audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: bpf, mFramesPerPacket: 1,
            mBytesPerFrame: bpf, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr, let fd
        else { throw TestClipError.writerFailed("audio format") }
        let bytes = data.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr
        else { throw TestClipError.writerFailed("audio block") }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(TestClipSpec.audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb
        else { throw TestClipError.writerFailed("audio sample buffer") }
        return sb
    }
}
