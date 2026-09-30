import CoreMedia
import CoreVideo
import Foundation
import SSCore
import VideoToolbox

/// One decoded frame. `pixelBuffer` is IOSurface-backed and Metal compatible; immutable after creation.
public struct DecodedFrame: @unchecked Sendable {
    public let media: UUID, pts: Time, duration: Time
    public let pixelBuffer: CVPixelBuffer
    public var byteCost: Int {
        let total = CVPixelBufferGetDataSize(pixelBuffer)
        if total > 0 { return total }
        var sum = 0
        for p in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            sum += CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, p) * CVPixelBufferGetHeightOfPlane(pixelBuffer, p)
        }
        return sum > 0 ? sum : CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
    }
    public init(media: UUID, pts: Time, duration: Time, pixelBuffer: CVPixelBuffer) {
        self.media = media; self.pts = pts; self.duration = duration; self.pixelBuffer = pixelBuffer
    }
}

public protocol VideoDecoding: Sendable {
    var info: VideoTrackInfo { get }
    var isHardware: Bool { get }
    /// Decodes presentation frames `range` and returns them in PTS order. Continues from the previous call without
    /// reseeking when `range` starts right after the last decoded frame (forward playback). Cancellable (Task).
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame]
    func invalidate()
}

/// VT destination size divisor (Program monitor quality popup).
public enum DecodeScale: Sendable, Hashable {
    case full, half, quarter
    var divisor: Int { self == .full ? 1 : self == .half ? 2 : 4 }
}

/// Pixel format requested from VideoToolbox. Left alone, VT hands out Apple's lossless-compressed variants
/// (`&8v0`, `&xf0`, `&xf2` ...); the packed 10-bit ones cannot be sampled by Metal (CVMetalTextureCache), so the
/// compositor drew Sony 4:2:2 10-bit and 4:2:0 10-bit as `.damaged`. We ask for the stream's native uncompressed
/// bi-planar format instead (memory bandwidth cost: ARCHITECTURE §5 risk).
public enum DecodePixelFormat {
    /// Bi-planar Y + CbCr format matching the stream's chroma subsampling, bit depth (> 8 = 10-bit planes) and range.
    public static func nativeUncompressed(for info: VideoTrackInfo, fullRange: Bool) -> OSType {
        let ten = info.bitDepth > 8
        switch info.chroma {
        case "4:2:2":
            return ten ? (fullRange ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
                : (fullRange ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange)
        case "4:4:4":
            return ten ? (fullRange ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
                : (fullRange ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
        default:
            return ten ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    /// `kCMFormatDescriptionExtension_FullRangeVideo` of the stream (absent = video range).
    public static func isFullRange(_ format: CMFormatDescription) -> Bool {
        (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) ?? false
    }
}

/// VideoToolbox decoder over a `Demuxing`. Hardware first; there is no software retry (Sony H.264 4:2:2 has no
/// software decoder, a failure is a clip error). Calls to `decode` must not overlap (one job per media).
public final class VTVideoDecoder: VideoDecoding, @unchecked Sendable {
    public let info: VideoTrackInfo

    /// Observable for tests.
    struct Stats: Equatable { var syncSubmissions = 0, reseeks = 0, samplesSubmitted = 0 }

    private let demuxer: any Demuxing
    private let media: UUID
    private let scale: DecodeScale
    private let pixelFormat: OSType
    private let presentationIndexOfOrdinal: [Int]
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var hardware = false
    private var lastOrdinal: Int?      // highest decode ordinal submitted since the last (re)seek
    private var carry: [Int: CVPixelBuffer] = [:]   // decoded ahead of the requested range (B-frame look-ahead), by presentation index
    private var _stats = Stats()

    public var isHardware: Bool { lock.withLock { hardware } }
    var stats: Stats { lock.withLock { _stats } }
    /// Number of times decoding restarted at a sync sample (seeks), for diagnostics.
    public var reseekCount: Int { stats.reseeks }

    public init(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full) throws {
        self.demuxer = demuxer; self.media = media; self.scale = scale
        let entries = demuxer.index.entries
        var inv = [Int](repeating: 0, count: entries.count)
        for (i, e) in entries.enumerated() where e.decodeOrdinal >= 0 && e.decodeOrdinal < entries.count { inv[e.decodeOrdinal] = i }
        presentationIndexOfOrdinal = inv
        let fd = demuxer.formatDescription
        info = try MediaImporter.videoInfo(format: fd, index: demuxer.index, rotation: demuxer.rotation)
        let (w, h) = (info.width, info.height)
        pixelFormat = DecodePixelFormat.nativeUncompressed(for: info, fullRange: DecodePixelFormat.isFullRange(fd))
        let (s, hw) = try Self.makeSession(format: fd, width: w, height: h, scale: scale, pixelFormat: pixelFormat)
        session = s; hardware = hw
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// Requests `pixelFormat` (native uncompressed, see `DecodePixelFormat`); if VT refuses it, retries with VT's choice.
    private static func makeSession(format: CMFormatDescription, width: Int, height: Int, scale: DecodeScale,
                                    pixelFormat: OSType) throws -> (VTDecompressionSession, Bool) {
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var dest: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                     kCVPixelBufferPixelFormatTypeKey: pixelFormat]
        if scale != .full {
            dest[kCVPixelBufferWidthKey] = max(2, (width / scale.divisor) & ~1)
            dest[kCVPixelBufferHeightKey] = max(2, (height / scale.divisor) & ~1)
        }
        var s: VTDecompressionSession?
        var st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: dest as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        if st != noErr && st != kVTCouldNotFindVideoDecoderErr && st != kVTVideoDecoderUnsupportedDataFormatErr {
            dest[kCVPixelBufferPixelFormatTypeKey] = nil
            st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: dest as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        }
        guard st == noErr, let s else {
            throw st == kVTCouldNotFindVideoDecoderErr || st == kVTVideoDecoderUnsupportedDataFormatErr
                ? MediaError.unsupportedCodec(fourCC(CMFormatDescriptionGetMediaSubType(format)))
                : MediaError.decodeFailed(st)
        }
        var v: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &v)
        return (s, (v as? Bool) ?? false)
    }

    public func invalidate() {
        lock.withLock {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; lastOrdinal = nil; carry = [:]
        }
    }

    /// Collects output frames from VT's callback threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Time: CVPixelBuffer] = [:]
        private var error: OSStatus = noErr
        func add(_ pts: Time, _ pb: CVPixelBuffer) { lock.withLock { frames[pts] = pb } }
        func fail(_ s: OSStatus) { lock.withLock { if error == noErr { error = s } } }
        var result: (frames: [Time: CVPixelBuffer], error: OSStatus) { lock.withLock { (frames, error) } }
    }

    public func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        guard range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        try Task.checkCancellation()

        let (last, continues) = plan(range)
        // Fresh start: open-GOP streams (HEVC) put leading pictures after the sync sample in decode order; they
        // reference the previous GOP. Start one GOP earlier when the range needs them.
        var lo = range.lowerBound
        if !continues {
            while true {
                let sp = presentationIndexOfOrdinal[demuxer.index.syncDecodeOrdinal(for: lo)]
                if lo >= sp || lo == 0 { break }   // lo == 0: no earlier GOP (clip start)
                lo = demuxer.index.previousSync(before: lo)   // strictly decreasing: terminates
            }
        }
        let syncOrdinal = demuxer.index.syncDecodeOrdinal(for: lo)
        let samples = try await demuxer.samples(for: lo...range.upperBound)
        try Task.checkCancellation()
        return try run(samples, range: range, start: lo, syncOrdinal: syncOrdinal, continuing: continues, last: last)
    }

    /// Continue when every frame the range needs is either carried over or still ahead of the submitted samples.
    private func plan(_ range: ClosedRange<Int>) -> (last: Int?, continues: Bool) {
        let entries = demuxer.index.entries
        let syncOrdinal = demuxer.index.syncDecodeOrdinal(for: range.lowerBound)
        return lock.withLock {
            guard session != nil, let last = lastOrdinal, syncOrdinal <= last + 1 else { return (nil, false) }
            let ok = range.allSatisfy { entries[$0].decodeOrdinal > last || carry[$0] != nil }
            return (last, ok)
        }
    }

    private func currentSession() throws -> VTDecompressionSession {
        if let s = lock.withLock({ session }) { return s }
        let d = CMVideoFormatDescriptionGetDimensions(demuxer.formatDescription)
        let (s, hw) = try Self.makeSession(format: demuxer.formatDescription, width: Int(d.width), height: Int(d.height), scale: scale,
                                           pixelFormat: pixelFormat)
        lock.withLock { session = s; hardware = hw }
        return s
    }

    /// Synchronous VT work (kept out of the async function: no non-Sendable values live across a suspension).
    private func run(_ samples: [CMSampleBuffer], range: ClosedRange<Int>, start: Int,
                     syncOrdinal: Int, continuing continues: Bool, last: Int?) throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        let first = syncOrdinal
        let skip = continues ? (last! + 1 - first) : 0
        // Leading pictures of a fresh sync sample are not decodable and not needed (see decode).
        let dropBelow = continues ? 0 : min(presentationIndexOfOrdinal[first], start)
        let carried: [Int: CVPixelBuffer] = lock.withLock {
            if !continues {
                _stats.reseeks += 1; carry = [:]
            }
            lastOrdinal = nil
            return carry
        }

        let session = try currentSession()
        let collector = Collector()
        var keyToIndex: [Time: Int] = [:]
        var submittedLast = last
        var failure: Error?
        var i = max(0, skip)
        while i < samples.count {
            if Task.isCancelled { failure = CancellationError(); break }
            let sb = samples[i]
            let ordinal = first + i
            guard let pts = Time(CMSampleBufferGetPresentationTimeStamp(sb)), ordinal < presentationIndexOfOrdinal.count else {
                failure = MediaError.truncated; break
            }
            if presentationIndexOfOrdinal[ordinal] < dropBelow { i += 1; continue }
            keyToIndex[pts] = presentationIndexOfOrdinal[ordinal]
            let notSync = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
                .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            var info = VTDecodeInfoFlags()
            let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: &info) { status, _, image, pts, _ in
                if status != noErr { collector.fail(status); return }
                if let image, let t = Time(pts) { collector.add(t, image) }
            }
            lock.withLock { _stats.samplesSubmitted += 1; if !notSync { _stats.syncSubmissions += 1 } }
            if st != noErr { failure = MediaError.decodeFailed(st); break }
            submittedLast = ordinal
            i += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let (frames, err) = collector.result
        if let failure {
            lock.withLock { lastOrdinal = nil }
            throw failure
        }
        if err != noErr { lock.withLock { lastOrdinal = nil }; throw MediaError.decodeFailed(err) }
        lock.withLock { lastOrdinal = submittedLast }

        var byIndex = carried
        for (t, pb) in frames { if let idx = keyToIndex[t] { byIndex[idx] = pb } }
        lock.withLock { carry = byIndex.filter { $0.key > range.upperBound } }
        var out: [DecodedFrame] = []
        out.reserveCapacity(range.count)
        for idx in range {
            guard let pb = byIndex[idx] else { lock.withLock { lastOrdinal = nil }; throw MediaError.truncated }
            out.append(DecodedFrame(media: media, pts: entries[idx].pts, duration: entries[idx].duration, pixelBuffer: pb))
        }
        return out
    }
}
