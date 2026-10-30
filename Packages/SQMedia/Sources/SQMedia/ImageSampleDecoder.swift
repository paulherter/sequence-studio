import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import SQCore

/// Decoder for QuickTime tracks whose every sample is a self-contained still picture (`png ` = "PNG" transparent
/// animation export of After Effects, Blender, Cinema 4D ...). VideoToolbox has no decoder for them (the clip used to
/// come out as the amber "damaged" placeholder), so ImageIO decodes each sample into the same premultiplied BGRA buffer
/// stills use (`StillImage.pixelBuffer`), alpha included. Every sample is a sync sample: no GOP state.
/// FB-L: one PNG frame costs tens of ms on one core, and the engine asks for one frame per job, so the decoder decodes
/// ahead: each request also starts the next `lookahead` frames in the direction and step of the last requests, all in
/// parallel; later requests pick them up (`Slot`). 8-bit RGBA comes straight from ImageIO's bytes (vImage permute +
/// premultiply) instead of a CGContext draw.
public final class ImageSampleDecoder: VideoDecoding, @unchecked Sendable {
    /// Sample entry types decoded here.
    public static let codecs: Set<CMVideoCodecType> = [0x706E_6720]   // 'png '
    static let lookahead = 6
    /// One picture per core at most (a concurrent GCD queue grew a thread per queued block).
    private static let work: OperationQueue = {
        let q = OperationQueue()
        q.name = "sq.png-decode"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return q
    }()

    public let info: VideoTrackInfo
    public var isHardware: Bool { false }
    private let demuxer: any Demuxing
    private let media: UUID
    private let scale: DecodeScale
    private let pool: BGRAPool
    private let lock = NSLock()
    // Guarded by `lock`.
    private var slots: [Int: Task<PixelBox, any Error>] = [:]
    private var last: Int?
    private var step = 1

    public init(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full) throws {
        self.demuxer = demuxer; self.media = media; self.scale = scale
        var i = try MediaImporter.videoInfo(format: demuxer.formatDescription, index: demuxer.index, rotation: demuxer.rotation)
        i.chroma = "4:4:4"; i.bitDepth = 8
        info = i
        let dims = CMVideoFormatDescriptionGetDimensions(demuxer.formatDescription)
        pool = BGRAPool(width: max(1, Int(dims.width)), height: max(1, Int(dims.height)))
    }

    deinit { for t in slots.values { t.cancel() } }

    public static func handles(_ format: CMFormatDescription) -> Bool {
        codecs.contains(CMFormatDescriptionGetMediaSubType(format))
    }

    public func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        guard range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        var out: [DecodedFrame] = []
        for idx in range where entries[idx].duration != .zero {
            try Task.checkCancellation()
            let task = lock.withLock { request(idx, count: entries.count) }
            let pb = try await task.value.pb
            out.append(DecodedFrame(media: media, pts: entries[idx].pts, duration: entries[idx].duration, pixelBuffer: pb))
        }
        return out
    }

    public func invalidate() {}

    /// Under `lock`: the slot of `idx` (started if missing), plus decode-ahead slots along the request direction.
    private func request(_ idx: Int, count: Int) -> Task<PixelBox, any Error> {
        var ahead = Self.lookahead
        if let last {
            let delta = idx - last
            if delta != 0, abs(delta) <= 8 { step = delta } else if delta != 0 { step = delta > 0 ? 1 : -1; ahead = 2 }
        }
        last = idx
        let task = slots.removeValue(forKey: idx) ?? start(idx)
        for k in 1...ahead {
            let j = idx + step * k
            guard j >= 0, j < count else { break }
            if slots[j] == nil { slots[j] = start(j) }
        }
        // Keep only what lies ahead in the current direction.
        let reach = abs(step) * (Self.lookahead + 1)
        for (j, t) in slots where (j - idx) * step.signum() <= 0 || abs(j - idx) > reach {
            t.cancel(); slots[j] = nil
        }
        return task
    }

    private func start(_ idx: Int) -> Task<PixelBox, any Error> {
        let demuxer = demuxer, pool = pool, scale = scale
        return Task.detached(priority: .userInitiated) {
            let samples = try await demuxer.samples(for: idx...idx)
            guard let sb = samples.last else { throw MediaError.truncated }
            try Task.checkCancellation()
            let box = SampleBox(sb), cancelled = CancelFlag()
            // Decode-ahead slots are canceled often (direction change, jump): a queued block that has not started yet
            // returns at once instead of decoding a picture nobody wants.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    Self.work.addOperation {
                        if cancelled.isSet { c.resume(throwing: CancellationError()); return }
                        c.resume(with: Result { PixelBox(pb: try BGRABuffer.scaled(Self.pixelBuffer(of: box.sb, pool: pool), by: scale)) })
                    }
                }
            } onCancel: { cancelled.set() }
        }
    }

    static func pixelBuffer(of sb: CMSampleBuffer, pool: BGRAPool? = nil) throws -> CVPixelBuffer {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { throw MediaError.truncated }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let st = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard st == kCMBlockBufferNoErr else { throw MediaError.decodeFailed(OSStatus(st)) }
        if let pool {
            let pb = try pool.make()
            CVPixelBufferLockBaseAddress(pb, [])
            let ok = data.withUnsafeBytes {
                PNGFastDecoder.decode($0, width: pool.width, height: pool.height, into: CVPixelBufferGetBaseAddress(pb)!,
                                      rowBytes: CVPixelBufferGetBytesPerRow(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if ok { return pb }
        }
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, opts) else { throw MediaError.decodeFailed(OSStatus(st)) }
        if let pool, let pb = try fastPath(image, pool: pool) { return pb }
        return try StillImage.pixelBuffer(from: image)
    }

    /// 8-bit RGBA / RGBX in sRGB (or untagged RGB): permute the decoded bytes to BGRA and premultiply, no CGContext draw.
    /// nil = not that layout (16-bit, gray, palette expanded otherwise, other color space): the CGContext path converts.
    static func fastPath(_ image: CGImage, pool: BGRAPool) throws -> CVPixelBuffer? {
        guard image.width == pool.width, image.height == pool.height, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let cs = image.colorSpace, cs.model == .rgb,
              // A color-managed picture (ICC profile, e.g. Adobe RGB) can come with any or no name: only sRGB, device RGB
              // and a truly untagged space (no profile data) are taken as sRGB bytes.
              cs.name == CGColorSpace.sRGB || cs.name as String? == "kCGColorSpaceDeviceRGB" || (cs.name == nil && cs.copyICCData() == nil),
              image.bitmapInfo.intersection(.byteOrderMask) == [] || image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Big,
              image.bitmapInfo.contains(.floatComponents) == false
        else { return nil }
        let alpha = image.alphaInfo
        guard [.last, .premultipliedLast, .noneSkipLast].contains(alpha), let cf = image.dataProvider?.data, let bytes = CFDataGetBytePtr(cf)
        else { return nil }
        let pb = try pool.make()
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(image.height),
                                width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(image.height),
                                width: vImagePixelCount(image.width), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let map: [UInt8] = [2, 1, 0, 3]   // RGBA -> BGRA
        guard vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        switch alpha {
        case .last: guard vImagePremultiplyData_RGBA8888(&dst, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        case .noneSkipLast: guard vImageOverwriteChannelsWithScalar_ARGB8888(255, &dst, &dst, 0x1, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        default: break
        }
        return pb
    }
}

/// CMSampleBuffer handed to the decode queue (read only there).
private struct SampleBox: @unchecked Sendable { let sb: CMSampleBuffer; init(_ sb: CMSampleBuffer) { self.sb = sb } }
/// Decoded picture of a decode-ahead slot (written once on the decode queue, then only read).
private struct PixelBox: @unchecked Sendable { let pb: CVPixelBuffer }
/// Set by a slot task's cancellation, read by its queued decode block.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Picks the decoder for a demuxed video track: ImageIO for still-picture codecs VideoToolbox lacks, VideoToolbox
/// otherwise. QuickTime Animation ('rle ') always uses `RLEDecoder` (FB-L: `AVDemuxer` presents every rle frame as random
/// access, which only this decoder honors); depths it cannot read go to VideoToolbox.
/// `deinterlace`: field order of an interlaced source to deinterlace right after decode (`VideoTrackInfo.
/// deinterlaceFieldOrder` of the media item; nil for progressive media, proxies and a switched-off item).
public func makeVideoDecoder(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full,
                             deinterlace: FieldOrder? = nil) throws -> any VideoDecoding {
    if ImageSampleDecoder.handles(demuxer.formatDescription) { return try ImageSampleDecoder(demuxer: demuxer, media: media, scale: scale) }
    if RLEDecoder.supports(demuxer.formatDescription) { return try RLEDecoder(demuxer: demuxer, media: media, scale: scale) }
    return try VTVideoDecoder(demuxer: demuxer, media: media, scale: scale, deinterlace: deinterlace)
}
