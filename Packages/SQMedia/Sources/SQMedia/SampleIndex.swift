import SQCore

/// Presentation-ordered frame table of one video track. Pure value, built once per media.
public struct SampleIndex: Sendable {
    public struct Entry: Sendable, Hashable {
        public var pts: Time, dts: Time, duration: Time, isSync: Bool, decodeOrdinal: Int
        public init(pts: Time, dts: Time, duration: Time, isSync: Bool, decodeOrdinal: Int) {
            self.pts = pts; self.dts = dts; self.duration = duration; self.isSync = isSync; self.decodeOrdinal = decodeOrdinal
        }
    }

    /// Sorted by pts; pts 0 = first presented frame (edit-list / start offset removed).
    public let entries: [Entry]
    /// decodeOrdinal -> presentation index.
    private let presentationIndexOfOrdinal: [Int]
    /// Decode ordinals of sync samples, ascending.
    private let syncOrdinals: [Int]

    /// `entries` may come in any order; pts and dts are shifted so the smallest pts becomes 0.
    /// `decodeOrdinal`s must be the contiguous range 0..<count.
    public init(entries raw: [Entry]) {
        let origin = raw.map(\.pts).min() ?? .zero
        var e = raw.map { var x = $0; x.pts = x.pts - origin; x.dts = x.dts - origin; return x }
        e.sort { $0.pts != $1.pts ? $0.pts < $1.pts : $0.decodeOrdinal < $1.decodeOrdinal }
        entries = e
        var inv = [Int](repeating: 0, count: e.count)
        for (i, x) in e.enumerated() where x.decodeOrdinal >= 0 && x.decodeOrdinal < e.count { inv[x.decodeOrdinal] = i }
        presentationIndexOfOrdinal = inv
        syncOrdinals = e.filter(\.isSync).map(\.decodeOrdinal).sorted()
    }

    public var count: Int { entries.count }
    /// End of the last frame.
    public var duration: Time { entries.map { $0.pts + $0.duration }.max() ?? .zero }

    /// Index of the frame with pts <= t < next pts (VFR-safe); nil before the first frame or at/after the end.
    public func frame(at t: Time) -> Int? {
        guard let last = entries.last, t >= .zero else { return nil }
        if t >= last.pts + last.duration { return nil }
        var lo = 0, hi = entries.count      // first index with pts > t
        while lo < hi { let m = (lo + hi) / 2; if entries[m].pts > t { hi = m } else { lo = m + 1 } }
        return lo > 0 ? lo - 1 : nil
    }

    /// Decode ordinal of the sync sample that starts the GOP of decode ordinal `o`.
    private func syncOrdinal(atOrSpanning o: Int) -> Int {
        var lo = 0, hi = syncOrdinals.count  // first sync > o
        while lo < hi { let m = (lo + hi) / 2; if syncOrdinals[m] > o { hi = m } else { lo = m + 1 } }
        return lo > 0 ? syncOrdinals[lo - 1] : 0
    }

    /// Decode ordinal of the sync sample to start decoding from for presentation frame `index`.
    public func syncDecodeOrdinal(for index: Int) -> Int { syncOrdinal(atOrSpanning: entries[index].decodeOrdinal) }

    /// Presentation indices of the frames that belong to the GOP (sync sample up to the next one in decode order).
    public func gop(containing index: Int) -> ClosedRange<Int> {
        let s = syncDecodeOrdinal(for: index)
        var lo = 0, hi = syncOrdinals.count
        while lo < hi { let m = (lo + hi) / 2; if syncOrdinals[m] > s { hi = m } else { lo = m + 1 } }
        let end = lo < syncOrdinals.count ? syncOrdinals[lo] : entries.count
        var mn = Int.max, mx = Int.min
        for o in s..<max(s + 1, end) where o < presentationIndexOfOrdinal.count {
            let p = presentationIndexOfOrdinal[o]; mn = min(mn, p); mx = max(mx, p)
        }
        return mn...mx
    }

    /// Presentation index of the nearest sync frame strictly before `index` (0 when there is none).
    public func previousSync(before index: Int) -> Int {
        var i = min(index, entries.count) - 1
        while i >= 0 { if entries[i].isSync { return i }; i -= 1 }
        return 0
    }
}
