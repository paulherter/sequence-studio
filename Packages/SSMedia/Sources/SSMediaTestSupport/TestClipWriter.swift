import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Foundation

public enum TestClipError: Error, Sendable { case encoderUnavailable(String), writerFailed(String) }

/// Description of a synthetic test clip. Times are rational (`CMTime`), never Double.
public struct TestClipSpec: Sendable {
    public enum Codec: Sendable { case h264, hevcMain10 }
    public var codec: Codec = .h264
    public var width = 320, height = 180
    public var frameDuration = CMTime(value: 1, timescale: 30)
    public var frameCount = 60
    /// Explicit presentation timestamps (VFR). Overrides `frameCount`/`frameDuration` spacing; must be strictly increasing.
    public var presentationTimes: [CMTime]?
    /// Shifts the first pts (start offset). The writer session starts at 0, so AVAssetReader pads the gap by repeating frame 0 at pts 0 (a leading duplicate stamp).
    public var startOffset = CMTime.zero
    /// Stereo 48 kHz float LPCM with a full-scale 1-sample impulse (both channels) at each time. nil = no audio track.
    public var audioClicks: [CMTime]?

    /// Writes the moov atom before the mdat (`shouldOptimizeForNetworkUse`), so a truncated copy keeps a readable head.
    public var moovAtStart = false

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

public enum TestClipWriter {
    /// Writes a clip into a fresh temp directory and returns its URL (.mov).
    public static func write(_ spec: TestClipSpec) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SSTestClip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.mov")
        let times = spec.resolvedTimes

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let format: OSType
        writer.shouldOptimizeForNetworkUse = spec.moovAtStart
        var compression: [String: Any] = [
            AVVideoAllowFrameReorderingKey: true,
            AVVideoMaxKeyFrameIntervalKey: 12,
            AVVideoExpectedSourceFrameRateKey: Int((Double(spec.frameDuration.timescale) / Double(spec.frameDuration.value)).rounded()),
        ]
        let codec: AVVideoCodecType
        switch spec.codec {
        case .h264:
            codec = .h264; format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevcMain10:
            codec = .hevc; format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw TestClipError.encoderUnavailable("\(spec.codec) settings rejected by AVAssetWriter")
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if spec.audioClicks != nil {
            let s: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: TestClipSpec.audioSampleRate, AVNumberOfChannelsKey: 2,
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
            var data = [Float](repeating: 0, count: n * 2)
            for c in clicks where c >= Int64(audioPos) && c < Int64(audioPos + n) {
                let k = Int(c) - audioPos; data[k * 2] = 1; data[k * 2 + 1] = 1
            }
            let sb = try makeAudioBuffer(data, frames: n, startFrame: audioPos)
            guard aIn.append(sb) else { throw TestClipError.writerFailed(writer.error?.localizedDescription ?? "audio append") }
            audioPos += n
            if audioPos >= totalAudioFrames { aIn.markAsFinished() }   // unfinished audio stalls video interleaving
        }

        // Feed whichever input is ready; the writer's readiness is what interleaves the two tracks.
        var next = 0
        while next < times.count || audioPos < totalAudioFrames {
            var progressed = false
            if next < times.count, vIn.isReadyForMoreMediaData {
                guard let pb = FrameStamp.makePixelBuffer(width: spec.width, height: spec.height, format: format, frame: next) else {
                    throw TestClipError.writerFailed("pixel buffer")
                }
                guard adaptor.append(pb, withPresentationTime: times[next]) else {
                    let msg = writer.error?.localizedDescription ?? "video append"
                    if spec.codec == .hevcMain10 { throw TestClipError.encoderUnavailable("HEVC Main10: \(msg)") }
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
            if spec.codec == .hevcMain10 { throw TestClipError.encoderUnavailable("HEVC Main10: \(msg)") }
            throw TestClipError.writerFailed(msg)
        }
        return url
    }

    private static func makeAudioBuffer(_ data: [Float], frames: Int, startFrame: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(TestClipSpec.audioSampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
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
