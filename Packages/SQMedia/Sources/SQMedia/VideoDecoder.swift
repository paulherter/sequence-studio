import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQFrame
import SQFrameCoreVideo
import Synchronization
import VideoToolbox

extension H264NAL {
    /// `isDisposable` on a sample buffer's data.
    static func isDisposable(_ sb: CMSampleBuffer, lengthSize: Int) -> Bool {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return false }
        var contiguous = bb
        if !CMBlockBufferIsRangeContiguous(bb, atOffset: 0, length: 0) {
            var c: CMBlockBuffer?
            guard CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: bb, blockAllocator: nil, customBlockSource: nil,
                                                offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &c) == noErr, let c else { return false }
            contiguous = c
        }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr, let ptr else { return false }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: length) {
            isDisposable(UnsafeBufferPointer(start: $0, count: length), lengthSize: lengthSize)
        }
    }

    /// NAL length size of an H.264 format description, nil for other codecs.
    static func lengthSize(of format: CMFormatDescription) -> Int? {
        let sub = CMFormatDescriptionGetMediaSubType(format)
        guard sub == kCMVideoCodecType_H264 || sub == FourCharCode(0x61766333) /* avc3 */ else { return nil }
        var count = 0, header: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &header) == noErr,
              (1...4).contains(header) else { return nil }
        return Int(header)
    }
}

/// Pixel format requested from VideoToolbox. Left alone, VT hands out Apple's lossless-compressed variants
/// (`&8v0`, `&xf0`, `&xf2` ...); the packed 10-bit ones cannot be sampled by Metal (CVMetalTextureCache), so the
/// compositor drew Sony 4:2:2 10-bit and 4:2:0 10-bit as `.damaged`. We ask for the stream's native uncompressed
/// bi-planar format instead (memory bandwidth cost: ARCHITECTURE §5 risk).
public enum DecodePixelFormat {
    /// Bi-planar Y + CbCr format matching the stream's chroma subsampling, bit depth (> 8 = 10-bit planes) and range.
    /// Streams with alpha (`alpha` non-nil) decode to packed 4:4:4:4 'y416' instead (A, Y', Cb, Cr, 16 bit each,
    /// video-range Y'CbCr, full-range alpha): ProRes 4444's native output and the one alpha format both ProRes and HEVC
    /// decoders produce; the compositor samples it as one rgba16Unorm texture.
    public static func nativeUncompressed(for info: VideoTrackInfo, fullRange: Bool, alpha: AlphaChannel? = nil) -> OSType {
        if alpha != nil { return alphaFormat }
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

    /// Decode format for streams with alpha.
    public static let alphaFormat: OSType = kCVPixelFormatType_4444AYpCbCr16

    /// Alpha of the stream, nil when it is opaque. A stream that says it has alpha counts: `ContainsAlphaChannel`, an
    /// `AlphaChannelMode` tag, or (ProRes 4444 only) the QuickTime depth 32. The mode tag wins; untagged ProRes 4444 is straight (SMPTE RDD 36; FFmpeg and
    /// Premiere read it so), untagged HEVC with alpha premultiplied (the default of Apple's HEVC-with-alpha encoder).
    public static func alphaChannel(of format: CMFormatDescription) -> AlphaChannel? {
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let flagged = (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) ?? false
        let mode = ext[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String
        let sub = CMFormatDescriptionGetMediaSubType(format)
        let proRes4444 = sub == kCMVideoCodecType_AppleProRes4444 || sub == kCMVideoCodecType_AppleProRes4444XQ
        // QuickTime "depth 32" = color + alpha. Files from After Effects, Resolve, FFmpeg carry it without the
        // ContainsAlphaChannel key Apple's own writers add; an AVAssetWriter opaque 4444 file says depth 24.
        let depth32 = (ext[kCMFormatDescriptionExtension_Depth as String] as? Int) == 32
        guard flagged || mode != nil || (proRes4444 && depth32) else { return nil }
        if mode == kCMFormatDescriptionAlphaChannelMode_StraightAlpha as String { return .straight }
        if mode == kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String { return .premultiplied }
        return proRes4444 ? .straight : .premultiplied
    }

    /// `kCMFormatDescriptionExtension_FullRangeVideo` of the stream (absent = video range).
    public static func isFullRange(_ format: CMFormatDescription) -> Bool {
        (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) ?? false
    }
}

/// How a stream's color relates to its alpha. Decoded frames carry it as `kCVImageBufferAlphaChannelModeKey`.
public enum AlphaChannel: Sendable, Equatable {
    case straight, premultiplied

    var attachment: CFString {
        self == .straight ? kCVImageBufferAlphaChannelMode_StraightAlpha : kCVImageBufferAlphaChannelMode_PremultipliedAlpha
    }
}

/// VideoToolbox decoder over a `Demuxing`. Hardware first; there is no software retry (Sony H.264 4:2:2 has no
/// software decoder, a failure is a clip error). Calls to `decode` must not overlap (one job per media).
public final class VTVideoDecoder: VideoDecoding, @unchecked Sendable {
    public let info: VideoTrackInfo
    /// Alpha of the stream (nil = opaque); frames then are 'y416' tagged with this mode.
    public let alpha: AlphaChannel?

    /// Observable for tests.
    struct Stats: Equatable { var syncSubmissions = 0, reseeks = 0, samplesSubmitted = 0, samplesSkipped = 0 }

    private let demuxer: any Demuxing
    private let media: UUID
    private let scale: DecodeScale
    private let deinterlace: FieldOrder?
    /// Reduces the deinterlaced picture to the size asked for (nil at full size and without the pass).
    private let scaler: DeinterlacedFrameScaler?
    /// Deinterlacing: formats the pass knows, tried when VT refuses `pixelFormat`, before VT's own choice.
    private let fallbackFormats: [OSType]
    private let pixelFormat: OSType
    private let presentationIndexOfOrdinal: [Int]
    /// H.264 only: NAL length size, for skipping unreferenced pictures before a seek target.
    private let nalLengthSize: Int?
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var hardware = false
    private var reduced = false
    private var lastOrdinal: Int?      // highest decode ordinal submitted since the last (re)seek
    private var carry: [Int: CVPixelBuffer] = [:]   // decoded ahead of the requested range (B-frame look-ahead), by presentation index
    private var _stats = Stats()

    public var isHardware: Bool { lock.withLock { hardware } }
    /// The decoder itself decodes at the preview size (`kVTDecompressionPropertyKey_ReducedResolutionDecode`, ProRes)
    /// instead of VT scaling the full frame afterwards.
    public var usesReducedResolutionDecode: Bool { lock.withLock { reduced } }
    var stats: Stats { lock.withLock { _stats } }
    /// Number of times decoding restarted at a sync sample (seeks), for diagnostics.
    public var reseekCount: Int { stats.reseeks }
    /// H.264 samples a seek (`neededFrom`) did not decode: nothing references them (diagnostics).
    public var skippedSampleCount: Int { stats.samplesSkipped }

    /// `deinterlace`: the field order of an interlaced source whose frames leave the decoder progressive
    /// (`Deinterlacer`); nil = frames as stored. Fields need the stored lines, so such a decoder always decodes at
    /// full size (VT's scaled output would blend the two fields first) and reduces the picture to `scale` after the
    /// pass: its frames have the size `scale` names, like any other decoder's.
    public init(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full, deinterlace: FieldOrder? = nil) throws {
        self.demuxer = demuxer; self.media = media; self.scale = deinterlace == nil ? scale : .full
        self.deinterlace = deinterlace
        scaler = deinterlace != nil && scale != .full ? DeinterlacedFrameScaler(divisor: scale.divisor) : nil
        let entries = demuxer.index.entries
        var inv = [Int](repeating: 0, count: entries.count)
        for (i, e) in entries.enumerated() where e.decodeOrdinal >= 0 && e.decodeOrdinal < entries.count { inv[e.decodeOrdinal] = i }
        presentationIndexOfOrdinal = inv
        let fd = demuxer.formatDescription
        nalLengthSize = H264NAL.lengthSize(of: fd)
        info = try MediaImporter.videoInfo(format: fd, index: demuxer.index, rotation: demuxer.rotation)
        let (w, h) = (info.width, info.height)
        alpha = DecodePixelFormat.alphaChannel(of: fd)
        pixelFormat = DecodePixelFormat.nativeUncompressed(for: info, fullRange: DecodePixelFormat.isFullRange(fd), alpha: alpha)
        let wanted = pixelFormat
        fallbackFormats = deinterlace != nil && alpha == nil
            ? [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].filter { $0 != wanted }
            : []
        let (s, hw, rr) = try Self.makeSession(format: fd, width: w, height: h, scale: self.scale, pixelFormat: pixelFormat,
                                               fallbacks: fallbackFormats)
        session = s; hardware = hw; reduced = rr
    }

    /// The frame as it leaves the decoder: deinterlaced when the decoder was asked to.
    /// A picture the pass cannot read (a format VT chose itself) stays woven, but is reduced all the same.
    private static func finished(_ pb: CVPixelBuffer, _ order: FieldOrder?, _ scaler: DeinterlacedFrameScaler?) -> CVPixelBuffer {
        guard let order else { return pb }
        let picture = Deinterlacer.deinterlace(pb, fieldOrder: order)
        return scaler?.run(picture) ?? picture
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// Requests `pixelFormat` (native uncompressed, see `DecodePixelFormat`); if VT refuses it, retries with VT's choice.
    /// Preview scales (half, quarter) ask decoders that support it (ProRes) to decode at the reduced size: VT's scaled
    /// output is a separate pass that caps a session at ~200 frames/s (4.9 vs 0.7 ms per 4K ProRes frame). Full size is
    /// never reduced, so export pixels are unchanged. H.264 / HEVC have no reduced decode (scaled output as before).
    private static func makeSession(format: CMFormatDescription, width: Int, height: Int, scale: DecodeScale,
                                    pixelFormat: OSType, fallbacks: [OSType] = []) throws -> (VTDecompressionSession, Bool, Bool) {
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
        for other in fallbacks.map(Optional.some) + [nil] {
            guard st != noErr && st != kVTCouldNotFindVideoDecoderErr && st != kVTVideoDecoderUnsupportedDataFormatErr else { break }
            dest[kCVPixelBufferPixelFormatTypeKey] = other
            st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: dest as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        }
        guard st == noErr, let s else {
            throw st == kVTCouldNotFindVideoDecoderErr || st == kVTVideoDecoderUnsupportedDataFormatErr
                ? MediaError.unsupportedCodec(fourCC(CMFormatDescriptionGetMediaSubType(format)))
                : MediaError.decodeFailed(st)
        }
        var reduced = false
        if scale != .full {
            var supported: CFDictionary?
            VTSessionCopySupportedPropertyDictionary(s, supportedPropertyDictionaryOut: &supported)
            if let keys = supported as? [String: Any], keys[kVTDecompressionPropertyKey_ReducedResolutionDecode as String] != nil {
                let size: [CFString: Any] = [kVTDecompressionResolutionKey_Width: max(2, (width / scale.divisor) & ~1),
                                             kVTDecompressionResolutionKey_Height: max(2, (height / scale.divisor) & ~1)]
                reduced = VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_ReducedResolutionDecode,
                                               value: size as CFDictionary) == noErr
            }
        }
        var v: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &v)
        return (s, (v as? Bool) ?? false, reduced)
    }

    public func invalidate() {
        lock.withLock {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; lastOrdinal = nil; carry = [:]
        }
    }

    /// Collects output frames from VT's callback threads. A frame handed out early is only recorded, not held: the
    /// caller owns it (the playback cache drops far ones at once), so a long GOP is never pinned until the job ends.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Time: CVPixelBuffer] = [:]
        private var handedOut: Set<Time> = []
        private var error: OSStatus = noErr
        private(set) var peak = 0
        func add(_ pts: Time, _ pb: CVPixelBuffer) { lock.withLock { frames[pts] = pb; peak = max(peak, frames.count) } }
        func handOut(_ pts: Time) { lock.withLock { handedOut.insert(pts) } }
        func fail(_ s: OSStatus) { lock.withLock { if error == noErr { error = s } } }
        var result: (frames: [Time: CVPixelBuffer], handedOut: Set<Time>, error: OSStatus, peak: Int) {
            lock.withLock { (frames, handedOut, error, peak) }
        }
    }

    private var _peakHeld = 0
    /// Most frames one `decode` held at once (tests: early delivery must not pin a whole GOP).
    var peakHeldFrames: Int { lock.withLock { _peakHeld } }

    public func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] { try await decode(range, early: nil, neededFrom: nil) }

    public func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try await decode(range, early: deliver, neededFrom: nil)
    }

    /// H.264: samples before `neededFrom` (presentation index) that no picture references are not decoded, and those
    /// frames are left out of the result (a seek reaches its target sooner; frames from the target on are unchanged).
    public func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                       deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try await decode(range, early: deliver, neededFrom: neededFrom)
    }

    private func decode(_ range: ClosedRange<Int>, early deliver: (@Sendable (DecodedFrame) -> Void)?,
                        neededFrom: Int?) async throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        guard range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        try Task.checkCancellation()

        let (last, continues) = plan(range)
        // Fresh start: open-GOP streams (HEVC) put leading pictures after the sync sample in decode order; they
        // reference the previous GOP. Start one GOP earlier when the range needs them. A seek (`neededFrom`) needs only
        // the frames from its target on: leading pictures before it never pull in the previous GOP.
        let needed = neededFrom.map { min(max($0, range.lowerBound), range.upperBound) }
        var lo = continues ? range.lowerBound : (needed ?? range.lowerBound)
        if !continues { lo = demuxer.index.freshDecodeStart(for: lo) }
        let syncOrdinal = demuxer.index.syncDecodeOrdinal(for: lo)
        // Continuing: only the samples not submitted yet are read (not the GOP again from its sync sample).
        let base = continues ? max(syncOrdinal, last! + 1) : syncOrdinal
        // Streaming reader: each sample is submitted as soon as it is read, so the hardware decoder starts on the first
        // sample while the rest of the GOP is still being read (PLAYBACK-PERF "Seek: exact frame sooner").
        let reader: any SampleReading
        if let r = try demuxer.sampleReader(for: lo...range.upperBound, fromDecodeOrdinal: base) {
            reader = r
        } else {
            reader = ArrayReader(try await demuxer.samples(for: lo...range.upperBound, fromDecodeOrdinal: base))
        }
        try Task.checkCancellation()
        return try run(reader, base: base, range: range, start: lo, syncOrdinal: syncOrdinal, continuing: continues, last: last,
                       deliver: deliver, skipBefore: needed)
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
        let (s, hw, rr) = try Self.makeSession(format: demuxer.formatDescription, width: Int(d.width), height: Int(d.height),
                                               scale: scale, pixelFormat: pixelFormat, fallbacks: fallbackFormats)
        lock.withLock { session = s; hardware = hw; reduced = rr }
        return s
    }

    /// Synchronous VT work (kept out of the async function: no non-Sendable values live across a suspension).
    /// The reader's first sample is decode ordinal `base`.
    private func run(_ reader: any SampleReading, base: Int, range: ClosedRange<Int>, start: Int,
                     syncOrdinal: Int, continuing continues: Bool, last: Int?,
                     deliver: (@Sendable (DecodedFrame) -> Void)?, skipBefore: Int?) throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        let first = syncOrdinal
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
        // Early delivery (decode order, VT callback thread): output pts -> presentation index of the frames in `range`
        // that are shown (zero-duration samples are reference-only, see below).
        // Filled per sample just before its submit (a frame is only output after its own submit), read on VT's threads.
        let earlyMap = Mutex<[Time: Int]>([:])
        let media = self.media
        let alphaTag = alpha?.attachment
        let fields = deinterlace, scaler = self.scaler
        var keyToIndex: [Time: Int] = [:]
        var submittedLast = last
        var skipped: Set<Int> = []
        var failure: Error?
        var i = 0
        let total = reader.count
        while i < total {
            if Task.isCancelled { failure = CancellationError(); break }
            let sb: CMSampleBuffer
            do { sb = try reader.next() } catch { failure = error; break }
            let ordinal = base + i
            guard let pts = Time(CMSampleBufferGetPresentationTimeStamp(sb)), ordinal < presentationIndexOfOrdinal.count else {
                failure = MediaError.truncated; break
            }
            if presentationIndexOfOrdinal[ordinal] < dropBelow { i += 1; continue }
            if let skipBefore, let ls = nalLengthSize, presentationIndexOfOrdinal[ordinal] < skipBefore,
               H264NAL.isDisposable(sb, lengthSize: ls) {
                skipped.insert(presentationIndexOfOrdinal[ordinal])
                lock.withLock { _stats.samplesSkipped += 1 }
                submittedLast = ordinal
                i += 1; continue
            }
            keyToIndex[pts] = presentationIndexOfOrdinal[ordinal]
            if deliver != nil {
                let idx = presentationIndexOfOrdinal[ordinal]
                if range.contains(idx), entries[idx].duration != .zero { earlyMap.withLock { $0[pts] = idx } }
            }
            let notSync = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
                .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            var info = VTDecodeInfoFlags()
            let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: &info) { status, _, image, pts, _ in
                if status != noErr { collector.fail(status); return }
                if let image, let t = Time(pts) {
                    // Frames without their own tag get the stream's (inferred) mode; a tag VT already set is kept.
                    if let alphaTag, CVBufferCopyAttachment(image, kCVImageBufferAlphaChannelModeKey, nil) == nil {
                        CVBufferSetAttachment(image, kCVImageBufferAlphaChannelModeKey, alphaTag, .shouldPropagate)
                    }
                    if let deliver, let idx = earlyMap.withLock({ $0[t] }) {
                        collector.handOut(t)
                        deliver(DecodedFrame(media: media, pts: entries[idx].pts, duration: entries[idx].duration,
                                             pixelBuffer: Self.finished(image, fields, scaler)))
                    } else {
                        collector.add(t, image)
                    }
                }
            }
            lock.withLock { _stats.samplesSubmitted += 1; if !notSync { _stats.syncSubmissions += 1 } }
            if st != noErr { failure = MediaError.decodeFailed(st); break }
            submittedLast = ordinal
            i += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let (frames, handedOut, err, peak) = collector.result
        lock.withLock { _peakHeld = peak }
        if let failure {
            lock.withLock { lastOrdinal = nil }
            throw failure
        }
        if err != noErr { lock.withLock { lastOrdinal = nil }; throw MediaError.decodeFailed(err) }
        lock.withLock { lastOrdinal = submittedLast }

        var byIndex = carried
        for (t, pb) in frames { if let idx = keyToIndex[t] { byIndex[idx] = pb } }
        let early = earlyMap.withLock { $0 }
        let delivered = Set(handedOut.compactMap { early[$0] })
        lock.withLock { carry = byIndex.filter { $0.key > range.upperBound } }
        var out: [DecodedFrame] = []
        out.reserveCapacity(range.count)
        for idx in range {
            // Samples the edit list does not show (zero duration, SampleIndex) are decoded for reference only: they
            // share the pts of the frame shown at the cut, so returning them would collide in pts-keyed caches.
            if entries[idx].duration == .zero || delivered.contains(idx) || skipped.contains(idx) { continue }
            if let skipBefore, idx < skipBefore, byIndex[idx] == nil { continue }     // not needed, not decoded
            guard let pb = byIndex[idx] else { lock.withLock { lastOrdinal = nil }; throw MediaError.truncated }
            // Frames carried over stay as decoded (`carry`), so none is deinterlaced twice.
            out.append(DecodedFrame(media: media, pts: entries[idx].pts, duration: entries[idx].duration,
                                    pixelBuffer: Self.finished(pb, fields, scaler)))
        }
        return out
    }
}

/// A reader over samples already in memory (demuxers without a streaming reader).
private final class ArrayReader: SampleReading, @unchecked Sendable {
    private var samples: [CMSampleBuffer]
    private var at = 0
    init(_ samples: [CMSampleBuffer]) { self.samples = samples }
    var count: Int { samples.count - at }
    func next() throws -> CMSampleBuffer {
        guard at < samples.count else { throw MediaError.truncated }
        defer { at += 1 }
        return samples[at]
    }
}

/// Whether VideoToolbox decodes a stream in hardware on this Mac (session on the media engine), cached per codec, size,
/// bit depth and profile bytes. The probe session costs a few ms once per kind of source. A source VT cannot open
/// counts as hardware (no hint; the media fails elsewhere). Feeds AutoProxy's software-decode hint.
public enum HardwareDecode {
    private static let cache = Mutex<[String: Bool]>([:])

    public static func isHardware(_ format: CMFormatDescription) -> Bool {
        let key = cacheKey(format)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        var hw = true
        if VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                        imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s) == noErr, let s {
            var v: CFTypeRef?
            VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &v)
            hw = (v as? Bool) ?? false
            VTDecompressionSessionInvalidate(s)
        }
        cache.withLock { $0[key] = hw }
        return hw
    }

    private static func cacheKey(_ format: CMFormatDescription) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        // avcC / hvcC head: profile, compatibility and level bytes (HEVC: chroma and depth follow within 23 bytes).
        let head = ["avcC", "hvcC"].compactMap { (atoms[$0] as? Data)?.prefix(23).map { String($0, radix: 16) }.joined(separator: ".") }
        let depth = ext[kCMFormatDescriptionExtension_BitsPerComponent as String].map { "\($0)" } ?? "-"
        return "\(CMFormatDescriptionGetMediaSubType(format)) \(d.width)x\(d.height) \(depth) \(head.joined())"
    }
}
