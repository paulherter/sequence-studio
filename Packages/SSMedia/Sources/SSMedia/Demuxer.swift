import AVFoundation
import CoreMedia
import SSCore

public protocol Demuxing: Sendable {
    var index: SampleIndex { get }
    var formatDescription: CMFormatDescription { get }
    /// Compressed samples needed to decode presentation frames `range`, in decode order (from the GOP's sync sample).
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer]
}

extension Time {
    init?(_ t: CMTime) {
        guard t.isNumeric, t.timescale > 0 else { return nil }
        self.init(t.value, Int64(t.timescale))
    }
    var cmTime: CMTime { CMTime(value: value, timescale: CMTimeScale(truncatingIfNeeded: timescale)) }
}

/// AVSampleCursor based demuxer for the first video track of a file.
/// `@unchecked Sendable`: the AVFoundation objects are only read; each call makes its own cursor and generator.
public final class AVDemuxer: Demuxing, @unchecked Sendable {
    public let index: SampleIndex
    public let formatDescription: CMFormatDescription
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
        var entries: [SampleIndex.Entry] = []
        entries.reserveCapacity(raw.count)
        for (i, r) in raw.enumerated() {
            guard let p = Time(r.pts), let d = Time(r.dts), let du = Time(r.dur) else { throw MediaError.unreadable }
            entries.append(.init(pts: p, dts: d, duration: du, isSync: r.sync, decodeOrdinal: i))
        }
        self.index = SampleIndex(entries: entries)
        self.formatDescription = fd
        self.asset = asset; self.track = track; self.origin = origin
        self.rawPTSByOrdinal = raw.map(\.pts)
    }

    public func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        let entries = index.entries
        guard !entries.isEmpty, range.lowerBound >= 0, range.upperBound < entries.count else { throw MediaError.truncated }
        let startOrdinal = index.syncDecodeOrdinal(for: range.lowerBound)
        var endOrdinal = startOrdinal
        for i in range { endOrdinal = max(endOrdinal, entries[i].decodeOrdinal) }

        guard let cursor = track.makeSampleCursor(presentationTimeStamp: rawPTSByOrdinal[startOrdinal]) else { throw MediaError.unreadable }
        // Duplicate pts or B-frame pts may land on another sample: walk to the exact decode position.
        let here = entries.first { $0.decodeOrdinal == startOrdinal }
        _ = here
        let generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(endOrdinal - startOrdinal + 1)
        for ordinal in startOrdinal...endOrdinal {
            try Task.checkCancellation()
            let req = AVSampleBufferRequest(start: cursor)
            req.direction = .forward; req.maxSampleCount = 1
            guard let sb = try? generator.createSampleBuffer(for: req) else { throw MediaError.truncated }
            out.append(sb)
            if ordinal < endOrdinal, cursor.stepInDecodeOrder(byCount: 1) != 1 { throw MediaError.truncated }
        }
        return out
    }
}
