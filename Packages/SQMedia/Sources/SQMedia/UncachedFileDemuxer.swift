import AVFoundation
import CoreMedia
import Darwin

/// Demuxer for files the app writes itself and reads back often (preview render cache segments): sample data is read with
/// `pread` from a descriptor opened with `F_NOCACHE`, so playing or exporting a cached segment does not push source media
/// out of the unified buffer cache (docs/research/editor-architecture/F1-fcp-timeline-speed.md, `FFSegmentStoreUseFNoCache`).
/// Index, format and rotation come from `AVDemuxer`; a file whose samples have no plain byte range in the file itself
/// (reference movies, missing storage info) reads through `AVDemuxer` instead (`usesUncachedReads` is false then).
/// `@unchecked Sendable`: the descriptor and the sample table are immutable after init; `pread` needs no lock.
public final class UncachedFileDemuxer: Demuxing, @unchecked Sendable {
    struct Sample { var offset: Int64; var length: Int; var pts: CMTime; var dts: CMTime; var duration: CMTime; var sync: Bool }

    private let inner: AVDemuxer
    private let fd: Int32
    /// Storage and raw timing per decode ordinal; nil = read through `inner`.
    private let table: [Sample]?

    /// True when samples are read with `F_NOCACHE` (the file has a plain sample table).
    public var usesUncachedReads: Bool { table != nil }
    public var index: SampleIndex { inner.index }
    public var codedIndex: SampleIndex { inner.codedIndex }
    public var formatDescription: CMFormatDescription { inner.formatDescription }
    public var rotation: Int { inner.rotation }

    public init(url: URL) async throws {
        inner = try await AVDemuxer(url: url)
        let d = open(url.path, O_RDONLY | O_CLOEXEC)
        guard d >= 0 else { throw MediaError.unreadable }
        // Reads skip the buffer cache: a cached segment is read once per play, keeping it there only evicts source media.
        _ = fcntl(d, F_NOCACHE, 1)
        fd = d
        let t = await Self.sampleTable(url: url)
        table = t?.count == inner.codedIndex.count ? t : nil
    }

    deinit { close(fd) }

    /// Byte range and raw timing of every sample in decode order, or nil when one is not a plain range of this file.
    private static func sampleTable(url: URL) async -> [Sample]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let c = track.makeSampleCursor(presentationTimeStamp: .zero) ?? track.makeSampleCursor(presentationTimeStamp: .negativeInfinity)
        else { return nil }
        while c.stepInDecodeOrder(byCount: -1) == -1 {}
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [Sample] = []
        repeat {
            if let chunk = c.currentChunkStorageURL, chunk.resolvingSymlinksInPath().standardizedFileURL.path != path { return nil }
            let r = c.currentSampleStorageRange
            guard r.offset >= 0, r.length > 0 else { return nil }
            out.append(Sample(offset: r.offset, length: Int(r.length), pts: c.presentationTimeStamp, dts: c.decodeTimeStamp,
                              duration: c.currentSampleDuration, sync: c.currentSampleSyncInfo.sampleIsFullSync.boolValue))
        } while c.stepInDecodeOrder(byCount: 1) == 1
        return out
    }

    public func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        try await samples(for: range, fromDecodeOrdinal: 0)
    }

    public func samples(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) async throws -> [CMSampleBuffer] {
        guard table != nil else { return try await inner.samples(for: range, fromDecodeOrdinal: fromDecodeOrdinal) }
        guard let reader = try sampleReader(for: range, fromDecodeOrdinal: fromDecodeOrdinal) else { return [] }
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(reader.count)
        while reader.count > 0 {
            try Task.checkCancellation()
            out.append(try reader.next())
        }
        return out
    }

    public func sampleReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> (any SampleReading)? {
        guard let table else { return try inner.sampleReader(for: range, fromDecodeOrdinal: fromDecodeOrdinal) }
        let entries = index.entries
        guard !entries.isEmpty, range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        let sync = index.syncDecodeOrdinal(for: range.lowerBound)
        var end = sync
        for i in range { end = max(end, entries[i].decodeOrdinal) }
        let start = max(sync, fromDecodeOrdinal)
        return Reader(owner: self, table: table, ordinals: start <= end ? Array(start...end) : [])
    }

    private final class Reader: SampleReading {
        let owner: UncachedFileDemuxer
        let table: [Sample]
        var ordinals: ArraySlice<Int>
        init(owner: UncachedFileDemuxer, table: [Sample], ordinals: [Int]) {
            self.owner = owner; self.table = table; self.ordinals = ordinals[...]
        }
        var count: Int { ordinals.count }
        func next() throws -> CMSampleBuffer {
            guard let o = ordinals.first, o < table.count else { throw MediaError.truncated }
            ordinals = ordinals.dropFirst()
            return try owner.buffer(table[o])
        }
    }

    private func buffer(_ s: Sample) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: s.length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: s.length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { throw MediaError.unreadable }
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &ptr) == noErr, let ptr else { throw MediaError.unreadable }
        var got = 0
        while got < s.length {
            let r = pread(fd, ptr + got, s.length - got, off_t(s.offset) + off_t(got))
            if r < 0, errno == EINTR { continue }
            guard r > 0 else { throw MediaError.truncated }
            got += r
        }
        var timing = CMSampleTimingInfo(duration: s.duration, presentationTimeStamp: s.pts, decodeTimeStamp: s.dts)
        var size = s.length
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { throw MediaError.unreadable }
        if !s.sync, let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
