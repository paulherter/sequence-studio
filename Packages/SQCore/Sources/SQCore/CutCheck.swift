import Foundation

/// Platforms with a UI overlay safe zone (mirrors the export presets; SQCore cannot import SQExport).
public enum CutCheckPlatform: String, Sendable, Hashable, CaseIterable {
    case tiktok, reels, shorts

    public var title: String {
        switch self { case .tiktok: "TikTok"; case .reels: "Reels"; case .shorts: "Shorts" }
    }
}

/// Rectangle in frame-relative units: origin top-left, all values 0...1.
public struct NormRect: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func contains(_ o: NormRect, tolerance e: Double = 0.001) -> Bool {
        o.x >= x - e && o.y >= y - e && o.x + o.width <= x + width + e && o.y + o.height <= y + height + e
    }
}

/// Insets (fractions of the frame) that platform UI (username, buttons, progress bar) covers on a 9:16 video.
public struct SafeZone: Sendable, Hashable {
    public var top: Double, bottom: Double, left: Double, right: Double
    public var rect: NormRect { NormRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom) }

    /// The zone as a frame fraction for a frame of `frameAspect` (width / height). A frame wider than 9:16 shows the
    /// platform's 9:16 picture as a centered window, so the zone is mapped into that window.
    public static func rect(for p: CutCheckPlatform, frameAspect: Double) -> NormRect {
        let z = zone(for: p).rect
        let vertical = 9.0 / 16
        guard frameAspect > vertical + 1e-6 else { return z }
        let win = vertical / frameAspect
        return NormRect(x: (1 - win) / 2 + z.x * win, y: z.y, width: z.width * win, height: z.height)
    }

    /// Approximate published creator guidance (1080 x 1920): TikTok ~ top 210 / bottom 340 / right 120 px, Reels and Shorts similar.
    public static func zone(for p: CutCheckPlatform) -> SafeZone {
        switch p {
        case .tiktok: SafeZone(top: 0.11, bottom: 0.18, left: 0.06, right: 0.12)
        case .reels: SafeZone(top: 0.13, bottom: 0.20, left: 0.05, right: 0.10)
        case .shorts: SafeZone(top: 0.10, bottom: 0.20, left: 0.05, right: 0.14)
        }
    }
}

public enum CutFindingKind: String, Sendable, Hashable, CaseIterable {
    case jumpCut, gap, captionOutsideSafeZone, audioPop

    public var title: String {
        switch self {
        case .jumpCut: "Jump cut"
        case .gap: "Gap"
        case .captionOutsideSafeZone: "Caption outside safe zone"
        case .audioPop: "Audio pop"
        }
    }
    var markerColor: MarkerColor {
        switch self { case .jumpCut: .orange; case .gap: .red; case .captionOutsideSafeZone: .purple; case .audioPop: .yellow }
    }
}

public struct CutFinding: Sendable, Hashable {
    public var kind: CutFindingKind
    public var time: Time
    /// Zero for point findings.
    public var duration: Time
    public var message: String
}

public struct ShotBucket: Sendable, Hashable { public var label: String; public var count: Int }

public struct EditStats: Sendable, Hashable {
    public var shotCount = 0
    public var cuts = 0
    public var totalSeconds = 0.0
    public var averageShotSeconds = 0.0
    public var shortestShotSeconds = 0.0
    public var longestShotSeconds = 0.0
    public var cutsPerMinute = 0.0
    public var histogram: [ShotBucket] = []
}

/// Pure cut-quality analysis of a sequence: jump cuts with unchanged framing, gaps, captions in the platform UI zone,
/// audio joins without a fade, plus shot-length statistics.
public enum CutCheck {
    static let tagPrefix = "[cutcheck:"
    private static func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    /// `captionBounds` returns a caption's on-screen box (frame-relative); nil = unknown, the caption is skipped.
    /// `platform` nil skips the safe-zone check.
    public static func analyze(_ tl: Timeline, platform: CutCheckPlatform? = nil, frameAspect: Double = 9.0 / 16,
                               captionBounds: ((CaptionItem) -> NormRect?)? = nil) -> [CutFinding] {
        var out: [CutFinding] = []
        let fd = tl.frameDuration
        for track in tl.tracks {
            let clips = track.clips.filter(\.isEnabled)
            for (a, b) in zip(clips, clips.dropFirst()) {
                guard b.start - a.timeline.end < fd, a.timeline.end - b.start < fd else { continue } // touching
                if track.kind == .video, isJumpCut(a, b, fd) {
                    out.append(CutFinding(kind: .jumpCut, time: b.start, duration: .zero,
                                          message: "Same source, same framing: cut looks like a jump."))
                }
                if track.kind == .audio, isPop(a, b, fd, track: track) {
                    out.append(CutFinding(kind: .audioPop, time: b.start, duration: .zero,
                                          message: "No fade at this audio join: it may click."))
                }
            }
        }
        out += gaps(tl)
        if let p = platform, let bounds = captionBounds {
            let zone = SafeZone.rect(for: p, frameAspect: frameAspect)
            for ct in tl.captionTracks {
                for item in ct.items {
                    guard let r = bounds(item), !zone.contains(r) else { continue }
                    out.append(CutFinding(kind: .captionOutsideSafeZone, time: item.range.start, duration: item.range.duration,
                                          message: "Caption leaves the \(p.rawValue) safe zone."))
                }
            }
        }
        return out.sorted { $0.time != $1.time ? $0.time < $1.time : $0.kind.rawValue < $1.kind.rawValue }
    }

    /// The second clip continues the first one's source (within a frame): a rejoined edit, not a jump.
    private static func contiguousSource(_ a: Clip, _ b: Clip, _ fd: Time) -> Bool {
        guard !a.isRetimed, !b.isRetimed else { return false }
        let d = b.source.start - a.source.end
        return d < fd && .zero - fd < d
    }

    private static func isJumpCut(_ a: Clip, _ b: Clip, _ fd: Time) -> Bool {
        guard !a.isGenerator, !b.isGenerator, !a.isNested, !b.isNested, !a.isStill, !b.isStill, a.media == b.media else { return false }
        if contiguousSource(a, b, fd) { return false }
        let ta = a.transform(at: a.timeline.end - fd), tb = b.transform(at: b.start)
        return abs(ta.position.x - tb.position.x) < 0.02 && abs(ta.position.y - tb.position.y) < 0.02
            && abs(ta.scale.x - tb.scale.x) < 0.03 && abs(ta.scale.y - tb.scale.y) < 0.03
            && abs(ta.rotation - tb.rotation) < 1
    }

    private static func isPop(_ a: Clip, _ b: Clip, _ fd: Time, track: Track) -> Bool {
        if a.media == b.media, contiguousSource(a, b, fd) { return false }
        let tail = FadeKeys.tailLength(of: a.animation.volume, duration: a.duration, marks: a.audioFades) ?? .zero
        let head = FadeKeys.headLength(of: b.animation.volume, marks: b.audioFades) ?? .zero
        if tail >= fd || head >= fd { return false }
        if track.transitions.contains(where: { $0.outgoing == a.id && $0.incoming == b.id }) { return false }
        // Silent on one side: nothing to click.
        return a.volume(at: a.timeline.end - fd) > 0.001 && b.volume(at: b.start) > 0.001
    }

    /// Union of enabled video clips; holes inside it are gaps.
    private static func gaps(_ tl: Timeline) -> [CutFinding] {
        let ranges = coverage(tl)
        var out: [CutFinding] = []
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            out.append(CutFinding(kind: .gap, time: a.end, duration: b.start - a.end, message: "Empty stretch on the video tracks."))
        }
        return out
    }

    /// Merged (touching ranges joined) covered ranges of the video tracks.
    static func coverage(_ tl: Timeline) -> [TimeRange] {
        let rs = tl.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter(\.isEnabled).map(\.timeline)
            .filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for r in rs {
            if let l = merged.last, r.start <= l.end { merged[merged.count - 1] = TimeRange(start: l.start, end: max(l.end, r.end)) }
            else { merged.append(r) }
        }
        return merged
    }

    public static func stats(_ tl: Timeline) -> EditStats {
        let clips = tl.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter(\.isEnabled).filter { !$0.timeline.isEmpty }
        let cov = coverage(tl)
        guard !clips.isEmpty else { return EditStats(histogram: histogram([])) }
        var bounds = Set<Time>()
        for c in clips { bounds.insert(c.start); bounds.insert(c.timeline.end) }
        let sorted = bounds.sorted()
        var shots: [Time] = [], cuts = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) where cov.contains(where: { $0.start <= a && b <= $0.end }) { shots.append(b - a) }
        for t in sorted where cov.contains(where: { $0.start < t && t < $0.end }) { cuts += 1 }
        let secs = shots.map(sec)
        let total = cov.reduce(0.0) { $0 + sec($1.duration) }
        var st = EditStats()
        st.shotCount = shots.count; st.cuts = cuts; st.totalSeconds = total
        st.averageShotSeconds = secs.isEmpty ? 0 : secs.reduce(0, +) / Double(secs.count)
        st.shortestShotSeconds = secs.min() ?? 0; st.longestShotSeconds = secs.max() ?? 0
        st.cutsPerMinute = total > 0 ? Double(cuts) / (total / 60) : 0
        st.histogram = histogram(secs)
        return st
    }

    private static func histogram(_ secs: [Double]) -> [ShotBucket] {
        let edges: [(String, Double)] = [("< 0.5 s", 0.5), ("0.5–1", 1), ("1–2", 2), ("2–4", 4), ("> 4 s", .infinity)]
        var counts = [Int](repeating: 0, count: edges.count)
        for s in secs { counts[edges.firstIndex { s < $0.1 } ?? edges.count - 1] += 1 }
        return zip(edges, counts).map { ShotBucket(label: $0.0, count: $1) }
    }

    // MARK: Markers

    /// The finding kind a marker carries, nil for markers the user made.
    public static func kind(of m: Marker) -> CutFindingKind? {
        guard m.comment.hasPrefix(tagPrefix), let end = m.comment.firstIndex(of: "]") else { return nil }
        let raw = m.comment[m.comment.index(m.comment.startIndex, offsetBy: tagPrefix.count)..<end]
        return CutFindingKind(rawValue: String(raw))
    }
}

extension Timeline {
    /// Replaces the markers of the last Check Cuts run with `findings` (user markers stay). Uses the existing marker model:
    /// the kind is in the comment tag, the color and name follow the kind, gaps and captions span their range.
    public mutating func applyCutCheck(_ findings: [CutFinding]) {
        markers.removeAll { CutCheck.kind(of: $0) != nil }
        let fd = frameDuration
        for f in findings {
            let id = addMarker(at: f.time, name: f.kind.title)
            updateMarker(id) {
                $0.color = f.kind.markerColor
                $0.comment = "\(CutCheck.tagPrefix)\(f.kind.rawValue)] \(f.message)"
                $0.duration = f.duration.snapped(to: fd)
            }
        }
    }
}
