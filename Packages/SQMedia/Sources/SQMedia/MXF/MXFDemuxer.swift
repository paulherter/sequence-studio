import CoreGraphics
import CoreMedia
import Foundation
import SQCore

/// Video of an MXF file as compressed samples: H.264 (Sony XAVC Intra and Long GOP) and ProRes, frame-wrapped.
/// One edit unit is one frame; decode ordinal = edit unit number (stored order).
public final class MXFDemuxer: Demuxing, @unchecked Sendable {
    public let index: SampleIndex
    public let formatDescription: CMFormatDescription
    public let rotation = 0
    public let file: MXFFile
    /// True when every frame is a key frame (XAVC Intra, ProRes).
    public let isIntraOnly: Bool

    private let isH264: Bool
    private let times: [CMSampleTimingInfo]
    private let sync: [Bool]

    public convenience init(url: URL) async throws {
        try self.init(file: try MXFFile.open(url))
    }

    /// What a demuxer derives from the file: built once per parsed file.
    struct Built: @unchecked Sendable {
        var index: SampleIndex
        var formatDescription: CMFormatDescription
        var isIntraOnly: Bool
        var isH264: Bool
        var times: [CMSampleTimingInfo]
        var sync: [Bool]
    }

    public init(file: MXFFile) throws {
        self.file = file
        let b: Built
        if let cached = file.shared.built.withLock({ $0 }) {
            b = cached
        } else {
            b = try Self.build(file)
            file.shared.built.withLock { $0 = b }
            file.shared.indexBuilds.withLock { $0 += 1 }
        }
        index = b.index
        formatDescription = b.formatDescription
        isIntraOnly = b.isIntraOnly
        isH264 = b.isH264
        times = b.times
        sync = b.sync
    }

    private static func build(_ file: MXFFile) throws -> Built {
        let isH264: Bool
        guard let track = file.videoTrack else { throw MediaError.unreadable }
        let count = file.unitCount
        guard count > 0, let first = file.pictureRange(ofUnit: 0) else { throw MediaError.truncated }
        guard let unit = track.editUnit, unit > .zero else { throw MediaError.unreadable }

        // The descriptor names the coding; an MPEG elementary stream container leaves it to the stream.
        var codec = file.videoCodec
        if codec == nil {
            let isAVC = file.bytes.withBytes(first.prefix(4096)) { p in
                H264AnnexB.nals(p, limit: 8).contains { [7, 8, 5].contains(p[$0.lowerBound] & 0x1F) && p[$0.lowerBound] & 0x80 == 0 }
            } ?? false
            codec = isAVC ? .h264 : .unsupported(first.count > 8 ? "unknown video" : "empty video")
        }
        let desc = track.picture
        var format: CMFormatDescription?
        switch codec {
        case .h264:
            isH264 = true
            format = try h264Format(file, descriptor: desc)
        case .prores(let flavor):
            isH264 = false
            format = try proresFormat(file, first: first, flavor: flavor, descriptor: desc)
        case .unsupported(let name):
            throw MediaError.unsupportedCodec("\(name) in MXF")
        case nil:
            throw MediaError.unsupportedCodec("unknown video in MXF")
        }
        guard let format else { throw MediaError.unreadable }

        // Key frames and display order: index table flags and temporal offsets, else (H.264 without them) the stream.
        var display = Array(0..<count)
        var sync = [Bool](repeating: true, count: count)
        // Without usable index entries the stream itself is read; that includes an index whose flags are there but
        // whose temporal offsets do not form a permutation: stored order as display order would shuffle B frames.
        var fromStream = file.flags.count != count
        if file.flags.count == count {
            let hasRandomAccess = file.flags.contains { $0 & 0x80 != 0 }
            for i in 0..<count { sync[i] = hasRandomAccess ? file.flags[i] & 0x80 != 0 : file.flags[i] & 0x30 == 0 }
            // Entry x says: the frame shown at position x is stored at x + offset.
            var shown = [Int](repeating: -1, count: count)
            var valid = true
            for x in 0..<count {
                let stored = x + Int(file.temporalOffsets[x])
                guard stored >= 0, stored < count, shown[stored] < 0 else { valid = false; break }
                shown[stored] = x
            }
            if valid { display = shown } else { fromStream = true }
            if !sync[0] { sync[0] = true }
        }
        if fromStream, isH264, !isIntraLabel(desc?.coding), let scanned = scanH264(file, count: count) {
            sync = scanned.sync; display = scanned.display
        }

        // Decode times run ahead of presentation by the largest reorder distance, so dts <= pts everywhere.
        var delay = 0
        for i in 0..<count { delay = max(delay, i - display[i]) }
        let scale = Int64(track.editRateNum), step = Int64(track.editRateDen)
        var entries: [SampleIndex.Entry] = []
        entries.reserveCapacity(count)
        var times: [CMSampleTimingInfo] = []
        times.reserveCapacity(count)
        for i in 0..<count {
            let pts = Time(Int64(display[i]) * step, scale), dts = Time(Int64(i - delay) * step, scale)
            entries.append(.init(pts: pts, dts: dts, duration: unit, isSync: sync[i], decodeOrdinal: i))
            times.append(CMSampleTimingInfo(duration: unit.cmTime, presentationTimeStamp: pts.cmTime, decodeTimeStamp: dts.cmTime))
        }
        return Built(index: SampleIndex(entries: entries), formatDescription: format, isIntraOnly: !sync.contains(false),
                     isH264: isH264, times: times, sync: sync)
    }

    /// Labels of the intra-only H.264 profiles (RP 2027 classes, `04 01 02 02 01 32`).
    private static func isIntraLabel(_ coding: MXFUL?) -> Bool {
        coding?.matches([0x04, 0x01, 0x02, 0x02, 0x01, 0x32], at: 8) ?? false
    }

    // MARK: format descriptions

    private static func h264Format(_ file: MXFFile, descriptor: MXFPictureDescriptor?) throws -> CMFormatDescription {
        var sets: (sps: [UInt8], pps: [UInt8])?
        for u in 0..<min(file.unitCount, 16) where sets == nil {
            guard let r = file.pictureRange(ofUnit: u) else { continue }
            sets = file.bytes.withBytes(r.prefix(1 << 16)) { H264AnnexB.parameterSets($0) } ?? nil
        }
        guard let sets else { throw MediaError.unsupportedCodec("H.264 without parameter sets in MXF") }
        var fd: CMFormatDescription?
        let st = sets.sps.withUnsafeBufferPointer { s in
            sets.pps.withUnsafeBufferPointer { p in
                var pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                var sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                           parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard st == noErr, let fd else { throw MediaError.unsupportedCodec("H.264 (unreadable parameter sets) in MXF") }
        return withColor(fd, descriptor: descriptor) ?? fd
    }

    private static func proresFormat(_ file: MXFFile, first: Range<Int>, flavor: FourCharCode?,
                                     descriptor: MXFPictureDescriptor?) throws -> CMFormatDescription {
        // Frame: size u32, "icpf", header size u16, version u16, creator u32, width u16, height u16, chroma flags u8.
        let b = file.bytes, o = first.lowerBound
        guard first.count >= 28, b.u32(o + 4) == 0x6963_7066, let w = b.u16(o + 16), let h = b.u16(o + 18), let f = b.u8(o + 20),
              w > 0, h > 0 else { throw MediaError.unsupportedCodec("ProRes (unreadable frame header) in MXF") }
        let code = flavor ?? MXFVideoCodec.code(f >> 6 == 3 ? "ap4h" : "apch")
        var fd: CMFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: code, width: Int32(w), height: Int32(h),
                                                extensions: nil, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw MediaError.decodeFailed(st) }
        return withColor(fd, descriptor: descriptor) ?? fd
    }

    /// Adds the descriptor's color tags where the stream itself did not carry them.
    private static func withColor(_ fd: CMFormatDescription, descriptor d: MXFPictureDescriptor?) -> CMFormatDescription? {
        guard let d else { return nil }
        var ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        var changed = false
        func add(_ key: CFString, _ value: String?) {
            guard let value, ext[key as String] == nil else { return }
            ext[key as String] = value; changed = true
        }
        add(kCMFormatDescriptionExtension_ColorPrimaries, d.primariesTag)
        add(kCMFormatDescriptionExtension_TransferFunction, d.transferTag)
        add(kCMFormatDescriptionExtension_YCbCrMatrix, d.matrixTag)
        guard changed else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        var out: CMFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(fd), width: dims.width,
                                                height: dims.height, extensions: ext as CFDictionary, formatDescriptionOut: &out)
        return st == noErr ? out : nil
    }

    /// Key frames (IDR) and display order from the slice headers: for long GOP files without index entries.
    private static func scanH264(_ file: MXFFile, count: Int) -> (sync: [Bool], display: [Int])? {
        var sps: H264AnnexB.SPS?
        var slices: [H264AnnexB.Slice] = []
        slices.reserveCapacity(count)
        for u in 0..<count {
            guard let r = file.pictureRange(ofUnit: u) else { return nil }
            let slice = file.bytes.withBytes(r.prefix(1 << 14)) { p -> H264AnnexB.Slice? in
                if sps == nil, let sets = H264AnnexB.parameterSets(p) { sps = H264AnnexB.sps(sets.sps) }
                return H264AnnexB.firstSlice(p, sps: sps)
            } ?? nil
            guard let slice else { return nil }
            slices.append(slice)
        }
        var sync = slices.map(\.isIDR)
        if !sync.contains(true) { sync = slices.map { $0.type == 2 } }
        if !sync.isEmpty { sync[0] = true }
        let display = sps.flatMap { $0.pocType == 0 ? H264AnnexB.displayOrder(slices, log2MaxPocLsb: $0.log2MaxPocLsb) : nil }
        return (sync, display ?? Array(0..<count))
    }

    // MARK: samples

    public func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        try await samples(for: range, fromDecodeOrdinal: 0)
    }

    /// Continues a decode: only the samples from `fromDecodeOrdinal` on are read from the file, so forward playback
    /// of long GOP reads every frame once instead of the GOP from its key frame for every batch.
    public func samples(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) async throws -> [CMSampleBuffer] {
        guard range.lowerBound >= 0, range.upperBound < index.count else { throw MediaError.truncated }
        var end = index.syncDecodeOrdinal(for: range.lowerBound)
        let start = max(end, fromDecodeOrdinal)
        for i in range { end = max(end, index.entries[i].decodeOrdinal) }
        guard start <= end else { return [] }
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(end - start + 1)
        for o in start...end {
            try Task.checkCancellation()
            out.append(try sampleBuffer(ordinal: o))
        }
        return out
    }

    /// The frame's bytes as VideoToolbox wants them (H.264: length-prefixed NAL units).
    func payload(ordinal o: Int) throws -> Data {
        guard let r = file.pictureRange(ofUnit: o) else { throw MediaError.truncated }
        if isH264 {
            guard let d = file.bytes.withBytes(r, { H264AnnexB.lengthPrefixed($0) }), !d.isEmpty else { throw MediaError.truncated }
            return d
        }
        guard let d = file.bytes.slice(r), !d.isEmpty else { throw MediaError.truncated }
        return d
    }

    static let maxFrameBytes = 1 << 29

    /// A block buffer of `size` bytes and its memory.
    private static func block(_ size: Int) throws -> (CMBlockBuffer, UnsafeMutableRawPointer) {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: size,
                                                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw MediaError.decodeFailed(st) }
        var p: UnsafeMutablePointer<CChar>?
        st = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &p)
        guard st == noErr, let p else { throw MediaError.decodeFailed(st) }
        return (block, UnsafeMutableRawPointer(p))
    }

    /// The frame goes from the file into the block buffer's own memory: ProRes with one read, H.264 with one read and
    /// the NAL units written length-prefixed into place.
    private func sampleBuffer(ordinal o: Int) throws -> CMSampleBuffer {
        // No frame of any format is this large: a length that says so (last unit, nothing to bound it) is corrupt.
        guard let r = file.pictureRange(ofUnit: o), !r.isEmpty, r.count <= Self.maxFrameBytes else { throw MediaError.truncated }
        let block: CMBlockBuffer
        var size = r.count
        if isH264 {
            let made = try file.bytes.withBytes(r) { p -> (CMBlockBuffer, Int)? in
                let k = H264AnnexB.kept(p)
                guard k.size > 0 else { return nil }
                let (b, dst) = try Self.block(k.size)
                H264AnnexB.write(p, k.ranges, to: dst)
                return (b, k.size)
            } ?? nil
            guard let made else { throw MediaError.truncated }
            (block, size) = made
        } else {
            let (b, dst) = try Self.block(size)
            guard file.bytes.copy(r, to: dst) else { throw MediaError.truncated }
            block = b
        }
        var timing = times[o]
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw MediaError.decodeFailed(st) }
        if !sync[o], let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

/// Stills of an MXF file for thumbnails and the library.
public enum MXFStill {
    public static func cgImage(url: URL, time: CMTime, height: Int, exact: Bool) async throws -> CGImage {
        try await cgImage(try await MXFDemuxer(url: url), time: time, height: height, exact: exact)
    }

    private static func cgImage(_ demux: MXFDemuxer, time: CMTime, height: Int, exact: Bool) async throws -> CGImage {
        let index = demux.index
        let t = Time(time) ?? .zero
        var i = index.frame(at: t) ?? (t < .zero ? 0 : index.count - 1)
        if !exact { i = index.entries[i].isSync ? i : index.previousSync(before: i) }
        let h = Int(CMVideoFormatDescriptionGetDimensions(demux.formatDescription).height)
        let scale: DecodeScale = height > 0 && height * 4 <= h ? .quarter : height > 0 && height * 2 <= h ? .half : .full
        // Interlaced MXF (1080i): the still is deinterlaced like every other frame of it.
        let decoder = try VTVideoDecoder(demuxer: demux, media: UUID(), scale: scale,
                                         deinterlace: demux.file.videoTrack?.picture?.fieldOrder)
        let frames = try await decoder.decode(i...i)
        decoder.invalidate()
        guard let frame = frames.first else { throw MediaError.truncated }
        return try WebMStill.image(frame.pixelBuffer, height: height)
    }

    /// A representative frame (10 % into the clip) for library thumbnails.
    public static func previewImage(url: URL, maxHeight: Int) async throws -> CGImage {
        let demux = try await MXFDemuxer(url: url)
        let d = demux.index.duration
        return try await cgImage(demux, time: Time(d.value, d.timescale * 10).cmTime, height: maxHeight, exact: false)
    }
}
