import CSQFFmpeg
import Foundation
import SQCore
import SQMedia
import SQMediaFFmpegCore

/// `Demuxing` over FFmpeg (any container FFmpeg reads): the best video stream, indexed once at open.
public final class FFmpegDemuxer: Demuxing, @unchecked Sendable {
    let handle: OpaquePointer
    public let index: SampleIndex
    public let formatDescription: DemuxedFormat
    public let rotation: Int
    public let table: FFmpegFrameTable
    let raw: SQFFVideoInfo
    private let sizes: [Int]

    public init(url: URL) throws {
        var h: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        let r = url.withUnsafeFileSystemRepresentation { sq_demux_open($0, &h, &err, Int32(err.count)) }
        guard r == 0, let h else { throw FFmpegError.from("open \(url.lastPathComponent)", r, err) }
        handle = h
        var info = SQFFVideoInfo()
        sq_demux_info(h, &info)
        raw = info
        let n = Int(sq_demux_packet_count(h))
        let p = sq_demux_packets(h)
        var packets: [FFmpegPacketTiming] = []
        var sizes: [Int] = []
        packets.reserveCapacity(n); sizes.reserveCapacity(n)
        for i in 0..<n {
            let x = p![i]
            packets.append(FFmpegPacketTiming(pts: x.pts, dts: x.dts, duration: x.duration, isKey: x.key != 0))
            sizes.append(Int(x.size))
        }
        self.sizes = sizes
        table = FFmpegFrameTable(packets: packets, timeBase: FFmpegTimeBase(num: Int64(info.tbNum), den: Int64(info.tbDen)))
        index = table.index
        rotation = Int(info.rotation)
        var extraSize: Int32 = 0
        let extra = sq_demux_extradata(h, &extraSize)
        let extradata = extra.map { Array(UnsafeBufferPointer(start: $0, count: Int(extraSize))) } ?? []
        formatDescription = DemuxedFormat(codec: Self.string(info.codec), width: Int(info.width), height: Int(info.height),
                                          extradata: extradata)
    }

    deinit { sq_demux_close(handle) }

    /// Track facts in the engine's terms (codec as the FFmpeg name, Rec. tags as FFmpeg's names).
    public var trackInfo: VideoTrackInfo {
        let frameDuration: Time
        if raw.frNum > 0, raw.frDen > 0 { frameDuration = Time(Int64(raw.frDen), Int64(raw.frNum)) }
        else { frameDuration = index.entries.first?.duration ?? Time(1, 30) }
        let durations = Set(index.entries.map(\.duration).filter { $0 > .zero })
        let pix = Self.string(raw.pixFmt)
        let chroma = pix.contains("444") ? "4:4:4" : pix.contains("422") ? "4:2:2" : "4:2:0"
        return VideoTrackInfo(width: Int(raw.width), height: Int(raw.height), codec: formatDescription.codec,
                              bitDepth: Int(raw.bitDepth), chroma: chroma, nominalFrameDuration: frameDuration,
                              isVariableFrameRate: durations.count > 1, rotation: rotation)
    }

    public func samples(for range: ClosedRange<Int>) async throws -> [DemuxedSample] {
        let reader = try ordinalReader(from: index.syncDecodeOrdinal(for: range.lowerBound),
                                       through: lastOrdinal(for: range))
        return try (0..<reader.count).map { _ in try reader.next() }
    }

    public func sampleReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> (any SampleReading)? {
        try ordinalReader(from: fromDecodeOrdinal, through: lastOrdinal(for: range))
    }

    /// Highest decode ordinal among the frames of `range`.
    func lastOrdinal(for range: ClosedRange<Int>) -> Int {
        range.map { index.entries[$0].decodeOrdinal }.max() ?? 0
    }

    /// Reads samples `from...through` in decode order.
    func ordinalReader(from: Int, through: Int) throws -> OrdinalReader { OrdinalReader(demuxer: self, from: from, through: through) }

    /// The sample at decode ordinal `ordinal`.
    func sample(ordinal: Int) throws -> DemuxedSample {
        let size = sizes[ordinal]
        var data = [UInt8](repeating: 0, count: size)
        let r = data.withUnsafeMutableBufferPointer { sq_demux_read(handle, Int32(ordinal), $0.baseAddress, Int32(size)) }
        guard r == 0 else { throw FFmpegError.failed("read sample \(ordinal)", r) }
        let p = sq_demux_packets(handle)![ordinal]
        let tb = table.timeBase, o = table.originTicks
        return DemuxedSample(data: data, pts: tb.time(ticks: p.pts - o), dts: tb.time(ticks: p.dts - o),
                             duration: tb.time(ticks: max(0, p.duration)), isSync: p.key != 0)
    }

    var packetCount: Int { sizes.count }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { b in String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
    }

    final class OrdinalReader: SampleReading {
        let demuxer: FFmpegDemuxer
        private var next_: Int
        private let last: Int
        init(demuxer: FFmpegDemuxer, from: Int, through: Int) {
            self.demuxer = demuxer; next_ = from; last = min(through, demuxer.packetCount - 1)
        }
        var count: Int { max(0, last - next_ + 1) }
        func next() throws -> DemuxedSample {
            guard next_ <= last else { throw FFmpegError.message("sample reader ran past its range") }
            defer { next_ += 1 }
            return try demuxer.sample(ordinal: next_)
        }
    }
}
