import SQCore
#if canImport(CoreMedia)
import CoreMedia

/// Compressed sample a `Demuxing` hands to its decoder. On the Mac a CoreMedia sample buffer (VideoToolbox decodes it).
public typealias DemuxedSample = CMSampleBuffer
/// Stream format of a `Demuxing`. On the Mac a CoreMedia format description.
public typealias DemuxedFormat = CMFormatDescription
#else
/// Compressed sample (one access unit, decode order) where CoreMedia is missing (Windows): the bytes plus timing.
public struct DemuxedSample: Sendable {
    public var data: [UInt8]
    public var pts: Time, dts: Time, duration: Time
    public var isSync: Bool
    public init(data: [UInt8], pts: Time, dts: Time, duration: Time, isSync: Bool) {
        self.data = data; self.pts = pts; self.dts = dts; self.duration = duration; self.isSync = isSync
    }
}

/// Stream format where CoreMedia is missing (Windows): codec name (FFmpeg's, e.g. "h264", "hevc"), coded size and the
/// codec configuration record (avcC / hvcC payload, FFmpeg "extradata").
public struct DemuxedFormat: Sendable, Hashable {
    public var codec: String
    public var width: Int, height: Int
    public var extradata: [UInt8]
    public init(codec: String, width: Int, height: Int, extradata: [UInt8] = []) {
        self.codec = codec; self.width = width; self.height = height; self.extradata = extradata
    }
}
#endif

public protocol Demuxing: Sendable {
    var index: SampleIndex { get }
    /// The stream's own sync flags. `index` may present more frames as sync than the codec has (QuickTime Animation:
    /// every frame is random access, its decoder restores state itself); decoders that rebuild state from the real key
    /// frames read this. Default: `index`.
    var codedIndex: SampleIndex { get }
    var formatDescription: DemuxedFormat { get }
    /// Clockwise quarter turns (0, 90, 180, 270 degrees) the decoded picture needs to be upright (track preferred transform).
    var rotation: Int { get }
    /// Compressed samples needed to decode presentation frames `range`, in decode order (from the GOP's sync sample).
    func samples(for range: ClosedRange<Int>) async throws -> [DemuxedSample]
    /// The samples of `samples(for: range)` from decode ordinal `fromDecodeOrdinal` on (a decoder continuing a GOP
    /// already submitted the ones before it). Default: reads the whole run and drops the head.
    func samples(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) async throws -> [DemuxedSample]
    /// A streaming reader for the same samples as `samples(for:fromDecodeOrdinal:)`; nil = the demuxer only reads whole runs.
    func sampleReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> (any SampleReading)?
}

/// Compressed samples of one decode run, read one at a time in decode order (synchronous, blocking file reads), so a
/// decoder can submit the first sample while the rest are still being read (PLAYBACK-PERF "Seek: exact frame sooner").
public protocol SampleReading: AnyObject {
    /// Samples left to read.
    var count: Int { get }
    /// The next sample (decode order). Throws when the file ends early.
    func next() throws -> DemuxedSample
}

public extension Demuxing {
    func sampleReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> (any SampleReading)? { nil }
    var rotation: Int { 0 }
    var codedIndex: SampleIndex { index }

    func samples(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) async throws -> [DemuxedSample] {
        let all = try await samples(for: range)
        let skip = fromDecodeOrdinal - index.syncDecodeOrdinal(for: range.lowerBound)
        return skip > 0 ? Array(all.dropFirst(skip)) : all
    }
}
