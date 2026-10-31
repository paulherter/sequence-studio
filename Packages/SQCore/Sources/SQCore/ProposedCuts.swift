import Foundation

/// What a proposed cut was found by. Silence and filler are ranges that get removed; `scene` is a point (empty range) where
/// accepting razors the clips instead of deleting anything.
public enum ProposedCutKind: String, Sendable, Hashable, CaseIterable { case silence, filler, scene }

extension Marker {
    /// Typed marker without a file-format change: a range marker whose comment carries this tag (`tag:kind`).
    static let proposedCutTag = "sq.proposedCut"

    public var proposedCutKind: ProposedCutKind? {
        guard comment.hasPrefix(Self.proposedCutTag) else { return nil }
        return ProposedCutKind(rawValue: String(comment.dropFirst(Self.proposedCutTag.count + 1))) ?? .silence
    }
    public var isProposedCut: Bool { proposedCutKind != nil }
}

extension Timeline {
    public struct ProposedCut: Sendable, Equatable, Identifiable {
        public var id: Marker.ID
        public var range: TimeRange
        public var kind: ProposedCutKind
        public init(id: Marker.ID, range: TimeRange, kind: ProposedCutKind) { self.id = id; self.range = range; self.kind = kind }
    }

    /// The pending "proposed cut" markers, in time order.
    public var proposedCuts: [ProposedCut] {
        markers.compactMap { m in
            m.proposedCutKind.map { ProposedCut(id: m.id, range: TimeRange(start: m.time, duration: m.duration), kind: $0) }
        }
    }

    public var proposedCutTotal: Time { proposedCuts.reduce(Time.zero) { $0 + $1.range.duration } }

    /// Replaces earlier proposals of `kind` by range markers for `cuts` (red, named "Cut: silence").
    public mutating func proposeCuts(_ cuts: [TimeRange], kind: ProposedCutKind) {
        markers.removeAll { $0.proposedCutKind == kind }
        for c in SilenceRemoval.normalized(cuts) {
            markers.append(Marker(time: c.start, name: "Cut: \(kind.rawValue)", color: .red,
                                  comment: "\(Marker.proposedCutTag):\(kind.rawValue)", duration: c.duration))
        }
        markers.sort { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
    }

    /// Replaces earlier scene proposals by point markers at `times` (sorted, duplicates dropped, negative ones ignored).
    public mutating func proposeSceneCuts(_ times: [Time]) {
        markers.removeAll { $0.proposedCutKind == .scene }
        var last: Time?
        for t in times.sorted() where t > .zero && t != last {
            last = t
            markers.append(Marker(time: t, name: "Cut: scene", color: .red,
                                  comment: "\(Marker.proposedCutTag):scene", duration: .zero))
        }
        markers.sort { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
    }

    public mutating func rejectProposedCut(_ id: Marker.ID) { markers.removeAll { $0.id == id && $0.isProposedCut } }
    public mutating func rejectAllProposedCuts() { markers.removeAll(where: \.isProposedCut) }

    /// Ripple-deletes the proposals in `ids` (nil = all) as `removeSilences` does (all or nothing), drops their markers and
    /// moves every other marker with the closed gaps. Returns the time removed.
    @discardableResult
    ///
    /// Scene proposals razor instead: every clip under the point on the tracks of `sceneClips` (default `clips`) and of
    /// their linked partners is cut in two; nothing is removed and nothing moves.
    public mutating func acceptProposedCuts(_ ids: Set<Marker.ID>?, around clips: Set<Clip.ID>,
                                            sceneClips: Set<Clip.ID>? = nil, joinFade: Time = .zero) throws -> Time {
        let chosen = proposedCuts.filter { ids?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { return .zero }
        var work = self
        let scenes = chosen.filter { $0.kind == .scene }
        if !scenes.isEmpty {
            let sel = sceneClips ?? clips
            let links = Set(tracks.flatMap(\.clips).filter { sel.contains($0.id) }.compactMap(\.link))
            let ids = work.tracks.filter { tr in
                !tr.isLocked && tr.clips.contains { sel.contains($0.id) || ($0.link.map(links.contains) ?? false) }
            }.map(\.id)
            if !ids.isEmpty { for s in scenes { try work.addEdit(at: s.range.start, tracks: ids) } }
        }
        let removals = chosen.filter { $0.kind != .scene }
        var removed = Time.zero
        if !removals.isEmpty { removed = try work.removeSilences(removals.map(\.range), around: clips, joinFade: joinFade) }
        let gone = Set(chosen.map(\.id))
        work.markers.removeAll { gone.contains($0.id) }
        self = work                                   // extract already moved the remaining markers (closeCaptionSpan)
        return removed
    }
}

extension Timeline.ProposedCut {
    /// "0:12.4   1.4 s": start in minutes:seconds and the length of the pause (the review list's row).
    public var rowTitle: String {
        func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        let start = max(sec(range.start), 0)
        let m = Int(start) / 60
        let s = start - Double(m * 60)
        if kind == .scene { return String(format: "%d:%04.1f   scene change", m, s) }
        return String(format: "%d:%04.1f   %.1f s", m, s, sec(range.duration))
    }

    /// "3 of 5 checked, 4.2 s will be removed." under the review list.
    public static func reviewSummary(count: Int, checked: Int, removed: Time) -> String {
        guard count > 0 else { return "No proposed cuts." }
        let sec = Double(removed.value) / Double(removed.timescale)
        return "\(checked) of \(count) checked, \(String(format: "%.1f", sec)) s will be removed."
    }
}
