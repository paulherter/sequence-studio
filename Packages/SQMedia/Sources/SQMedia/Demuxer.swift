import AVFoundation
import CoreMedia
import SQCore

/// Clockwise rotation in degrees (0/90/180/270) of a track's preferred transform; other angles snap to the nearest quarter turn.
public func quarterTurnRotation(of t: CGAffineTransform) -> Int {
    let deg = atan2(Double(t.b), Double(t.a)) * 180 / .pi
    let q = Int((deg / 90).rounded())
    return ((q % 4) + 4) % 4 * 90
}

extension Time {
    init?(_ t: CMTime) {
        guard t.isNumeric, t.timescale > 0 else { return nil }
        self.init(t.value, Int64(t.timescale))
    }
    var cmTime: CMTime { CMTime(value: value, timescale: CMTimeScale(truncatingIfNeeded: timescale)) }
}

/// A track's edit list as media -> presentation mapping. Only 100 %-rate segments are mapped; a track with a scaled
/// segment (iPhone slow motion) or without segments gets nil and keeps plain media time (start offset removed later).
struct EditList: Sendable {
    struct Segment: Sendable { var source: TimeRange, target: Time }
    /// Non-empty segments in presentation order.
    let segments: [Segment]

    init?(segments raw: [AVAssetTrackSegment]) {
        var s: [Segment] = []
        for seg in raw where !seg.isEmpty {
            let m = seg.timeMapping
            guard let ss = Time(m.source.start), let sd = Time(m.source.duration), let ts = Time(m.target.start),
                  let td = Time(m.target.duration), sd == td, sd > .zero else { return nil }
            s.append(Segment(source: TimeRange(start: ss, duration: sd), target: ts))
        }
        guard !s.isEmpty else { return nil }
        segments = s.sorted { $0.target < $1.target }
    }

    init(_ segments: [Segment]) { self.segments = segments.sorted { $0.target < $1.target } }

    /// Presentation pts and duration of a sample at media time `pts`. A sample no segment shows gets duration 0 and
    /// the pts of the cut it fell into (start of the next shown media, or the end of the last segment).
    func present(pts p: Time, duration du: Time) -> (Time, Time) {
        let end = p + du
        for s in segments where s.source.start < end && p < s.source.end {
            let a = max(p, s.source.start), b = min(end, s.source.end)
            return (s.target + (a - s.source.start), b - a)
        }
        if let next = segments.filter({ $0.source.start >= end }).min(by: { $0.source.start < $1.source.start }) {
            return (next.target, .zero)
        }
        let last = segments.max { $0.target + $0.source.duration < $1.target + $1.source.duration }!
        return (last.target + last.source.duration, .zero)
    }
}

/// AVSampleCursor based demuxer for the first video track of a file.
/// `@unchecked Sendable`: the AVFoundation objects are only read; each call makes its own cursor and generator.
public final class AVDemuxer: Demuxing, @unchecked Sendable {
    public let index: SampleIndex
    public let codedIndex: SampleIndex
    public let formatDescription: CMFormatDescription
    public let rotation: Int
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    /// Raw pts of the first presented frame (subtracted to build `index`).
    private let origin: CMTime
    /// Raw pts per decode ordinal, for seeking the cursor.
    private let rawPTSByOrdinal: [CMTime]

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unreadable }
        guard let fd = try? await track.load(.formatDescriptions).first else { throw MediaError.unreadable }
        guard let first = track.makeSampleCursor(presentationTimeStamp: .zero) ?? track.makeSampleCursor(presentationTimeStamp: .negativeInfinity)
        else { throw MediaError.unreadable }
        // Rewind to the very first sample in decode order, then walk forward.
        while first.stepInDecodeOrder(byCount: -1) == -1 {}
        var raw: [(pts: CMTime, dts: CMTime, dur: CMTime, sync: Bool)] = []
        repeat {
            raw.append((first.presentationTimeStamp, first.decodeTimeStamp, first.currentSampleDuration,
                        first.currentSampleSyncInfo.sampleIsFullSync.boolValue))
        } while first.stepInDecodeOrder(byCount: 1) == 1
        guard !raw.isEmpty else { throw MediaError.unreadable }

        var origin = raw[0].pts
        for r in raw where CMTimeCompare(r.pts, origin) < 0 { origin = r.pts }
        // The cursor reports media time; the edit list says which media is shown when (macOS screen recordings cut
        // pieces out). Audio comes from AVAssetReader, which follows the edit list, so video must too.
        let edits = EditList(segments: (try? await track.load(.segments)) ?? [])
        var entries: [SampleIndex.Entry] = []
        entries.reserveCapacity(raw.count)
        for (i, r) in raw.enumerated() {
            guard var p = Time(r.pts), var d = Time(r.dts), var du = Time(r.dur) else { throw MediaError.unreadable }
            if let edits {
                let (pp, dd) = edits.present(pts: p, duration: du)
                d = d + (pp - p); p = pp; du = dd
            }
            entries.append(.init(pts: p, dts: d, duration: du, isSync: r.sync, decodeOrdinal: i))
        }
        // Samples cut out after the last shown frame move onto it (they sort before it), so every hidden entry is
        // followed by a shown one and clamping to the last entry still lands on a shown frame.
        if let lastShown = entries.filter({ $0.duration > .zero }).map(\.pts).max() {
            for i in entries.indices where entries[i].duration == .zero && entries[i].pts > lastShown {
                entries[i].dts = entries[i].dts - (entries[i].pts - lastShown); entries[i].pts = lastShown
            }
        }
        let coded = SampleIndex(entries: entries)
        self.codedIndex = coded
        // QuickTime Animation: often one key frame for the whole clip. The engine plans whole GOPs (a job would decode
        // and cache the entire clip), so every frame is presented as random access; `RLEDecoder` restores the delta chain
        // from its canvas, a checkpoint or the true key frame (`codedIndex`).
        if RLEDecoder.supports(fd) {
            self.index = SampleIndex(entries: entries.map { var e = $0; e.isSync = true; return e })
        } else {
            self.index = coded
        }
        self.formatDescription = fd
        self.rotation = quarterTurnRotation(of: (try? await track.load(.preferredTransform)) ?? .identity)
        self.asset = asset; self.track = track; self.origin = origin
        self.rawPTSByOrdinal = raw.map(\.pts)
    }

    public func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        try await samples(for: range, fromDecodeOrdinal: 0)
    }

    /// Reads only from `fromDecodeOrdinal` on: the cursor steps over the samples before it (no data loaded), so a
    /// frame-by-frame export no longer re-reads its GOP from the sync sample for every frame.
    public func samples(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) async throws -> [CMSampleBuffer] {
        guard let reader = try makeReader(for: range, fromDecodeOrdinal: fromDecodeOrdinal) else { return [] }
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(reader.count)
        while reader.count > 0 {
            try Task.checkCancellation()
            out.append(try reader.next())
        }
        return out
    }

    public func sampleReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> (any SampleReading)? {
        if let r = try makeReader(for: range, fromDecodeOrdinal: fromDecodeOrdinal) { return r }
        return EmptyReader()
    }

    private final class EmptyReader: SampleReading {
        var count: Int { 0 }
        func next() throws -> CMSampleBuffer { throw MediaError.truncated }
    }

    private final class Reader: SampleReading {
        let generator: AVSampleBufferGenerator
        let cursor: AVSampleCursor
        private(set) var count: Int
        init(generator: AVSampleBufferGenerator, cursor: AVSampleCursor, count: Int) {
            self.generator = generator; self.cursor = cursor; self.count = count
        }
        func next() throws -> CMSampleBuffer {
            guard count > 0 else { throw MediaError.truncated }
            let req = AVSampleBufferRequest(start: cursor)
            req.direction = .forward; req.maxSampleCount = 1
            guard let sb = try? generator.createSampleBuffer(for: req) else { throw MediaError.truncated }
            count -= 1
            if count > 0, cursor.stepInDecodeOrder(byCount: 1) != 1 { throw MediaError.truncated }
            return sb
        }
    }

    private func makeReader(for range: ClosedRange<Int>, fromDecodeOrdinal: Int) throws -> Reader? {
        let entries = index.entries
        guard !entries.isEmpty, range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        let syncOrdinal = index.syncDecodeOrdinal(for: range.lowerBound)
        var endOrdinal = syncOrdinal
        for i in range { endOrdinal = max(endOrdinal, entries[i].decodeOrdinal) }
        let startOrdinal = max(syncOrdinal, fromDecodeOrdinal)
        guard startOrdinal <= endOrdinal else { return nil }

        guard let cursor = track.makeSampleCursor(presentationTimeStamp: rawPTSByOrdinal[syncOrdinal]) else { throw MediaError.unreadable }
        if startOrdinal > syncOrdinal, cursor.stepInDecodeOrder(byCount: Int64(startOrdinal - syncOrdinal)) != Int64(startOrdinal - syncOrdinal) {
            throw MediaError.truncated
        }
        return Reader(generator: AVSampleBufferGenerator(asset: asset, timebase: nil), cursor: cursor, count: endOrdinal - startOrdinal + 1)
    }
}
