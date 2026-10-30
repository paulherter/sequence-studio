@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore

/// Pure frame-slot math of a variable-frame-rate conform: which output frames (at `k * frameDuration`) a source frame
/// fills. Frames are placed at the nearest slot; a frame whose slot is taken by a later one is dropped, a gap is filled
/// by repeating the frame before it. Time stays rational.
public enum VFRConformPlan {
    /// Slot index nearest to `t` (half up), never below 0.
    public static func slot(of t: Time, frameDuration fd: Time) -> Int64 {
        guard fd.value > 0, t.value > 0 else { return 0 }
        let num = Int128(2) * Int128(t.value) * Int128(fd.timescale) + Int128(fd.value) * Int128(t.timescale)
        let den = Int128(2) * Int128(fd.value) * Int128(t.timescale)
        return Int64(num / den)
    }

    /// Slots filled by the frame at `pts` when the next frame (or the end of the clip) is at `next`. A first frame
    /// starts at slot 0 (its picture is held back to the start of the clip instead of leaving it empty).
    public static func slots(pts: Time, next: Time, frameDuration fd: Time, isFirst: Bool) -> Range<Int64> {
        let lo = isFirst ? 0 : slot(of: pts, frameDuration: fd)
        let hi = slot(of: next, frameDuration: fd)
        return lo..<max(lo, hi)
    }

    /// Slot range of every source frame; the sum of their sizes is the output frame count.
    public static func plan(pts: [Time], end: Time, frameDuration fd: Time) -> [Range<Int64>] {
        pts.indices.map { i in
            slots(pts: pts[i], next: i + 1 < pts.count ? pts[i + 1] : end, frameDuration: fd, isFirst: i == 0)
        }
    }
}

public enum VFRConformError: Error, Equatable, LocalizedError {
    case noVideoTrack, invalidFrameDuration
    case readerFailed(String)
    case writerFailed(String)

    /// English text (the display sink translates it with `SQL10n.localized`).
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .invalidFrameDuration: "The frame rate is not valid."
        case .readerFailed(let why): "The file could not be read: \(why)"
        case .writerFailed(let why): "The copy could not be written: \(why)"
        }
    }
}

/// Re-encodes a variable-frame-rate clip to a constant rate (ProRes 422, audio kept as PCM, picture size, rotation and
/// color tags kept) so cuts and audio stay in sync. The copy is a new file; the original is never touched.
public enum VFRConform {
    public struct Output: Sendable, Equatable {
        public var frameCount: Int
        public var frameDuration: Time
    }

    public static func conform(source: URL, destination: URL, frameDuration fd: Time,
                               progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> Output {
        guard fd.value > 0, fd.timescale > 0, fd.timescale <= Int64(Int32.max) else { throw VFRConformError.invalidFrameDuration }
        let asset = AVURLAsset(url: source)
        let (videos, audios, duration) = try await (asset.loadTracks(withMediaType: .video),
                                                    asset.loadTracks(withMediaType: .audio), asset.load(.duration))
        guard let video = videos.first else { throw VFRConformError.noVideoTrack }
        let (transform, formats) = try await video.load(.preferredTransform, .formatDescriptions)
        guard let format = formats.first else { throw VFRConformError.noVideoTrack }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let end = Time(duration.value, Int64(duration.timescale))

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw VFRConformError.readerFailed("cannot add video output") }
        reader.add(vOut)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422,
                                       AVVideoWidthKey: Int(dims.width), AVVideoHeightKey: Int(dims.height)]
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let t = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        vIn.mediaTimeScale = CMTimeScale(fd.timescale)
        writer.add(vIn)

        var audioPumps: [(AVAssetWriterInput, AVAssetReaderOutput)] = []
        for track in await UsableAudioTracks.tracks(audios) {
            guard let af = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            var pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: asbd.mSampleRate,
                                      AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                      AVLinearPCMIsNonInterleaved: false]
            var layoutSize = 0
            var layout: Data
            if let l = CMAudioFormatDescriptionGetChannelLayout(af, sizeOut: &layoutSize), layoutSize > 0 {
                layout = Data(bytes: l, count: layoutSize)
            } else {
                var l = AudioChannelLayout()
                l.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo
                    : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
                layout = Data(bytes: &l, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let aOut = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            pcm[AVChannelLayoutKey] = layout
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            aIn.expectsMediaDataInRealTime = false
            guard reader.canAdd(aOut), writer.canAdd(aIn) else { continue }
            reader.add(aOut); writer.add(aIn)
            audioPumps.append((aIn, aOut))
        }

        guard reader.startReading() else { throw VFRConformError.readerFailed(reader.error?.localizedDescription ?? "?") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VFRConformError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
        writer.startSession(atSourceTime: .zero)

        let state = ConformState(frameDuration: fd, end: end, reader: reader, progress: progress)
        let pumps = audioPumps
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await state.pumpVideo(input: vIn, output: vOut) }
                for (i, o) in pumps { group.addTask { await state.pumpAudio(input: i, output: o) } }
            }
        } onCancel: { state.cancel() }

        func cleanup() { reader.cancelReading(); writer.cancelWriting(); try? FileManager.default.removeItem(at: destination) }
        if state.cancelled || Task.isCancelled { cleanup(); throw CancellationError() }
        if reader.status == .failed { cleanup(); throw VFRConformError.readerFailed(reader.error?.localizedDescription ?? "?") }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw VFRConformError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
        progress(1)
        return Output(frameCount: state.framesWritten, frameDuration: fd)
    }
}

private final class ConformState: @unchecked Sendable {
    let fd: Time, end: Time, reader: AVAssetReader, progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var _cancelled = false, _frames = 0
    var cancelled: Bool { lock.withLock { _cancelled } }
    var framesWritten: Int { lock.withLock { _frames } }

    /// Video pump state, touched only on the video queue.
    private var current: (buffer: CVImageBuffer, pts: Time)?
    private var isFirst = true
    private var pendingSlots: Range<Int64> = 0..<0
    private var held: (buffer: CVImageBuffer, pts: Time)?
    private var finishedReading = false

    init(frameDuration: Time, end: Time, reader: AVAssetReader, progress: @escaping @Sendable (Double) -> Void) {
        fd = frameDuration; self.end = end; self.reader = reader; self.progress = progress
    }
    func cancel() { lock.withLock { _cancelled = true }; reader.cancelReading() }

    func pumpVideo(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput) async {
        let queue = DispatchQueue(label: "sqmedia.vfrconform.video", qos: .utility)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                // One frame of lookahead: a frame's slots are known once the next frame's time is. A long gap makes many
                // slots, so they are written one by one while the input is ready.
                while input.isReadyForMoreMediaData {
                    if pendingSlots.isEmpty, let h = held { current = h; held = nil }
                    if let cur = current, let slot = pendingSlots.first {
                        pendingSlots = (slot + 1)..<pendingSlots.upperBound
                        if !append(cur.buffer, slot: slot, to: input) { input.markAsFinished(); cont.resume(); return }
                        continue
                    }
                    if finishedReading { input.markAsFinished(); cont.resume(); return }
                    var next: (buffer: CVImageBuffer, pts: Time)?
                    if !cancelled, let sb = output.copyNextSampleBuffer() {
                        guard let img = CMSampleBufferGetImageBuffer(sb) else { continue }
                        let p = CMSampleBufferGetPresentationTimeStamp(sb)
                        next = (img, Time(p.value, Int64(p.timescale)))
                    }
                    if let cur = current {
                        let upTo = next?.pts ?? end
                        pendingSlots = VFRConformPlan.slots(pts: cur.pts, next: upTo, frameDuration: fd, isFirst: isFirst)
                        isFirst = false
                        let total = Double(end.value) / Double(end.timescale)
                        progress(min(0.999, max(0, Double(upTo.value) / Double(upTo.timescale) / max(total, 1e-9))))
                    }
                    if let n = next {
                        // The previous frame's slots are written first (the loop above), then this one becomes current.
                        if pendingSlots.isEmpty { current = n } else { held = n }
                    } else {
                        finishedReading = true
                    }
                }
            }
        }
    }

    private func append(_ buffer: CVImageBuffer, slot: Int64, to input: AVAssetWriterInput) -> Bool {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return false }
        let scale = CMTimeScale(fd.timescale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: fd.value, timescale: scale),
                                        presentationTimeStamp: CMTime(value: slot * fd.value, timescale: scale),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        guard let out, input.append(out) else { return false }
        lock.withLock { _frames += 1 }
        return true
    }

    func pumpAudio(input: AVAssetWriterInput, output: AVAssetReaderOutput) async {
        let queue = DispatchQueue(label: "sqmedia.vfrconform.audio", qos: .utility)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard !cancelled, let sb = output.copyNextSampleBuffer(), input.append(sb) else {
                        input.markAsFinished(); cont.resume(); return
                    }
                }
            }
        }
    }
}
