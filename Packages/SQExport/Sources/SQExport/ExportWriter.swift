import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import VideoToolbox

/// Writes frames (and optionally audio) to an MP4/MOV with Rec.709 1-1-1 tags via AVAssetWriter.
/// H.264 / HEVC use B-frames unless `VideoSettings.allowsFrameReordering` is off; a segmentable source is encoded as
/// parallel segments (own renderer, decoders and encoder session each) that are joined without re-encoding (W9.4).
public enum ExportWriter {
    /// Non-square pixels: the stored size is written as is and the file carries the pixel aspect (pasp). Nothing for square.
    static func addPixelAspect(_ v: VideoSettings, to out: inout [String: Any]) {
        guard let a = v.pixelAspectStore, !a.isSquare else { return }
        out[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: a.num,
                                           AVVideoPixelAspectRatioVerticalSpacingKey: a.den]
    }

    /// The HDR delivery tags when they apply: HEVC video only (needs 10 bits); ProRes, H.264, pictures and audio stay SDR.
    static func hdrTags(_ s: ExportSettings) -> HDRDelivery? { s.appliedHDRDelivery }

    public static func videoOutputSettings(_ s: ExportSettings) -> [String: Any] {
        let v = s.video
        let colour: [String: Any] = hdrTags(s)?.colorProperties ?? [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        if v.codec.isProRes {
            // Intra-frame: no bitrate, profile, keyframe or reordering properties.
            let type: AVVideoCodecType = switch v.codec {
            case .prores422: .proRes422
            case .prores422LT: .proRes422LT
            case .prores422Proxy: .proRes422Proxy
            case .prores4444: .proRes4444
            default: .proRes422HQ
            }
            var pro: [String: Any] = [
                AVVideoCodecKey: type,
                AVVideoWidthKey: v.width,
                AVVideoHeightKey: v.height,
                AVVideoColorPropertiesKey: colour,
            ]
            addPixelAspect(v, to: &pro)
            return pro
        }
        var comp: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: v.keyframeInterval,
            AVVideoExpectedSourceFrameRateKey: Int((Double(v.frameDuration.timescale) / Double(v.frameDuration.value)).rounded()),
            // B-frames: Baseline has none.
            AVVideoAllowFrameReorderingKey: v.allowsFrameReordering && v.profile != .baseline,
        ]
        if let q = v.constantQuality {
            // Constant quality: the size follows the picture, no bitrate target and no data rate limit.
            comp[AVVideoQualityKey] = q
        } else {
            comp[AVVideoAverageBitRateKey] = v.bitrate.averageBitsPerSecond
            if let m = v.bitrate.maxBitsPerSecond {
                comp[kVTCompressionPropertyKey_DataRateLimits as String] = [m / 8, 1]
            }
        }
        switch (v.codec, v.profile) {
        case (.h264, .baseline): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264BaselineAutoLevel
        case (.h264, .main): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
        case (.h264, .high): comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case (.hevc, .main): comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case (.hevc, .main10): comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        default: break
        }
        if let hdr = hdrTags(s) {
            comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            comp.merge(hdr.metadataProperties) { $1 }
        }
        var out: [String: Any] = [
            AVVideoCodecKey: v.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: v.width,
            AVVideoHeightKey: v.height,
            AVVideoColorPropertiesKey: colour,
            AVVideoCompressionPropertiesKey: comp,
        ]
        addPixelAspect(v, to: &out)
        if !v.hardwareEncoding {
            out[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        }
        return out
    }

    /// Attach Rec.709 color tags to a pixel buffer so the encoder does not guess.
    public static func tagRec709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        // The YUV output passes site chroma "Left" (co-sited with even luma columns; ExportShaderSource.chromaRGB).
        if CVPixelBufferGetPlaneCount(pb) > 1 {
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
        }
    }

    /// Time a frame loop spent waiting for the next rendered picture (frames from `skip` on, so the cold open of the first
    /// clip does not count). Near zero: the encoder is the limit; large: rendering or decoding is.
    final class WaitMeter: @unchecked Sendable {
        static let skip = 10
        private let lock = NSLock()
        private var waited = Duration.zero
        private var began: ContinuousClock.Instant?
        private var ended: ContinuousClock.Instant?
        func frame(_ i: Int, waited w: Duration) {
            guard i >= Self.skip else { return }
            lock.lock(); defer { lock.unlock() }
            if began == nil { began = .now - w }
            waited += w; ended = .now
        }
        /// Share of the measured loop time spent waiting, nil when too few frames were seen.
        var waitShare: Double? {
            lock.lock(); defer { lock.unlock() }
            guard let b = began, let e = ended, e > b else { return nil }
            func sec(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
            return sec(waited) / sec(e - b)
        }
    }

    /// Frames of the first segment that tell, in automatic mode, whether the export is render- or encoder-bound.
    static let probeFrames = 60
    /// Wait share above which the frame loop counts as render-bound (two parallel segments pay off). Measured shares: plain
    /// 1080p/4K decode and render 0.02-0.03, a color effect with a caption from 4K 0.19-0.30 (both encoder-bound).
    static let renderBoundShare = 0.4

    /// Segments the rest of an automatic export runs as after the head probe: `planned` when the head's wait share says
    /// render-bound, else one. A probe without a reading (too few frames) counts as render-bound.
    public static func restSegments(waitShare: Double?, planned: Int) -> Int {
        (waitShare ?? 1) > renderBoundShare ? max(1, planned) : 1
    }

    /// Bench hook: called once per automatic export with the head's measured wait share and the chosen rest count.
    nonisolated(unsafe) public static var probeObserver: (@Sendable (Double?, Int) -> Void)?

    /// Shortest segment worth a separate encoder session (each starts with a keyframe).
    static let minimumSegmentFrames = 15

    /// Segments an export runs with. `requested` nil = automatic: two for sources of at least 10 s (Apple silicon
    /// Max/Ultra chips have two media encode engines; on others the second segment still overlaps decode, compositing
    /// and encoding), else one. Plain (non-segmentable) sources always export in one piece; every segment gets at
    /// least `minimumSegmentFrames` and one keyframe interval. Multi-pass is one piece (one analysis for the whole file). Constant bitrate is one piece: every segment would
    /// be its own encoder session with its own rate buffer.
    public static func segmentCount(requested: Int?, source: any FrameSource, settings: ExportSettings) -> Int {
        guard !settings.video.usesConstantBitrate, !settings.usesMultiPass else { return 1 }
        guard let s = source as? any SegmentableFrameSource, s.isSegmentable else { return 1 }
        let fd = settings.video.frameDuration
        let tenSeconds = fd.value > 0 ? Int((Int128(10) * Int128(fd.timescale)) / Int128(fd.value)) : .max
        let wanted = requested ?? (source.frameCount >= tenSeconds ? 2 : 1)
        let minFrames = max(minimumSegmentFrames, settings.video.codec.isMastering ? 0 : settings.video.keyframeInterval)
        return max(1, min(wanted, source.frameCount / minFrames))
    }

    /// `progress` receives 0...1 (monotonic, ends at 1.0). Canceling the calling task removes the partial file
    /// and throws `CancellationError`. `segments`: nil = automatic (`segmentCount`).
    @discardableResult
    public static func export(
        video: any FrameSource,
        audio: (any AudioSource)?,
        settings: ExportSettings,
        to url: URL,
        segments: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoudnessReport? {
        let issues = settings.validate()
        guard issues.isEmpty else { throw ExportError.invalidSettings(issues) }
        guard video.frameCount > 0 else { throw ExportError.emptySource }
        let audioSource = settings.audio.enabled ? audio : nil
        if settings.audio.loudness != nil, let a = audioSource, !(a is any RewindableAudioSource) {
            throw ExportError.loudnessNeedsRewindableSource
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        if let output = settings.frameOutput {
            do {
                try await FrameOutputWriter.write(video: video, output: output, settings: settings, to: url, progress: progress)
            } catch {
                try? fm.removeItem(at: url)
                throw error
            }
            progress(1.0)
            return nil
        }
        if let format = settings.audioOnly {
            guard let a = audioSource else { throw ExportError.noAudio }
            let r = try await exportAudioOnly(a, format: format, duration: settings.video.frameDuration * Int64(video.frameCount),
                                              settings: settings.effectiveAudio, to: url, progress: progress)
            progress(1.0)
            return r
        }
        var n = segmentCount(requested: segments, source: video, settings: settings)
        // Segments are written next to the output first (same volume, about the size of the whole video again).
        if n > 1, !hasRoomForSegments(at: url.deletingLastPathComponent(), settings: settings, frames: video.frameCount) { n = 1 }
        let report: LoudnessReport?
        if n > 1, let seg = video as? any SegmentableFrameSource {
            // Loudness measuring and the audio mix run alongside the video segments (see `exportSegmented`).
            report = try await exportSegmented(seg, count: n, adaptive: segments == nil, audio: audioSource, settings: settings, to: url, progress: progress)
        } else {
            // Frame 0 (cold open and seek of the first clip, ~150-500 ms) renders while the loudness pass and the writer start.
            let first = firstFrame(video)
            let (normalized, r): ((any AudioSource)?, LoudnessReport?)
            do { (normalized, r) = try await normalizedAudio(audioSource, settings: settings.audio) } catch { first.cancel(); throw error }
            report = r
            try await encode(video: video, audio: normalized, settings: settings, to: url, first: first,
                             progress: { progress($0 * (normalized == nil ? 1 : 0.99)) })
        }
        // The encoder is lossy: read the loudness and true peak back from the file.
        var verified = report
        if verified != nil { verified?.verified = try? await OutputAudioVerifier.measure(url: url) }
        progress(1.0)
        return verified
    }

    /// Audio-only file (M4A / WAV): the mix, normalized when asked, written without a picture. AAC can end a little above
    /// the true-peak ceiling: the file is measured and, on an overshoot, written once more with the ceiling lowered by it.
    private static func exportAudioOnly(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                        to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        var s = settings
        var attempt = 0
        while true {
            let (source, report) = try await normalizedAudio(audio, settings: s)
            guard let source else { throw ExportError.noAudio }
            try await writeAudioFile(source, format: format, duration: duration, settings: s, to: url) {
                progress($0 * (report == nil ? 1 : 0.95))
            }
            guard var r = report else { return nil }
            r.verified = try? await OutputAudioVerifier.measure(url: url)
            if let over = r.overshootDB, format.codec == .aac, attempt == 0, var l = s.loudness {
                attempt += 1
                l.truePeakCeilingDB -= over + 0.1
                s.loudness = l
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Reported against the ceiling the user asked for, not the lowered one.
            r.ceilingDB = settings.loudness?.truePeakCeilingDB ?? r.ceilingDB
            return r
        }
    }

    /// Writes one audio file (a stem, a language track) from `audio`: M4A, WAV or FLAC, normalized when the settings ask.
    @discardableResult
    public static func exportAudioFile(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        var s = settings
        s.codec = format.codec
        return try await exportAudioOnly(audio, format: format, duration: duration, settings: s, to: url, progress: progress)
    }

    private static func writeAudioFile(_ source: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                       to url: URL, progress: @Sendable (Double) -> Void) async throws {
        if format == .flac {
            try await FLACWriter.write(source, duration: duration, bitDepth: settings.pcmBitDepth, to: url, progress: progress)
            return
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: format == .m4a ? .m4a : .wav)
        let feeder = try AudioFeeder(source: source, settings: settings, writer: writer)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        do {
            // One second at a time, so progress moves and cancel is noticed.
            let seconds = max(1, Int((Double(duration.value) / Double(max(duration.timescale, 1))).rounded(.up)))
            for k in 1..<max(seconds, 2) {
                try Task.checkCancellation()
                try await feeder.feed(upTo: Time(Int64(k), 1), blocking: true)
                progress(Double(k) / Double(seconds))
            }
            try await feeder.feedAll()
            try Task.checkCancellation()
        } catch {
            writer.cancelWriting()
            throw error
        }
        try await finish(writer, url)
    }

    /// Loudness normalization (measure pass over the whole mix, then a gain) when the settings ask for it.
    static func normalizedAudio(_ audio: (any AudioSource)?, settings: AudioSettings) async throws
        -> ((any AudioSource)?, LoudnessReport?) {
        guard let l = settings.loudness, let a = audio else { return (audio, nil) }
        guard let r = a as? any RewindableAudioSource else { throw ExportError.loudnessNeedsRewindableSource }
        let n = try await NormalizedAudioSource.make(r, settings: l)
        return (n, LoudnessReport(normalized: n, settings: l))
    }

    static func fileType(_ url: URL, _ settings: ExportSettings) -> AVFileType {
        (url.pathExtension.lowercased() == "mov" || settings.video.codec.isMastering) ? .mov : .mp4
    }

    // MARK: one encoder session

    /// Encodes `video` (+ `audio`) into `url`. `progress` gets frames written / total. The next frame renders while the
    /// current one is appended and encoded (one frame ahead, so a source never sees overlapping requests). The audio is
    /// mixed and appended by its own task (`AudioFeed`); the writer interleaves the two inputs.
    static func encode(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                               first: Task<Box<CVPixelBuffer>, Error>? = nil, meter: WaitMeter? = nil,
                               progress: @Sendable (Double) -> Void) async throws {
        // `first`: frame 0 already asked for by the single-segment caller (it renders while the writer starts). Segments
        // ask for it only after their writer started: parallel segments that render during writer setup starve the
        // cooperative pool (blocking AVFoundation calls) and the export hangs.
        do { try verifyHardwareForWriter(settings) } catch { first?.cancel(); throw error }
        if usesSpeedEncoder(settings) {
            return try await encodeWithSession(video: video, audio: audio, settings: settings, to: url, first: first,
                                               meter: meter, progress: progress)
        }
        let fm = FileManager.default
        let writer: AVAssetWriter, vInput: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioFeed: AudioFeed?
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType(url, settings))
            writer.metadata = settings.metadata?.items ?? []
            vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(settings))
            vInput.expectsMediaDataInRealTime = false
            // No pool attributes: buffers come from the source in its own format (BGRA, 420v, x420, x422 or y416).
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: nil)
            guard writer.canAdd(vInput) else { throw ExportError.cannotAddVideoInput }
            writer.add(vInput)
            let feeder = try audio.map { try AudioFeeder(source: $0, settings: settings.audio, writer: writer) }

            guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
            writer.startSession(atSourceTime: .zero)
            audioFeed = feeder.map { AudioFeed($0, inFrameLoop: audioFeedsInFrameLoop) }
        } catch {
            first?.cancel()
            throw error
        }

        let fd = settings.video.frameDuration
        let total = video.frameCount
        let fps = CMTimeScale(clamping: fd.timescale)
        var pending: Task<Box<CVPixelBuffer>, Error>? = first ?? firstFrame(video)
        do {
            for i in 0..<total {
                try Task.checkCancellation()
                let current = pending!
                let t0 = ContinuousClock.now
                let pb = try await withTaskCancellationHandler { try await current.value.buffer } onCancel: { current.cancel() }
                meter?.frame(i, waited: ContinuousClock.now - t0)
                pending = i + 1 < total ? Task { [video] in Box(try await video.frame(at: i + 1)) } : nil
                tagRec709(pb)
                try await waitUntilReady(vInput, writer, audioFeed?.inLoop, audioFeed)
                let pts = CMTime(value: CMTimeValue(fd.value) * CMTimeValue(i), timescale: fps)
                guard adaptor.append(pb, withPresentationTime: pts) else {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append video")
                }
                try await audioFeed?.inLoop?.feed(upTo: Time(fd.value * Int64(i + 1), fd.timescale), blocking: false)
                progress(Double(i + 1) / Double(total))
            }
            // Video is complete: finish it first so the writer stops waiting on video while audio drains.
            vInput.markAsFinished()
            try await audioFeed?.finish()
            try Task.checkCancellation()
        } catch {
            pending?.cancel()
            await audioFeed?.cancel()
            writer.cancelWriting()
            try? fm.removeItem(at: url)
            throw error is CancellationError ? CancellationError() : error
        }
        try await finish(writer, url)
    }

    /// Encoder speed Balanced / Fast: frames go through `SpeedEncoderSession`, its compressed samples into a pass-through
    /// input. The input (and the audio input) are added once the first sample gives the format, since a pass-through
    /// input into MP4 needs a format hint and inputs must exist before `startWriting`.
    private static func encodeWithSession(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                                          first: Task<Box<CVPixelBuffer>, Error>?, meter: WaitMeter?,
                                          progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let writer: AVAssetWriter, encoder: SpeedEncoderSession
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType(url, settings))
            writer.metadata = settings.metadata?.items ?? []
            encoder = try SpeedEncoderSession(settings: settings)
        } catch {
            first?.cancel()
            throw error
        }
        var vInput: AVAssetWriterInput?
        var audioFeed: AudioFeed?
        let fd = settings.video.frameDuration
        let total = video.frameCount
        let fps = CMTimeScale(clamping: fd.timescale)
        let frameTime = CMTime(value: CMTimeValue(fd.value), timescale: fps)

        var appended = 0
        func drain() async throws {
            for sb in try encoder.take() {
                appended += CMSampleBufferGetNumSamples(sb)
                if vInput == nil {
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                                   sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
                    input.expectsMediaDataInRealTime = false
                    guard writer.canAdd(input) else { throw ExportError.cannotAddVideoInput }
                    writer.add(input)
                    let feeder = try audio.map { try AudioFeeder(source: $0, settings: settings.audio, writer: writer) }
                    guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
                    writer.startSession(atSourceTime: .zero)
                    vInput = input
                    audioFeed = feeder.map { AudioFeed($0, inFrameLoop: audioFeedsInFrameLoop) }
                }
                let input = vInput!
                try await waitUntilReady(input, writer, audioFeed?.inLoop, audioFeed)
                guard input.append(sb) else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append video") }
            }
        }

        var pending: Task<Box<CVPixelBuffer>, Error>?
        do {
            // One pass, or with multi-pass two: an analysis pass whose samples are thrown away (the software encoder emits a
            // full stream in every pass, measured 2026-10-17) and the final pass, declared final by us (BeginFinalPass) so
            // nothing has to be held back. The time ranges the encoder suggests for a further pass are not used: the
            // final pass always carries every frame.
            let multi = encoder.multiPass
            let passes = multi ? 2 : 1
            for pass in 0..<passes {
                let final = pass == passes - 1
                try Task.checkCancellation()
                if multi {
                    if pass > 0 { _ = try encoder.nextPassRanges() }   // the encoder expects the question before the next pass
                    try encoder.beginPass(final: final)
                }
                pending = pass == 0 ? (first ?? firstFrame(video)) : firstFrame(video)
                for i in 0..<total {
                    try Task.checkCancellation()
                    let current = pending!
                    let t0 = ContinuousClock.now
                    let pb = try await withTaskCancellationHandler { try await current.value.buffer } onCancel: { current.cancel() }
                    if pass == 0 { meter?.frame(i, waited: ContinuousClock.now - t0) }
                    pending = i + 1 < total ? Task { [video] in Box(try await video.frame(at: i + 1)) } : nil
                    tagRec709(pb)
                    let pts = CMTime(value: CMTimeValue(fd.value) * CMTimeValue(i), timescale: fps)
                    try encoder.encode(pb, pts: pts, duration: frameTime)
                    if final {
                        try await drain()
                        try await audioFeed?.inLoop?.feed(upTo: Time(fd.value * Int64(i + 1), fd.timescale), blocking: false)
                    } else {
                        _ = try encoder.take()   // analysis pass: drop the samples, still surface encoder errors
                    }
                    progress(Double(pass * total + i + 1) / Double(passes * total))
                }
                if multi {
                    try encoder.complete()   // every frame of the pass is through the encoder before the pass ends
                    let more = try encoder.endPass()
                    NSLog("[export] multi-pass: pass %d of %d done (%d frames), encoder wants a further pass: %@", pass + 1, passes, total, more ? "yes" : "no")
                }
                // The analysis pass' late samples must be gone before the final pass starts.
                try encoder.complete()
                if !final { _ = try encoder.take() }
            }
            try await drain()
            guard let input = vInput else { throw ExportError.writerFailed("encoder produced no frames") }
            // Drop safety does not rest on an encoder default: every frame sent must come back as one sample.
            guard appended == total else { throw ExportError.writerFailed("the encoder returned \(appended) of \(total) frames") }
            input.markAsFinished()
            try await audioFeed?.finish()
            try Task.checkCancellation()
        } catch {
            pending?.cancel()
            await audioFeed?.cancel()
            if writer.status == .writing { writer.cancelWriting() }
            try? fm.removeItem(at: url)
            throw error is CancellationError ? CancellationError() : error
        }
        try await finish(writer, url)
    }

    /// Starts rendering frame 0 of `video` (the first request a source sees: requests never overlap).
    private static func firstFrame(_ video: any FrameSource) -> Task<Box<CVPixelBuffer>, Error> {
        Task { [video] in Box(try await video.frame(at: 0)) }
    }

    private static func finish(_ writer: AVAssetWriter, _ url: URL) async throws {
        await writer.finishWriting()
        guard writer.status == .completed else {
            let e = ExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
            try? FileManager.default.removeItem(at: url)
            throw e
        }
    }

    /// Waits for the video input. The writer may hold video back until audio is far enough ahead, so the audio must move
    /// meanwhile: `feeder` (audio fed by the caller's own loop) is fed here; `audio` (fed by its own task) is only asked
    /// whether it failed, since video would wait forever for audio that stopped.
    private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ feeder: (any AudioInterleaving)?,
                                       _ audio: AudioFeed? = nil) async throws {
        try audio?.check()
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try audio?.check()
            if writer.status == .failed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "failed") }
            try await feeder?.feed(upTo: nil, blocking: false)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: parallel segments

    /// Rough size of the encoded video in bytes: the bitrate for H.264 / HEVC, Apple's ProRes data rates per pixel
    /// (422 ~2.4, 422 HQ ~3.5, 4444 ~5.3 bit per pixel and frame) for the mastering codecs.
    static func estimatedVideoBytes(settings: ExportSettings, frames: Int) -> Int64 {
        let v = settings.video
        let seconds = Double(frames) * Double(v.frameDuration.value) / Double(max(1, v.frameDuration.timescale))
        let bitsPerPixel: Double
        switch v.codec {
        case .h264, .hevc: return Int64(Double(v.bitrate.averageBitsPerSecond) * seconds / 8)
        case .prores422: bitsPerPixel = 2.4
        case .prores422LT: bitsPerPixel = 1.65
        case .prores422Proxy: bitsPerPixel = 0.75
        case .prores422HQ: bitsPerPixel = 3.5
        case .prores4444: bitsPerPixel = 5.3
        }
        return Int64(bitsPerPixel * Double(v.width * v.height) * Double(frames) / 8)
    }

    /// The segment files plus the joined copy must fit on the output volume (with 10 % and 1 GB to spare).
    static func hasRoomForSegments(at folder: URL, settings: ExportSettings, frames: Int) -> Bool {
        guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage else { return true }
        let need = Double(estimatedVideoBytes(settings: settings, frames: frames)) * 2.2 + 1_000_000_000
        return Double(free) >= need
    }

    /// Encodes `count` segments in parallel into a temporary folder (video only) while a further task measures loudness (if
    /// asked), mixes and encodes the audio into its own file; then joins both into `url` without re-encoding (video timing
    /// shifted by each segment's start, audio copied as encoded). Before 2026-10-04 the audio was mixed and encoded during
    /// the join and the loudness pass ran before the first frame, both on the critical path.
    /// Progress: segments 0...0.9 (frames done over all segments), join 0.9...0.99.
    private static func exportSegmented(_ video: any SegmentableFrameSource, count: Int, adaptive: Bool, audio: (any AudioSource)?,
                                        settings: ExportSettings, to url: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        let fm = FileManager.default
        // Hidden folder next to the output: same volume as the result (not the boot volume's temp), removed on success,
        // error and cancel.
        let dir = url.deletingLastPathComponent().appendingPathComponent(".sq-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let total = video.frameCount
        func split(_ r: Range<Int>, _ n: Int) -> [Range<Int>] {
            (0..<n).map { (r.lowerBound + r.count * $0 / n)..<(r.lowerBound + r.count * ($0 + 1) / n) }
        }
        // Automatic mode starts with a short head segment alone and measures its frame loop: when it hardly waits for
        // pictures the hardware encoder is the limit and one more session for the rest is faster than two (measured
        // 2026-10-12: one session +19 to +42 % on encoder-bound exports); when it waits, rendering is the limit and the
        // rest runs as `count` parallel segments.
        let minFrames = max(minimumSegmentFrames, settings.video.codec.isMastering ? 0 : settings.video.keyframeInterval)
        let head = adaptive && total >= probeFrames + count * minFrames ? probeFrames : nil
        var ranges = head.map { [0..<$0] } ?? split(0..<total, count)
        let segSettings = { var s = settings; s.audio.enabled = false; return s }()
        let files = (0..<(count + 1)).map { dir.appendingPathComponent("segment-\($0).mov") }
        let meter = WaitMeter()
        let counter = ProgressCounter(total: total, scale: 0.9, report: progress)
        let audioFile = audio.map { _ in dir.appendingPathComponent("audio.mov") }
        do {
            let report = try await withThrowingTaskGroup(of: (LoudnessReport?, Bool).self) { group in
                if let audio, let audioFile {
                    group.addTask {
                        let (normalized, report) = try await normalizedAudio(audio, settings: settings.audio)
                        try await encodeAudio(normalized ?? audio, settings: settings.audio, to: audioFile)
                        return (report, false)
                    }
                }
                func add(_ k: Int, _ r: Range<Int>, isHead: Bool) throws {
                    let source = try video.segment(r)
                    let file = files[k]
                    let len = r.count
                    group.addTask {
                        let last = ProgressCounter.Last()
                        try await encode(video: source, audio: nil, settings: segSettings, to: file, meter: isHead ? meter : nil) { p in
                            counter.advance(last.delta(Int((p * Double(len)).rounded())))
                        }
                        return (nil, isHead)
                    }
                }
                for (k, r) in ranges.enumerated() { try add(k, r, isHead: head != nil) }
                var report: LoudnessReport?
                for try await (r, wasHead) in group {
                    if let r { report = r }
                    if wasHead, let head {
                        let share = meter.waitShare
                        let restCount = restSegments(waitShare: share, planned: count)
                        probeObserver?(share, restCount)
                        let rest = split(head..<total, restCount)
                        for (j, r) in rest.enumerated() { try add(1 + j, r, isHead: false) }
                        ranges += rest
                    }
                }
                return report
            }
            let starts = ranges.map { settings.video.frameDuration * Int64($0.lowerBound) }
            try await join(zip(files, starts).map { JoinPiece(url: $0, start: $1) }, audioFile: audioFile,
                           settings: settings, to: url) { progress(0.9 + 0.09 * $0) }
            return report
        } catch {
            try? fm.removeItem(at: url)
            throw error is CancellationError ? CancellationError() : error
        }
    }

    /// Mixes and encodes `audio` alone into `url` (a MOV: holds AAC and PCM), for the segment join to copy.
    static func encodeAudio(_ audio: any AudioSource, settings: AudioSettings, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let feeder = try AudioFeeder(source: audio, settings: settings, writer: writer)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        do {
            try await feeder.feedAll()
            try Task.checkCancellation()
        } catch {
            writer.cancelWriting()
            throw error
        }
        try await finish(writer, url)
    }

    /// Joins encoded segments into one file: compressed samples are copied (passthrough) with presentation and decode
    /// times shifted by the segment's start; the encoded audio file is copied alongside, interleaved by time.
    /// A piece of the joined file: a whole encoded segment, or (`copy`) the frames of a source file copied as they are.
    struct JoinPiece {
        var url: URL
        var start: Time
        var copy: CopyRange?
    }

    /// `frames` source frames from the sync sample at `from` (source media time), one per `frameDuration`.
    struct CopyRange: Equatable {
        var from: Time
        var frames: Int
        var frameDuration: Time
        var end: Time { from + frameDuration * Int64(frames) }
        /// Asset time range to read: from 2 s before the run (the reader backs up to a sync sample, and asset time lags
        /// media time by the composition delay) to one frame after it, so the sample that ends the run is seen.
        var readRange: CMTimeRange {
            let lead = Time(2, 1)
            let start = from - lead
            let begin = start < .zero ? Time.zero : start
            return CMTimeRange(start: begin.cm, duration: (end + frameDuration * 2 - begin).cm)
        }
    }

    static func join(_ pieces: [JoinPiece], audioFile: URL?, settings: ExportSettings, to url: URL,
                     progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        var segments: [(AVAssetReader, AVAssetReaderTrackOutput, CMTime, CopyRange?)] = []
        var hint: CMFormatDescription?
        for piece in pieces {
            let (file, start) = (piece.url, piece.start)
            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.writerFailed("segment has no video")
            }
            if hint == nil { hint = try await track.load(.formatDescriptions).first }
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if let c = piece.copy {
                reader.timeRange = c.readRange
            }
            reader.add(out)
            segments.append((reader, out, start.cm, piece.copy))
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType(url, settings))
        writer.metadata = settings.metadata?.items ?? []
            writer.metadata = settings.metadata?.items ?? []
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(vInput) else { throw ExportError.cannotAddVideoInput }
        writer.add(vInput)
        let feeder: AudioCopier?
        if let audioFile { feeder = try await AudioCopier(file: audioFile, writer: writer) } else { feeder = nil }
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        var lastDTS = CMTime.invalid
        do {
            try feeder?.start()
            for (k, (reader, out, start, copy)) in segments.enumerated() {
                var copied = 0
                guard reader.startReading() else { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read segment") }
                // Passthrough samples carry media times: with B-frames the first frame is presented at the composition
                // delay, not at 0 (the segment's edit list hides that). The first sample in decode order is the
                // segment's opening keyframe, which is also its first frame shown: it lands exactly on `start`.
                var offset: CMTime?
                while let sb = out.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
                    if let copy {
                        // The reader starts a little before the run (and delivers a marker sample first): skip to its sync sample.
                        let p = CMSampleBufferGetPresentationTimeStamp(sb)
                        if offset == nil, !(isSyncSample(sb) && CMTimeCompare(p, copy.from.cm) == 0) { continue }
                        if CMTimeCompare(p, copy.end.cm) >= 0 { break }
                        copied += CMSampleBufferGetNumSamples(sb)
                    }
                    if offset == nil { offset = CMTimeSubtract(start, CMSampleBufferGetPresentationTimeStamp(sb)) }
                    let shifted = try retimed(sb, by: offset!, after: &lastDTS)
                    try await waitUntilReady(vInput, writer, feeder)
                    guard vInput.append(shifted) else {
                        throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append segment sample")
                    }
                    let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(shifted), CMSampleBufferGetDuration(shifted))
                    try await feeder?.feed(upTo: end.isNumeric ? Time(end.value, Int64(end.timescale)) : nil, blocking: false)
                }
                if let copy {
                    reader.cancelReading()
                    guard copied == copy.frames else { throw ExportError.writerFailed("smart render: copied \(copied) of \(copy.frames) frames") }
                } else if reader.status == .failed { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read segment") }
                progress(Double(k + 1) / Double(segments.count))
            }
            vInput.markAsFinished()
            try await feeder?.feedAll()
            try Task.checkCancellation()
        } catch {
            for s in segments { s.0.cancelReading() }
            feeder?.cancel()
            writer.cancelWriting()
            try? fm.removeItem(at: url)
            throw error
        }
        try await finish(writer, url)
    }

    private static func retimed(_ sb: CMSampleBuffer, by offset: CMTime, after lastDTS: inout CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset) }
        }
        try clampDecodeTimes(&timing, after: &lastDTS)
        var out: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                                       sampleTimingArray: &timing, sampleBufferOut: &out)
        guard st == noErr, let out else { throw ExportError.writerFailed("retime \(st)") }
        return out
    }

    /// Keeps decode times strictly increasing across a seam. Each segment's decode times start its reorder delay before
    /// its first frame; a segment with a longer delay than the one before would decode before that segment's last
    /// sample. Such samples move to just after the previous decode time (one tick of a 1/90000 s grid, as in MPEG
    /// timing); a sample that would then decode after it is shown cannot be re-timed and fails the export.
    static func clampDecodeTimes(_ timing: inout [CMSampleTimingInfo], after lastDTS: inout CMTime) throws {
        for i in timing.indices {
            var dts = timing[i].decodeTimeStamp
            guard dts.isValid else { lastDTS = timing[i].presentationTimeStamp; continue }
            if lastDTS.isValid, CMTimeCompare(dts, lastDTS) <= 0 {
                dts = CMTimeAdd(lastDTS, CMTime(value: 1, timescale: 90_000))
                guard CMTimeCompare(dts, timing[i].presentationTimeStamp) <= 0 else {
                    throw ExportError.writerFailed("segment seam: decode time after presentation time")
                }
                timing[i].decodeTimeStamp = dts
            }
            lastDTS = dts
        }
    }

    // MARK: audio

    static func audioOutputSettings(_ a: AudioSettings, sourceChannels: Int? = nil) -> [String: Any] {
        var a = a
        if sourceChannels == 1 { a.channels = 1 }   // Mono sequence: one channel in the file (AAC and PCM both allow it)
        if a.codec == .pcm {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: a.sampleRate,
                AVNumberOfChannelsKey: a.channels,
                AVLinearPCMBitDepthKey: a.pcmBitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: a.sampleRate,
            AVNumberOfChannelsKey: a.channels,
            AVEncoderBitRateKey: a.bitrate,
        ]
    }

    /// Feeds a writer's audio input up to a time, so audio and video interleave.
    private protocol AudioInterleaving: AnyObject {
        func feed(upTo time: Time?, blocking: Bool) async throws
    }

    /// Copies the encoded samples of an audio file (`encodeAudio`) into a writer's pass-through audio input. The copied
    /// AAC packets keep their priming/trim attachments, so the written edit list is the one the audio file had.
    /// Used by one task only.
    private final class AudioCopier: AudioInterleaving {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
        var next: CMSampleBuffer?
        var done = false

        init(file: URL, writer: AVAssetWriter) async throws {
            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ExportError.writerFailed("audio file has no track")
            }
            let hint = try await track.load(.formatDescriptions).first
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw ExportError.cannotAddAudioInput }
            writer.add(i)
            input = i; self.writer = writer
        }

        func start() throws {
            guard reader.startReading() else { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read audio") }
        }

        func cancel() { reader.cancelReading() }

        /// Appends samples that start before `time` (nil = all); non-blocking returns once the input is not ready.
        func feed(upTo time: Time?, blocking: Bool) async throws {
            let limit = time.map { CMTime(value: $0.value, timescale: CMTimeScale(truncatingIfNeeded: $0.timescale)) }
            while !done {
                try Task.checkCancellation()
                if next == nil {
                    while let sb = output.copyNextSampleBuffer() {
                        if CMSampleBufferGetNumSamples(sb) > 0 { next = sb; break }
                    }
                    if next == nil {
                        if reader.status == .failed { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read audio") }
                        done = true; input.markAsFinished(); return
                    }
                }
                if let limit, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(next!), limit) >= 0 { return }
                while !input.isReadyForMoreMediaData {
                    if !blocking { return }
                    try Task.checkCancellation()
                    if writer.status == .failed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard input.append(next!) else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append audio") }
                next = nil
            }
        }

        func feedAll() async throws { try await feed(upTo: nil, blocking: true) }
    }

    /// `SQ_EXPORT_AUDIO_IN_LOOP=1`: the frame loop mixes and appends the audio itself, as before 2026-10-09 (A/B bench only).
    private static let audioFeedsInFrameLoop = ProcessInfo.processInfo.environment["SQ_EXPORT_AUDIO_IN_LOOP"] == "1"

    /// The audio of a one-session export, mixed and appended by its own task next to the frame loop (each writer input is
    /// fed by one task, the writer interleaves). Inside the frame loop a mixed chunk cost ~4 ms and the writer took many in
    /// a row, which held the next frame back: 30 s of a six-track timeline 7.85 s, 7.15 s since (as fast as without audio).
    private final class AudioFeed: @unchecked Sendable {
        /// Only with `SQ_EXPORT_AUDIO_IN_LOOP`: the feeder the frame loop drives itself (no task then).
        let inLoop: AudioFeeder?
        private let task: Task<Void, any Error>?
        private let failed = Failed()

        private final class Failed: @unchecked Sendable {
            private let lock = NSLock()
            private var error: (any Error)?
            func set(_ e: any Error) { lock.withLock { error = e } }
            func get() -> (any Error)? { lock.withLock { error } }
        }

        init(_ feeder: AudioFeeder, inFrameLoop: Bool) {
            guard !inFrameLoop else { inLoop = feeder; task = nil; return }
            inLoop = nil
            nonisolated(unsafe) let feeder = feeder
            task = Task { [failed] in
                do { try await feeder.feedAll() } catch {
                    failed.set(error)
                    throw error
                }
            }
        }

        /// Throws what stopped the audio task, so the frame loop ends with it (asked once per frame).
        func check() throws { if let e = failed.get() { throw e } }

        /// The rest of the audio, after the video input is finished.
        func finish() async throws {
            guard let task else { return try await inLoop?.feedAll() ?? () }
            // A cancel of the export stops the drain with the next chunk (the task is not a child of the caller).
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }

        /// Stops the task and waits for it: nothing appends once the writer is canceled.
        func cancel() async {
            task?.cancel()
            _ = await task?.result
        }
    }

    /// The audio input of one writer and how far it has been fed. Used by one task only.
    private final class AudioFeeder: AudioInterleaving {
        let source: any AudioSource
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
        var written = 0
        var done = false

        init(source: any AudioSource, settings: AudioSettings, writer: AVAssetWriter) throws {
            // A one-channel source (Mono sequence) writes one channel; the codecs of every container here allow it.
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings(settings, sourceChannels: source.channels))
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw ExportError.cannotAddAudioInput }
            writer.add(i)
            self.source = source; self.input = i; self.writer = writer
        }

        /// Non-blocking: up to `time` (nil = as far as the input accepts), returns as soon as the input is not ready.
        func feed(upTo time: Time?, blocking: Bool) async throws {
            guard !done else { return }
            let target = time.map { Int((Int128($0.value) * Int128(source.sampleRate)) / Int128($0.timescale)) } ?? Int.max
            written = try await ExportWriter.feedAudio(source, input, writer, written: written, upTo: target, blocking: blocking, done: &done)
        }

        func feedAll() async throws { try await feed(upTo: nil, blocking: true) }
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
        st = chunk.samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }   // empty chunk
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
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

extension Time {
    var cm: CMTime { CMTime(value: value, timescale: CMTimeScale(truncatingIfNeeded: timescale)) }
}

/// Frames done over all parallel segments, reported as one monotonic fraction.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let scale: Double
    private let report: @Sendable (Double) -> Void

    init(total: Int, scale: Double, report: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1); self.scale = scale; self.report = report
    }

    func advance(_ frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        done += frames
        report(Double(min(done, total)) / Double(total) * scale)
    }

    /// Turns one segment's cumulative frame count into increments.
    final class Last: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func delta(_ now: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let d = now - value
            if d > 0 { value = now }
            return max(d, 0)
        }
    }
}

/// The Mac encoder behind `ExportEncoding`: AVAssetWriter with VideoToolbox (`ExportWriter.export`).
public struct AVExportEncoder: ExportEncoding {
    public init() {}
    public func export(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        try await ExportWriter.export(video: video, audio: audio, settings: settings, to: url, progress: progress)
    }
    public func exportAudioFile(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        try await ExportWriter.exportAudioFile(audio, format: format, duration: duration, settings: settings, to: url, progress: progress)
    }
}
