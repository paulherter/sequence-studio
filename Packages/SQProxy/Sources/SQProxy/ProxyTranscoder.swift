@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMedia

/// AVAssetReader (hardware decode via VideoToolbox) -> AVAssetWriter (ProRes) transcoder.
public struct ProxyTranscoder: ProxyTranscoding {
    public init() {}

    public func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                          progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        try Task.checkCancellation()
        if WebMReadback.handles(source) {   // AVFoundation cannot open WebM / Matroska / MXF
            return try await WebMProxyTranscoder.transcode(source: source, kind: kind, destination: destination,
                                                           timeRange: timeRange, progress: progress)
        }
        let asset = AVURLAsset(url: source)
        let (videoTracks, audioTracks, fullDuration) = try await (
            asset.loadTracks(withMediaType: .video), asset.loadTracks(withMediaType: .audio), asset.load(.duration))
        guard let video = videoTracks.first else { throw ProxyTranscodeError.noVideoTrack }
        let (natural, transform, formats, timescale) = try await video.load(.naturalSize, .preferredTransform, .formatDescriptions, .naturalTimeScale)
        guard let format = formats.first else { throw ProxyTranscodeError.noVideoTrack }

        // The stored pixel grid, not `naturalSize`: that one is the picture desqueezed by a pixel aspect tag (512x288 at 2:1
        // reads 1024x288). A proxy keeps the grid so it divides the original's size by the kind's divisor (RenderLoop's
        // `proxyDivisor`), is neither upscaled nor stretched, and takes whatever pixel aspect the media item has later.
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        let srcDims = coded.width > 0 && coded.height > 0
            ? ProxyDimensions(width: Int(coded.width), height: Int(coded.height))
            : ProxyDimensions(width: Int(natural.width.rounded()), height: Int(natural.height.rounded()))
        let outDims = srcDims.scaled(divisor: kind.scaleDivisor)
        let cmRange = try Self.cmTimeRange(timeRange, fullDuration: fullDuration)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = cmRange
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video. Alpha sources (ProRes 4444, HEVC with alpha) get a ProRes 4444 proxy fed 16-bit AYCbCr, so the alpha
        // channel and its straight/premultiplied tag survive; everything else stays 10-bit 4:2:2.
        let alpha = Self.hasAlpha(format)
        // Interlaced source: every frame is deinterlaced here, at the stored size and before the writer scales it (scaling
        // woven fields blends them). The proxy file is progressive, so its frames take no pass at playback
        // (`MediaTable.deinterlace`). The pass reads planar buffers, hence the bi-planar reader format; alpha stays packed
        // 'y416', which the pass reads as well. A picture it cannot deinterlace fails the job: a woven frame never goes
        // into a file that says it is progressive.
        let fields = Deinterlacer.fieldOrder(of: format)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: alpha ? kCVPixelFormatType_4444AYpCbCr16
                : fields != nil ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10,
        ]
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: readerSettings)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ProxyTranscodeError.readerFailed("cannot add video output") }
        reader.add(vOut)
        var vSettings: [String: Any] = [
            AVVideoCodecKey: alpha ? AVVideoCodecType.proRes4444
                : kind == .optimized ? AVVideoCodecType.proRes422 : AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: outDims.width, AVVideoHeightKey: outDims.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        ]
        if let color = Self.colorProperties(from: format) { vSettings[AVVideoColorPropertiesKey] = color }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        vIn.mediaTimeScale = timescale // keeps 29.97 etc. exact; the default would round PTS to 1/600 s
        writer.add(vIn)

        // Background work: the pump queue follows the priority of the calling task.
        let qos = Self.qos(for: Task.currentPriority)
        var pumps: [Pump] = [Pump(input: vIn, output: vOut, tracksProgress: true, qos: qos, deinterlace: fields)]

        // Audio: decode to PCM, all channels kept.
        for track in await UsableAudioTracks.tracks(audioTracks) {      // same list as probe and playback
            guard let af = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            let bits = (asbd.mBitsPerChannel == 24 || asbd.mBitsPerChannel == 32) ? 24 : 16
            var pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bits,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            var layoutSize = 0
            var layoutData: Data
            if let l = CMAudioFormatDescriptionGetChannelLayout(af, sizeOut: &layoutSize), layoutSize > 0 {
                layoutData = Data(bytes: l, count: layoutSize)
            } else {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono
                    : channels == 2 ? kAudioChannelLayoutTag_Stereo
                    : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
                layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let aOut = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            pcm[AVChannelLayoutKey] = layoutData
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            aIn.expectsMediaDataInRealTime = false
            guard reader.canAdd(aOut), writer.canAdd(aIn) else { continue }
            reader.add(aOut); writer.add(aIn)
            pumps.append(Pump(input: aIn, output: aOut, tracksProgress: false, qos: qos))
        }

        guard reader.startReading() else { throw ProxyTranscodeError.readerFailed(reader.error?.localizedDescription ?? "?") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
        writer.startSession(atSourceTime: cmRange.start)

        let job = Job(reader: reader, writer: writer)
        let start = cmRange.start, total = cmRange.duration
        let report = Progress(start: start, total: total, sink: progress)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for p in pumps {
                    group.addTask { await p.run(job: job, progress: report) }
                }
            }
        } onCancel: { job.cancel() }

        if let failure = job.failure {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        if Task.isCancelled || job.cancelled {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: destination)
            throw ProxyTranscodeError.readerFailed(reader.error?.localizedDescription ?? "?")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
        progress(1)
        let dur = cmRange.duration
        return TranscodeOutput(dimensions: outDims, sourceDuration: try Self.sourceDuration(dur))
    }

    /// Converts the requested range (or the full asset) to CoreMedia; throws on timescales above Int32.max and
    /// on indefinite/invalid durations instead of trapping.
    static func cmTimeRange(_ range: TimeRange?, fullDuration: CMTime) throws -> CMTimeRange {
        func cm(_ t: Time) throws -> CMTime {
            guard let scale = CMTimeScale(exactly: t.timescale) else {
                throw ProxyTranscodeError.invalidTime("timescale \(t.timescale) exceeds Int32.max")
            }
            return CMTime(value: t.value, timescale: scale)
        }
        if let range { return CMTimeRange(start: try cm(range.start), duration: try cm(range.duration)) }
        guard fullDuration.isNumeric, fullDuration.timescale > 0 else {
            throw ProxyTranscodeError.invalidTime("source duration is indefinite")
        }
        return CMTimeRange(start: .zero, duration: fullDuration)
    }

    static func sourceDuration(_ d: CMTime) throws -> Time {
        guard d.isNumeric, d.timescale > 0 else { throw ProxyTranscodeError.invalidTime("duration is not numeric") }
        return Time(d.value, Int64(d.timescale))
    }

    static func qos(for p: TaskPriority) -> DispatchQoS.QoSClass {
        if p <= .background { return .background }
        if p <= .utility { return .utility }
        return .userInitiated
    }

    /// True when the source video carries an alpha channel: the ContainsAlphaChannel flag or an AlphaChannelMode tag
    /// (a bare 32-bit depth is not enough; opaque ProRes 4444 reports it too).
    static func hasAlpha(_ format: CMFormatDescription) -> Bool {
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        return (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) == true
            || ext[kCMFormatDescriptionExtension_AlphaChannelMode as String] != nil
    }

    /// Color tags from the source format description as an `AVVideoColorPropertiesKey` value (all three or none).
    static func colorProperties(from format: CMFormatDescription) -> [String: String]? {
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        guard let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
              let t = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
              let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String else { return nil }
        return [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
    }
}

private final class Job: @unchecked Sendable {
    let reader: AVAssetReader, writer: AVAssetWriter
    private let lock = NSLock()
    private var _cancelled = false
    private var _failure: ProxyTranscodeError?
    /// True after `cancel` and after `fail`: every pump stops.
    var cancelled: Bool { lock.withLock { _cancelled || _failure != nil } }
    var failure: ProxyTranscodeError? { lock.withLock { _failure } }
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    func cancel() {
        lock.withLock { _cancelled = true }
        reader.cancelReading()
    }
    /// Ends the job with `error` (the first one wins); the file is deleted by `transcode`.
    func fail(_ error: ProxyTranscodeError) {
        lock.withLock { if _failure == nil { _failure = error } }
        reader.cancelReading()
    }
}

private final class Progress: @unchecked Sendable {
    let start: CMTime, total: CMTime, sink: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var last = 0.0
    init(start: CMTime, total: CMTime, sink: @escaping @Sendable (Double) -> Void) { self.start = start; self.total = total; self.sink = sink }
    func report(_ pts: CMTime) {
        guard total.isNumeric, total.seconds > 0, pts.isNumeric else { return }
        let f = min(0.999, max(0, CMTimeSubtract(pts, start).seconds / total.seconds))
        let emit = lock.withLock { () -> Bool in if f - last >= 0.01 { last = f; return true }; return false }
        if emit { sink(f) }
    }
}

private final class Pump: @unchecked Sendable {
    let input: AVAssetWriterInput, output: AVAssetReaderOutput, tracksProgress: Bool
    let queue: DispatchQueue
    /// Field order of an interlaced video source: its frames are deinterlaced on the way to the writer.
    let deinterlace: FieldOrder?
    init(input: AVAssetWriterInput, output: AVAssetReaderOutput, tracksProgress: Bool, qos: DispatchQoS.QoSClass,
         deinterlace: FieldOrder? = nil) {
        self.input = input; self.output = output; self.tracksProgress = tracksProgress; self.deinterlace = deinterlace
        queue = DispatchQueue(label: "sqproxy.pump", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
    }

    func run(job: Job, progress: Progress) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard !job.cancelled, let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); cont.resume(); return
                    }
                    if tracksProgress { progress.report(CMSampleBufferGetPresentationTimeStamp(sb)) }
                    guard let frame = ProxyFields.writable(sb, fieldOrder: deinterlace) else {
                        job.fail(.deinterlaceFailed)
                        input.markAsFinished(); cont.resume(); return
                    }
                    if !input.append(frame) { input.markAsFinished(); cont.resume(); return }
                }
            }
        }
    }
}

/// What the video pump hands the writer for a source with fields.
enum ProxyFields {
    /// The sample to write: `sb` itself for a progressive source (`fieldOrder` nil) or a sample without a picture, its
    /// deinterlaced copy for an interlaced one. nil = the picture could not be deinterlaced and must not be written.
    static func writable(_ sb: CMSampleBuffer, fieldOrder: FieldOrder?) -> CMSampleBuffer? {
        guard let fieldOrder, CMSampleBufferGetImageBuffer(sb) != nil else { return sb }
        return progressive(sb, fieldOrder: fieldOrder)
    }

    /// `sb` with its picture deinterlaced, same timing. nil = no picture, or a format the pass does not know.
    static func progressive(_ sb: CMSampleBuffer, fieldOrder: FieldOrder) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let picture = Deinterlacer.deinterlace(source, fieldOrder: fieldOrder)
        guard picture !== source else { return nil }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: picture, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo()
        guard let format, CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: picture, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}
