import CoreMedia
import Foundation
import SQCore
import VideoToolbox

/// Demuxer for the first video track of a Matroska / WebM file. AVFoundation cannot open these files; frames are
/// handed to VideoToolbox as they are (VP9, AV1). VP8 and other codecs have no system decoder: opening throws
/// `MediaError.unsupportedCodec` with the codec name.
public final class WebMDemuxer: Demuxing, @unchecked Sendable {
    public let index: SampleIndex
    public let formatDescription: CMFormatDescription
    public let rotation = 0
    private let file: WebMFile
    /// Video blocks by decode ordinal.
    private let frames: [WebMBlock]
    private let times: [CMTime]

    /// Registers the system's VP9 decoder (Apple ships it as a supplemental decoder; the call is a no-op where absent).
    public static func registerDecoders() {
        _ = registered
    }
    private static let registered: Bool = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        return true
    }()

    /// Readable name of a Matroska codec ID for messages ("V_VP8" -> "VP8").
    public static func codecName(_ id: String) -> String {
        id.hasPrefix("V_") || id.hasPrefix("A_") ? String(id.dropFirst(2)) : id
    }

    public convenience init(url: URL) async throws { try self.init(file: WebMFile.open(url)) }

    public init(file: WebMFile) throws {
        guard let track = file.track(.video) else { throw MediaError.unreadable }
        guard !track.hasContentEncoding else { throw MediaError.unsupportedCodec("compressed " + Self.codecName(track.codecID)) }
        let reordered = track.codecID == Self.avcID || track.codecID == Self.hevcID
        guard track.codecID == "V_VP9" || track.codecID == "V_AV1" || reordered else {
            throw MediaError.unsupportedCodec(Self.codecName(track.codecID))
        }
        Self.registerDecoders()
        var blocks = file.blocks(of: track.number)
        // Decoding starts at a key frame.
        if let k = blocks.firstIndex(where: \.isKey) { blocks.removeFirst(k) } else { throw MediaError.unreadable }
        // H.264 / HEVC keep the file (decode) order: Matroska stores only presentation times, so the B-frame
        // reordering is recovered from it (dts below). VP9 / AV1 are presented in the order they are decoded.
        if !reordered {
            blocks = blocks.enumerated().sorted { ($0.element.ticks, $0.offset) < ($1.element.ticks, $1.offset) }.map(\.element)
        }
        guard !blocks.isEmpty else { throw MediaError.unreadable }

        let fd = try Self.makeFormat(track: track, first: file.payload(blocks[0]))
        var entries: [SampleIndex.Entry] = []
        entries.reserveCapacity(blocks.count)
        let fallback = track.defaultDuration > 0 ? Time(track.defaultDuration, 1_000_000_000) : nil
        // Presentation order of the decode ordinals (identity for VP9 / AV1).
        let byPts = blocks.indices.sorted { (blocks[$0].ticks, $0) < (blocks[$1].ticks, $1) }
        var next = [Int?](repeating: nil, count: blocks.count)   // ordinal -> following ordinal in presentation order
        for k in 0..<byPts.count - 1 { next[byPts[k]] = byPts[k + 1] }
        // Matroska has no decode times. The i-th smallest pts is a monotonic decode time, moved back by the largest
        // amount it overtakes a pts (the reorder delay) so that dts <= pts holds for every frame.
        var delay = Time.zero
        if reordered {
            for i in blocks.indices { delay = max(delay, file.time(blocks[byPts[i]].ticks) - file.time(blocks[i].ticks)) }
        }
        var dtsTimes: [Time] = []
        for (i, b) in blocks.enumerated() {
            let pts = file.time(b.ticks)
            var dur: Time?
            if let n = next[i], blocks[n].ticks > b.ticks { dur = file.time(blocks[n].ticks - b.ticks) }
            else if let d = b.durationTicks, d > 0 { dur = file.time(d) }
            else if let fallback { dur = fallback }
            else if i > 0 { dur = entries[i - 1].duration }
            let dts = reordered ? file.time(blocks[byPts[i]].ticks) - delay : pts
            dtsTimes.append(dts)
            entries.append(.init(pts: pts, dts: dts, duration: dur ?? Time(1, 30), isSync: b.isKey, decodeOrdinal: i))
        }
        index = SampleIndex(entries: entries)
        formatDescription = fd
        self.file = file
        frames = blocks
        times = blocks.map { file.time($0.ticks).cmTime }
        decodeTimes = dtsTimes.map(\.cmTime)
    }

    static let avcID = "V_MPEG4/ISO/AVC", hevcID = "V_MPEGH/ISO/HEVC"
    private let decodeTimes: [CMTime]

    static func makeFormat(track: WebMTrack, first: Data) throws -> CMFormatDescription {
        var width = track.width, height = track.height
        var ext: [String: Any] = [:]
        var atoms: [String: Data] = [:]
        var primaries = track.primaries, transfer = track.transfer, matrix = track.matrix
        var fullRange = track.range == 2
        var depth = track.bitsPerChannel
        let codec: CMVideoCodecType
        if track.codecID == "V_VP9" {
            codec = kCMVideoCodecType_VP9
            guard let kf = VP9KeyFrameInfo.parse(first) else { throw MediaError.unreadable }
            if width == 0 || height == 0 { width = kf.width; height = kf.height }
            depth = kf.bitDepth
            if track.range == nil { fullRange = kf.fullRange }
            // VP9 color_space: 1 BT.601, 2 BT.709, 3 SMPTE-170, 4 SMPTE-240, 5 BT.2020, 7 sRGB.
            if matrix == nil { matrix = [1: 5, 2: 1, 3: 6, 4: 7, 5: 9, 7: 0][kf.colorSpace] }
            if primaries == nil { primaries = [1: 5, 2: 1, 3: 6, 4: 7, 5: 9, 7: 1][kf.colorSpace] }
            if transfer == nil { transfer = [1: 6, 2: 1, 3: 6, 4: 7, 5: 14, 7: 13][kf.colorSpace] }
            atoms["vpcC"] = kf.vpcC(primaries: primaries ?? 2, transfer: transfer ?? 2, matrix: matrix ?? 2)
        } else if track.codecID == Self.avcID || track.codecID == Self.hevcID {
            let avc = track.codecID == Self.avcID
            // Configuration record: avcC needs 7 bytes + SPS/PPS, hvcC 23 bytes; version byte is 1 for both.
            guard track.codecPrivate.count >= (avc ? 7 : 23), track.codecPrivate.first == 1 else { throw MediaError.unreadable }
            codec = avc ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
            atoms[avc ? "avcC" : "hvcC"] = track.codecPrivate
            depth = nil
        } else {
            codec = kCMVideoCodecType_AV1
            guard !track.codecPrivate.isEmpty else { throw MediaError.unreadable }
            atoms["av1C"] = track.codecPrivate
        }
        guard width > 0, height > 0 else { throw MediaError.unreadable }
        ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
        ext[kCMFormatDescriptionExtension_FullRangeVideo as String] = fullRange
        if let depth { ext[kCMFormatDescriptionExtension_BitsPerComponent as String] = depth }
        if let p = primaries, let s = Self.primariesName[p] { ext[kCMFormatDescriptionExtension_ColorPrimaries as String] = s }
        if let t = transfer, let s = Self.transferName[t] { ext[kCMFormatDescriptionExtension_TransferFunction as String] = s }
        if let m = matrix, let s = Self.matrixName[m] { ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] = s }
        var fd: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(width), height: Int32(height),
                                                extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw MediaError.decodeFailed(st) }
        return fd
    }

    // ITU-T H.273 code points (also what Matroska stores) -> CoreMedia names.
    static let primariesName: [Int: String] = [
        1: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, 5: kCMFormatDescriptionColorPrimaries_EBU_3213 as String,
        6: kCMFormatDescriptionColorPrimaries_SMPTE_C as String, 7: kCMFormatDescriptionColorPrimaries_SMPTE_C as String,
        9: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String, 12: kCMFormatDescriptionColorPrimaries_P3_D65 as String,
    ]
    static let transferName: [Int: String] = [
        1: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, 6: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        7: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String, 8: kCMFormatDescriptionTransferFunction_Linear as String,
        13: kCMFormatDescriptionTransferFunction_sRGB as String, 14: kCMFormatDescriptionTransferFunction_ITU_R_2020 as String,
        15: kCMFormatDescriptionTransferFunction_ITU_R_2020 as String,
        16: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
        18: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
    ]
    static let matrixName: [Int: String] = [
        1: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String, 5: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String,
        6: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String, 7: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String,
        9: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
    ]

    public func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        let entries = index.entries
        guard !entries.isEmpty, range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        let start = index.syncDecodeOrdinal(for: range.lowerBound)
        var end = start
        for i in range { end = max(end, entries[i].decodeOrdinal) }
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(end - start + 1)
        for o in start...end {
            try Task.checkCancellation()
            out.append(try sampleBuffer(ordinal: o))
        }
        return out
    }

    private func sampleBuffer(ordinal o: Int) throws -> CMSampleBuffer {
        let b = frames[o]
        let payload = file.payload(b)
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw MediaError.decodeFailed(st) }
        st = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        guard st == noErr else { throw MediaError.decodeFailed(st) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: times[o], decodeTimeStamp: decodeTimes[o])
        var size = payload.count
        var sb: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw MediaError.decodeFailed(st) }
        if !b.isKey, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
