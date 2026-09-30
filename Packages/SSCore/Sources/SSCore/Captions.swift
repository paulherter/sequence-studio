import Foundation

/// One caption on a caption track. Mirrors SSTranscribe's `Caption` (lines, range, style and animation
/// preset references) without depending on it; word indices stay in the transcript layer.
public struct CaptionItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Display lines (already broken by the segmenter or by the user).
    public var lines: [String]
    /// Timeline position (half-open).
    public var range: TimeRange
    public var styleRef: String
    public var animationRef: String

    public init(id: UUID = UUID(), lines: [String], range: TimeRange, styleRef: String = "", animationRef: String = "") {
        self.id = id; self.lines = lines; self.range = range
        self.styleRef = styleRef; self.animationRef = animationRef
    }

    /// Lines joined with newlines.
    public var text: String { lines.joined(separator: "\n") }
}

/// A caption track: sorted items that never overlap. Sits above the video tracks; sync-locked like a clip track.
public struct CaptionTrack: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var isLocked: Bool
    /// Shifts together with ripple edits made on other tracks (unless locked).
    public var syncLock: Bool
    /// Hidden tracks produce no captions in `Timeline.captions(at:)`.
    public var isVisible: Bool
    /// Sorted by start, never overlapping.
    public private(set) var items: [CaptionItem]

    public init(id: UUID = UUID(), name: String = "", isLocked: Bool = false, syncLock: Bool = true,
                isVisible: Bool = true, items: [CaptionItem] = []) {
        self.id = id; self.name = name; self.isLocked = isLocked; self.syncLock = syncLock
        self.isVisible = isVisible
        self.items = items.sorted { $0.range.start < $1.range.start }
    }

    private enum CodingKeys: String, CodingKey { case id, name, isLocked, syncLock, isVisible, items }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  isLocked: try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false,
                  syncLock: try c.decodeIfPresent(Bool.self, forKey: .syncLock) ?? true,
                  isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
                  items: try c.decodeIfPresent([CaptionItem].self, forKey: .items) ?? [])
    }

    public var followsRipple: Bool { syncLock && !isLocked }
    public var end: Time { items.last?.range.end ?? .zero }
    public func item(_ id: CaptionItem.ID) -> CaptionItem? { items.first { $0.id == id } }

    /// Replaces all items. Throws `.emptyClip` for an empty range, `.collision` for overlaps. Unsorted input is sorted.
    public mutating func replaceAll(_ new: [CaptionItem]) throws {
        let sorted = new.sorted { $0.range.start < $1.range.start }
        guard sorted.allSatisfy({ !$0.range.isEmpty && $0.range.start >= .zero }) else { throw EditError.emptyClip }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.range.end <= $1.range.start }) else { throw EditError.collision }
        items = sorted
    }

    /// Edits the text only; timing is untouched.
    @discardableResult
    public mutating func setLines(_ id: CaptionItem.ID, _ lines: [String]) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].lines = lines
        return true
    }

    /// Moves an item so it starts at `start`, keeping its duration. Clamped by the neighbours and 0.
    /// Returns the applied start, or nil if the item is unknown.
    @discardableResult
    public mutating func move(_ id: CaptionItem.ID, to start: Time) -> Time? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let dur = items[i].range.duration
        let lo = i > 0 ? items[i - 1].range.end : .zero
        var s = max(start, lo)
        if i + 1 < items.count { s = min(s, items[i + 1].range.start - dur) }
        s = max(s, lo)
        items[i].range = TimeRange(start: s, duration: dur)
        return s
    }

    /// Moves one edge to `t`. Clamped by the neighbours, 0 and `minDuration` (the item never gets shorter).
    /// Returns the new range, or nil if the item is unknown.
    @discardableResult
    public mutating func trim(_ id: CaptionItem.ID, edge: ClipEdge, to t: Time, minDuration: Time) -> TimeRange? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items[i].range
        switch edge {
        case .head:
            let lo = i > 0 ? items[i - 1].range.end : .zero
            let s = min(max(t, lo), r.end - minDuration)
            items[i].range = TimeRange(start: s, end: r.end)
        case .tail:
            var e = max(t, r.start + minDuration)
            if i + 1 < items.count { e = min(e, items[i + 1].range.start) }
            items[i].range = TimeRange(start: r.start, end: max(e, r.start + minDuration))
        }
        return items[i].range
    }

    public mutating func remove(_ id: CaptionItem.ID) { items.removeAll { $0.id == id } }

    /// Ripple-closes `span`: material after it moves left by its duration, items inside it are cut out
    /// (fully covered ones vanish, straddling ones shrink). Items never overlap afterwards.
    mutating func closeSpan(_ span: TimeRange) {
        guard !span.isEmpty else { return }
        func f(_ t: Time) -> Time { t <= span.start ? t : (t >= span.end ? t - span.duration : span.start) }
        remap(f)
    }

    /// Ripple-opens a gap of `length` at `pivot`: items starting at or after it move right, an item
    /// under the pivot stretches over the gap.
    mutating func openGap(at pivot: Time, by length: Time) {
        guard length > .zero else { return }
        items = items.map { item in
            var c = item
            let a = item.range.start, b = item.range.end
            c.range = TimeRange(start: a >= pivot ? a + length : a, end: b > pivot ? b + length : b)
            return c
        }
    }

    private mutating func remap(_ f: (Time) -> Time) {
        items = items.compactMap { item in
            var c = item
            let r = TimeRange(start: f(item.range.start), end: f(item.range.end))
            guard !r.isEmpty else { return nil }
            c.range = r
            return c
        }
    }
}

/// A caption visible at one instant.
public struct ActiveCaption: Sendable, Hashable {
    public var item: CaptionItem
    public var track: CaptionTrack.ID
}

extension Timeline {
    private func captionTrackIndex(_ id: CaptionTrack.ID) throws -> Int {
        guard let i = captionTracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        if captionTracks[i].isLocked { throw EditError.trackLocked }
        return i
    }

    private func captionLocation(_ id: CaptionItem.ID) throws -> Int {
        guard let i = captionTracks.firstIndex(where: { $0.item(id) != nil }) else { throw EditError.clipNotFound }
        if captionTracks[i].isLocked { throw EditError.trackLocked }
        return i
    }

    public func captionTrack(_ id: CaptionTrack.ID) -> CaptionTrack? { captionTracks.first { $0.id == id } }

    /// Replaces every caption of a track with `items` (e.g. after transcribing). Without `track` the first
    /// caption track is used, and one is created when there is none. Returns the track ID.
    /// Invalid input (empty range, overlap) throws and leaves the timeline unchanged.
    @discardableResult
    public mutating func replaceCaptions(_ items: [CaptionItem], track id: CaptionTrack.ID? = nil) throws -> CaptionTrack.ID {
        if let id {
            let i = try captionTrackIndex(id)
            try captionTracks[i].replaceAll(items)
            return id
        }
        if let first = captionTracks.first?.id { return try replaceCaptions(items, track: first) }
        var t = CaptionTrack(name: "C1")
        try t.replaceAll(items)
        captionTracks.append(t)
        return t.id
    }

    /// Edits the text of one caption.
    public mutating func setCaptionText(_ id: CaptionItem.ID, lines: [String]) throws {
        let i = try captionLocation(id)
        captionTracks[i].setLines(id, lines)
    }

    /// Moves a caption (clamped by neighbours and 0). Returns the applied start.
    @discardableResult
    public mutating func moveCaption(_ id: CaptionItem.ID, to start: Time) throws -> Time {
        let i = try captionLocation(id)
        return captionTracks[i].move(id, to: start)!
    }

    /// Moves one edge of a caption (clamped by neighbours, 0 and one frame minimum). Returns the new range.
    @discardableResult
    public mutating func trimCaption(_ id: CaptionItem.ID, edge: ClipEdge, to t: Time) throws -> TimeRange {
        let i = try captionLocation(id)
        return captionTracks[i].trim(id, edge: edge, to: t, minDuration: frameDuration)!
    }

    public mutating func deleteCaption(_ id: CaptionItem.ID) throws {
        let i = try captionLocation(id)
        captionTracks[i].remove(id)
    }

    /// Captions visible at `t`, bottom track first. Captions of nested sequences are not evaluated (Premiere).
    public func captions(at t: Time) -> [ActiveCaption] {
        captionTracks.filter(\.isVisible).compactMap { track in
            track.items.first { $0.range.contains(t) }.map { ActiveCaption(item: $0, track: track.id) }
        }
    }

    // MARK: Ripple support (used by the timeline-wide edits; only unlocked, sync-locked tracks follow)

    mutating func closeCaptionSpan(_ span: TimeRange) {
        for i in captionTracks.indices where captionTracks[i].followsRipple { captionTracks[i].closeSpan(span) }
    }

    mutating func openCaptionGap(at pivot: Time, by length: Time) {
        for i in captionTracks.indices where captionTracks[i].followsRipple {
            captionTracks[i].openGap(at: pivot, by: length)
        }
    }
}
