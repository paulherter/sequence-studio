@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore

public enum ProxyTranscodeError: Error, Equatable {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case invalidTime(String)
}

/// AVAssetReader (hardware decode via VideoToolbox) -> AVAssetWriter (ProRes) transcoder.
public struct ProxyTranscoder: ProxyTranscoding {
    public init() {}

    public func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                          progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let (videoTracks, audioTracks, fullDuration) = try await (
            asset.loadTracks(withMediaType: .video), asset.loadTracks(withMediaType: .audio), asset.load(.duration))
        guard let video = videoTracks.first else { throw ProxyTranscodeError.noVideoTrack }
        let (natural, transform, formats, timescale) = try await video.load(.naturalSize, .preferredTransform, .formatDescriptions, .naturalTimeScale)
        guard let format = formats.first else { throw ProxyTranscodeError.noVideoTrack }

        let srcDims = ProxyDimensions(width: Int(natural.width.rounded()), height: Int(natural.height.rounded()))
        let outDims = srcDims.scaled(divisor: kind.scaleDivisor)
        let cmRange = try Self.cmTimeRange(timeRange, fullDuration: fullDuration)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = cmRange
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10,
        ]
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: readerSettings)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ProxyTranscodeError.readerFailed("cannot add video output") }
        reader.add(vOut)
        var vSettings: [String: Any] = [
            AVVideoCodecKey: kind == .optimized ? AVVideoCodecType.proRes422 : AVVideoCodecType.proRes422Proxy,
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
        var pumps: [Pump] = [Pump(input: vIn, output: vOut, tracksProgress: true, qos: qos)]

        // Audio: decode to PCM, all channels kept.
        for track in audioTracks {
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
    var cancelled: Bool { lock.withLock { _cancelled } }
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    func cancel() {
        lock.withLock { _cancelled = true }
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
    init(input: AVAssetWriterInput, output: AVAssetReaderOutput, tracksProgress: Bool, qos: DispatchQoS.QoSClass) {
        self.input = input; self.output = output; self.tracksProgress = tracksProgress
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
                    if !input.append(sb) { input.markAsFinished(); cont.resume(); return }
                }
            }
        }
    }
}
