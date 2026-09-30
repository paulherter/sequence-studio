import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SSCore
import VideoToolbox

public enum ExportError: Error, Sendable, Equatable {
    case invalidSettings(Set<ExportSettingsIssue>)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case writerFailed(String)
    case emptySource
    /// Loudness normalisation is on but the audio source cannot be read twice.
    case loudnessNeedsRewindableSource
}

/// Writes frames (and optionally audio) to an MP4/MOV with Rec.709 1-1-1 tags via AVAssetWriter.
public enum ExportWriter {
    public static func videoOutputSettings(_ s: ExportSettings) -> [String: Any] {
        let v = s.video
        var comp: [String: Any] = [
            AVVideoAverageBitRateKey: v.bitrate.averageBitsPerSecond,
            AVVideoMaxKeyFrameIntervalKey: v.keyframeInterval,
            AVVideoExpectedSourceFrameRateKey: Int((Double(v.frameDuration.timescale) / Double(v.frameDuration.value)).rounded()),
            AVVideoAllowFrameReorderingKey: false,
        ]
        if let m = v.bitrate.maxBitsPerSecond {
            comp[kVTCompressionPropertyKey_DataRateLimits as String] = [m / 8, 1]
        }
        switch (v.codec, v.profile) {
        case (.h264, .baseline): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264BaselineAutoLevel
        case (.h264, .main): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
        case (.h264, .high): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case (.hevc, .main): comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case (.hevc, .main10): comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        default: break
        }
        var out: [String: Any] = [
            AVVideoCodecKey: v.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: v.width,
            AVVideoHeightKey: v.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: comp,
        ]
        if !v.hardwareEncoding {
            out[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        }
        return out
    }

    /// Attach Rec.709 colour tags to a pixel buffer so the encoder does not guess.
    public static func tagRec709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// `progress` receives 0...1 (monotonic, ends at 1.0). Cancelling the calling task removes the partial file
    /// and throws `CancellationError`.
    public static func export(
        video: any FrameSource,
        audio: (any AudioSource)?,
        settings: ExportSettings,
        to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let issues = settings.validate()
        guard issues.isEmpty else { throw ExportError.invalidSettings(issues) }
        guard video.frameCount > 0 else { throw ExportError.emptySource }
        var audio = audio
        if settings.audio.enabled, let l = settings.audio.loudness, let a = audio {
            guard let r = a as? any RewindableAudioSource else { throw ExportError.loudnessNeedsRewindableSource }
            audio = try await NormalizedAudioSource.make(r, settings: l)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(settings))
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.video.width,
            kCVPixelBufferHeightKey as String: settings.video.height,
        ])
        guard writer.canAdd(vInput) else { throw ExportError.cannotAddVideoInput }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if settings.audio.enabled, audio != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings(settings.audio))
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw ExportError.cannotAddAudioInput }
            writer.add(i)
            aInput = i
        }

        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        func abort(_ error: Error) -> Error {
            writer.cancelWriting()
            try? fm.removeItem(at: url)
            return error
        }

        let fd = settings.video.frameDuration
        let total = video.frameCount
        let fps = CMTimeScale(clamping: fd.timescale)
        var audioDone = aInput == nil
        var audioFramesWritten = 0
        let aRate = audio?.sampleRate ?? 48_000

        do {
            for i in 0..<total {
                try Task.checkCancellation()
                let pb = try await video.frame(at: i)
                tagRec709(pb)
                while !vInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                    // The writer may hold video back until audio is far enough ahead: feed audio as far as it accepts.
                    if let aInput, let audio, !audioDone {
                        audioFramesWritten = try await feedAudio(audio, aInput, writer, written: audioFramesWritten,
                                                                 upTo: Int.max, blocking: false, done: &audioDone)
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let pts = CMTime(value: CMTimeValue(fd.value) * CMTimeValue(i), timescale: fps)
                guard adaptor.append(pb, withPresentationTime: pts) else {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append video")
                }
                // Interleave audio up to the current video time.
                if let aInput, let audio, !audioDone {
                    let target = Int((Int128(i + 1) * Int128(fd.value) * Int128(aRate)) / Int128(fd.timescale))
                    audioFramesWritten = try await feedAudio(audio, aInput, writer, written: audioFramesWritten,
                                                             upTo: target, blocking: false, done: &audioDone)
                }
                progress(Double(i + 1) / Double(total) * (aInput == nil ? 1 : 0.99))
            }
            // Video is complete: finish it first so the writer stops waiting on video while audio drains.
            vInput.markAsFinished()
            if let aInput, let audio, !audioDone {
                audioFramesWritten = try await feedAudio(audio, aInput, writer, written: audioFramesWritten, upTo: Int.max, blocking: true, done: &audioDone)
            }
            try Task.checkCancellation()
        } catch {
            throw abort(error is CancellationError ? CancellationError() : error)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            let e = ExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
            try? fm.removeItem(at: url)
            throw e
        }
        progress(1.0)
    }

    static func audioOutputSettings(_ a: AudioSettings) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: a.sampleRate,
            AVNumberOfChannelsKey: a.channels,
            AVEncoderBitRateKey: a.bitrate,
        ]
    }

    /// Pull PCM from the source and append until `written >= upTo` frames or the source ends.
    /// Non-blocking mode returns as soon as the input is not ready (the writer may be waiting for video; blocking
    /// there would deadlock the interleaving). The caller feeds the rest later.
    private static func feedAudio(
        _ source: any AudioSource, _ input: AVAssetWriterInput, _ writer: AVAssetWriter,
        written: Int, upTo: Int, blocking: Bool, done: inout Bool
    ) async throws -> Int {
        var written = written
        while written < upTo {
            try Task.checkCancellation()
            if !blocking && !input.isReadyForMoreMediaData { break }
            guard let chunk = try await source.nextChunk(maxFrames: 4096) else { done = true; input.markAsFinished(); break }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                try await Task.sleep(for: .milliseconds(2))
            }
            let sb = try makeSampleBuffer(chunk, sampleRate: source.sampleRate, startFrame: written)
            guard input.append(sb) else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append audio") }
            written += chunk.frameCount
        }
        return written
    }

    private static func makeSampleBuffer(_ chunk: AudioChunk, sampleRate: Int, startFrame: Int) throws -> CMSampleBuffer {
        let ch = UInt32(chunk.channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
            mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        var st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else { throw ExportError.writerFailed("audio format \(st)") }
        let bytes = chunk.samples.count * 4
        var block: CMBlockBuffer?
        st = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard st == kCMBlockBufferNoErr, let block else { throw ExportError.writerFailed("block \(st)") }
        st = chunk.samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard st == kCMBlockBufferNoErr else { throw ExportError.writerFailed("copy \(st)") }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate))
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: chunk.frameCount,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw ExportError.writerFailed("sample buffer \(st)") }
        return sb
    }
}
