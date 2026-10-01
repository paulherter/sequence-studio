import Foundation

/// One caption on a caption track. Mirrors SQTranscribe's `Caption` (lines, range, style and animation
/// preset references) without depending on it; word indices stay in the transcript layer.
public struct CaptionItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Display lines (already broken by the segmenter or by the user).
    public var lines: [String]
    /// Timeline position (half-open).
    public var range: TimeRange
    /// The style this caption is drawn with. Follows the track's style unless `styleOverridden`.
    public var styleRef: String
    public var animationRef: String
    /// True once the caption got its own style: a change of the track style leaves it alone.
    public var styleOverridden: Bool
    /// Word timings on the timeline (karaoke highlight); empty = spread over the range by word length
    /// (see `effectiveWords`).
    public var words: [CaptionWord]

    public init(id: UUID = UUID(), lines: [String], range: TimeRange, styleRef: String = "", animationRef: String = "",
                styleOverridden: Bool = false, words: [CaptionWord] = []) {
        self.id = id; self.lines = lines; self.range = range
        self.styleRef = styleRef; self.animationRef = animationRef
        self.styleOverridden = styleOverridden; self.words = words
    }

    private enum CodingKeys: String, CodingKey { case id, lines, range, styleRef, animationRef, styleOverridden, words }

    /// Older files lack the override flag and the word timings.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), lines: try c.decode([String].self, forKey: .lines),
                  range: try c.decode(TimeRange.self, forKey: .range),
                  styleRef: try c.decodeIfPresent(String.self, forKey: .styleRef) ?? "",
                  animationRef: try c.decodeIfPresent(String.self, forKey: .animationRef) ?? "",
                  styleOverridden: try c.decodeIfPresent(Bool.self, forKey: .styleOverridden) ?? false,
                  words: try c.decodeIfPresent([CaptionWord].self, forKey: .words) ?? [])
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
    /// Style of the track: every caption without its own style follows it ("" = each caption keeps what it has).
    public var styleRef: String
    public var animationRef: String
    /// Karaoke word highlight (the TikTok look); nil = off.
    public var karaoke: KaraokeStyle?
    /// Sorted by start, never overlapping.
    public private(set) var items: [CaptionItem]

    public init(id: UUID = UUID(), name: String = "", isLocked: Bool = false, syncLock: Bool = true,
                isVisible: Bool = true, items: [CaptionItem] = [], styleRef: String = "", animationRef: String = "",
                karaoke: KaraokeStyle? = nil) {
        self.id = id; self.name = name; self.isLocked = isLocked; self.syncLock = syncLock
        self.isVisible = isVisible
        self.styleRef = styleRef; self.animationRef = animationRef; self.karaoke = karaoke
        self.items = items.sorted { $0.range.start < $1.range.start }
    }

    private enum CodingKeys: String, CodingKey { case id, name, isLocked, syncLock, isVisible, items, styleRef, animationRef, karaoke }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  isLocked: try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false,
                  syncLock: try c.decodeIfPresent(Bool.self, forKey: .syncLock) ?? true,
                  isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
                  items: try c.decodeIfPresent([CaptionItem].self, forKey: .items) ?? [],
                  styleRef: try c.decodeIfPresent(String.self, forKey: .styleRef) ?? "",
                  animationRef: try c.decodeIfPresent(String.self, forKey: .animationRef) ?? "",
                  karaoke: try c.decodeIfPresent(KaraokeStyle.self, forKey: .karaoke))
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

    /// Moves one edge to `t`. Clamped by the neighbours, 0 and `minDuration` (the item never gets shorter; one that is
    /// already shorter, squeezed by its neighbours, just cannot shrink further). The neighbours always win: the result
    /// never overlaps them, however short the item is. Returns the new range, or nil if the item is unknown.
    @discardableResult
    public mutating func trim(_ id: CaptionItem.ID, edge: ClipEdge, to t: Time, minDuration: Time) -> TimeRange? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items[i].range
        switch edge {
        case .head:
            let lo = i > 0 ? items[i - 1].range.end : .zero
            let hi = max(r.start, r.end - minDuration)
            let newStart = max(lo, min(t, hi))
            items[i].shiftWordOrigin(by: newStart - r.start)   // word times are relative to the start
            items[i].range = TimeRange(start: newStart, end: r.end)
        case .tail:
            var e = max(t, min(r.end, r.start + minDuration))
            if i + 1 < items.count { e = min(e, items[i + 1].range.start) }   // the neighbour wins over minDuration
            items[i].range = TimeRange(start: r.start, end: e)
        }
        return items[i].range
    }

    /// Absolute words made relative to `range.start`, clamped into the range.
    static func relativeWords(_ words: [CaptionWord], to range: TimeRange) -> [CaptionWord] {
        words.map { w in
            let a = min(max(w.range.start, range.start), range.end), b = min(max(w.range.end, a), range.end)
            return CaptionWord(text: w.text, range: TimeRange(start: a - range.start, end: b - range.start))
        }
    }

    public mutating func remove(_ id: CaptionItem.ID) { items.removeAll { $0.id == id } }

    /// Splits at `t` (strictly inside the item). The words are shared out by the time proportion, at least one word
    /// each side while the item has two or more. Both halves keep style and animation. Returns the new IDs.
    mutating func split(_ id: CaptionItem.ID, at t: Time) -> (CaptionItem.ID, CaptionItem.ID)? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items[i].range
        guard t > r.start, t < r.end else { return nil }
        let words = items[i].tokens
        let k: Int
        if words.count < 2 { k = words.count }
        else if items[i].hasWordTimings {
            // With timings the cut falls where the speech does: the words that end at or before the cut stay left.
            let ending = items[i].effectiveWords.filter { $0.range.end <= t }.count
            k = min(max(ending, 1), words.count - 1)
        } else {
            let frac = Double((t - r.start).value) / Double((t - r.start).timescale)
                / (Double((r.end - r.start).value) / Double((r.end - r.start).timescale))
            k = min(max(Int((Double(words.count) * frac).rounded()), 1), words.count - 1)
        }
        var left = items[i], right = items[i]
        left.range = TimeRange(start: r.start, end: t); right.range = TimeRange(start: t, end: r.end)
        // Keep the original line breaks where the cut allows: walk the lines, the first k words go left.
        var leftLines: [String] = [], rightLines: [String] = []
        var used = 0
        for line in items[i].lines {
            let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !w.isEmpty else { continue }
            let take = max(0, min(w.count, k - used))
            if take > 0 { leftLines.append(w[..<take].joined(separator: " ")) }
            if take < w.count { rightLines.append(w[take...].joined(separator: " ")) }
            used += take
        }
        left.lines = leftLines.isEmpty ? [""] : leftLines
        right.lines = rightLines.isEmpty ? [""] : rightLines
        // The word timings go with their words; without timings each half spreads its own.
        if items[i].hasWordTimings {
            let eff = items[i].effectiveWords   // absolute, already clamped into the caption
            let cut = min(k, eff.count)
            left.words = Self.relativeWords(Array(eff[..<cut]), to: left.range)
            right.words = Self.relativeWords(Array(eff[cut...]), to: right.range)
        } else { left.words = []; right.words = [] }
        right.id = UUID()
        items[i] = left
        items.insert(right, at: i + 1)
        return (left.id, right.id)
    }

    /// Merges the items from the earliest to the latest of `ids` (everything in between is included) into the
    /// earliest one: text joined by a space on one line, range from the first start to the last end.
    mutating func merge(_ ids: Set<CaptionItem.ID>) -> CaptionItem.ID? {
        let idx = items.indices.filter { ids.contains(items[$0].id) }
        guard let lo = idx.first, let hi = idx.last, lo < hi else { return nil }
        var m = items[lo]
        let text = items[lo...hi].map { $0.lines.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: " ")
        m.lines = [text]
        // Timings survive when every part has them; otherwise the merged caption spreads its words again.
        m.range = TimeRange(start: items[lo].range.start, end: items[hi].range.end)
        m.words = items[lo...hi].allSatisfy({ $0.hasWordTimings || $0.tokens.isEmpty })
            ? Self.relativeWords(items[lo...hi].flatMap(\.effectiveWords), to: m.range) : []
        items.replaceSubrange(lo...hi, with: [m])
        return m.id
    }

    /// New empty caption starting at `at` (not inside another item) up to `duration`, cut short by the next item.
    mutating func add(at: Time, duration: Time, style: String, animation: String) throws -> CaptionItem.ID {
        guard at >= .zero, duration > .zero else { throw EditError.emptyClip }
        guard !items.contains(where: { $0.range.contains(at) }) else { throw EditError.collision }
        var end = at + duration
        if let next = items.first(where: { $0.range.start >= at }) { end = min(end, next.range.start) }
        guard end > at else { throw EditError.collision }
        let ref = items.last { $0.range.end <= at } ?? items.first
        // A new caption follows the track's style; without one it takes its neighbour's look (as before).
        let item = CaptionItem(lines: [""], range: TimeRange(start: at, end: end),
                               styleRef: styleRef.isEmpty ? (ref?.styleRef ?? style) : styleRef,
                               animationRef: animationRef.isEmpty ? (ref?.animationRef ?? animation) : animationRef)
        items.append(item)
        items.sort { $0.range.start < $1.range.start }
        return item.id
    }

    /// The track style: stored on the track and applied to every caption that has no style of its own.
    mutating func setStyle(styleRef: String, animationRef: String?) {
        self.styleRef = styleRef
        if let animationRef { self.animationRef = animationRef }
        for i in items.indices where !items[i].styleOverridden {
            items[i].styleRef = styleRef
            if let animationRef { items[i].animationRef = animationRef }
        }
    }

    /// Gives the captions their own style (`styleRef`), or hands them back to the track style (nil).
    mutating func setItemStyle(_ ids: Set<CaptionItem.ID>, styleRef: String?) {
        for i in items.indices where ids.contains(items[i].id) {
            if let styleRef { items[i].styleRef = styleRef; items[i].styleOverridden = true }
            else {
                items[i].styleOverridden = false
                if !self.styleRef.isEmpty { items[i].styleRef = self.styleRef }
                if !animationRef.isEmpty { items[i].animationRef = animationRef }
            }
        }
    }

    /// Replaces `find` in every line; returns the number of replacements. Timing is untouched.
    mutating func replaceText(find: String, with new: String, caseSensitive: Bool) -> Int {
        guard !find.isEmpty else { return 0 }
        var count = 0
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for i in items.indices {
            var lines = items[i].lines
            for j in lines.indices {
                var out = "", rest = lines[j][...]
                while let r = rest.range(of: find, options: opts) {
                    out += rest[..<r.lowerBound] + new
                    rest = rest[r.upperBound...]
                    count += 1
                }
                lines[j] = out + rest
            }
            items[i].lines = lines
        }
        return count
    }

    /// Ripple-closes `span`: material after it moves left by its duration, items inside it are cut out
    /// (fully covered ones vanish, straddling ones shrink). Items never overlap afterwards.
    mutating func closeSpan(_ span: TimeRange) {
        guard !span.isEmpty else { return }
        func f(_ t: Time) -> Time { t <= span.start ? t : (t >= span.end ? t - span.duration : span.start) }
        remap(f)
    }

    /// Ripple-opens a gap of `length` at `pivot`: items starting at or after it move right, an item
    /// under the pivot stretches over the gap (its words after the pivot move with the material).
    mutating func openGap(at pivot: Time, by length: Time) {
        guard length > .zero else { return }
        func g(_ t: Time) -> Time { t >= pivot ? t + length : t }
        items = items.map { item in
            var c = item
            let a = item.range.start, b = item.range.end
            c.range = TimeRange(start: a >= pivot ? a + length : a, end: b > pivot ? b + length : b)
            c.mapWords(from: item, g)
            return c
        }
    }

    private mutating func remap(_ f: (Time) -> Time) {
        items = items.compactMap { item in
            var c = item
            let r = TimeRange(start: f(item.range.start), end: f(item.range.end))
            guard !r.isEmpty else { return nil }
            c.range = r
            c.mapWords(from: item, f)
            return c
        }
    }
}

extension CaptionItem {
    /// After a ripple: the word times of `old` pass through the same time map as the material, and are stored relative
    /// to the (already set) new range. Items without usable timings are left alone.
    fileprivate mutating func mapWords(from old: CaptionItem, _ f: (Time) -> Time) {
        guard old.hasWordTimings else { return }
        let moved = old.effectiveWords.map { CaptionWord(text: $0.text, range: TimeRange(start: f($0.range.start), end: f($0.range.end))) }
        words = CaptionTrack.relativeWords(moved, to: range)
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

    /// Splits a caption at `t`. Returns the IDs of the two halves.
    @discardableResult
    public mutating func splitCaption(_ id: CaptionItem.ID, at t: Time) throws -> (CaptionItem.ID, CaptionItem.ID) {
        let i = try captionLocation(id)
        guard let r = captionTracks[i].split(id, at: t) else { throw EditError.emptyClip }
        return r
    }

    /// Merges the selected captions (and any between them) of one track into one. Needs two or more.
    @discardableResult
    public mutating func mergeCaptions(_ ids: Set<CaptionItem.ID>) throws -> CaptionItem.ID {
        guard let first = ids.first else { throw EditError.clipNotFound }
        let i = try captionLocation(first)
        guard ids.allSatisfy({ captionTracks[i].item($0) != nil }) else { throw EditError.wrongTrackKind }
        guard let m = captionTracks[i].merge(ids) else { throw EditError.emptyClip }
        return m
    }

    @discardableResult
    public mutating func addCaption(at t: Time, duration: Time, track: CaptionTrack.ID? = nil) throws -> CaptionItem.ID {
        let id = try track ?? captionTracks.first?.id ?? replaceCaptions([])
        let i = try captionTrackIndex(id)
        return try captionTracks[i].add(at: t, duration: duration, style: "", animation: "")
    }

    /// Search and replace over all unlocked caption tracks (a locked track throws). Returns the replacement count.
    @discardableResult
    public mutating func replaceCaptionText(find: String, with new: String, caseSensitive: Bool) throws -> Int {
        // Locked tracks are skipped (and not counted); only when every track is locked is the edit refused.
        guard captionTracks.contains(where: { !$0.isLocked }) || captionTracks.isEmpty else { throw EditError.trackLocked }
        guard find != new else { return 0 }
        var n = 0
        for i in captionTracks.indices where !captionTracks[i].isLocked {
            n += captionTracks[i].replaceText(find: find, with: new, caseSensitive: caseSensitive)
        }
        return n
    }

    /// IDs of the captions whose text contains `find`, in time order.
    public func captionMatches(find: String, caseSensitive: Bool) -> [CaptionItem.ID] {
        guard !find.isEmpty else { return [] }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return captionTracks.flatMap(\.items).sorted { $0.range.start < $1.range.start }
            .filter { $0.lines.contains { $0.range(of: find, options: opts) != nil } }.map(\.id)
    }

    /// Sets the style (and optionally the animation) of the track: every caption without its own style follows it.
    public mutating func setCaptionStyle(styleRef: String, animationRef: String? = nil, track id: CaptionTrack.ID) throws {
        let i = try captionTrackIndex(id)
        captionTracks[i].setStyle(styleRef: styleRef, animationRef: animationRef)
    }

    /// Gives the captions their own style (an override), or with nil hands them back to the track style.
    public mutating func setCaptionItemStyle(_ ids: Set<CaptionItem.ID>, styleRef: String?) throws {
        guard !ids.isEmpty else { return }
        for i in captionTracks.indices where captionTracks[i].items.contains(where: { ids.contains($0.id) }) {
            if captionTracks[i].isLocked { throw EditError.trackLocked }
        }
        for i in captionTracks.indices { captionTracks[i].setItemStyle(ids, styleRef: styleRef) }
    }

    /// Turns the karaoke word highlight of a track on (a style) or off (nil).
    public mutating func setCaptionKaraoke(_ karaoke: KaraokeStyle?, track id: CaptionTrack.ID) throws {
        let i = try captionTrackIndex(id)
        captionTracks[i].karaoke = karaoke
    }

    /// Captions visible at `t`, bottom track first. Captions of nested sequences are not evaluated (Premiere).
    public func captions(at t: Time) -> [ActiveCaption] {
        captionTracks.filter(\.isVisible).compactMap { track in
            track.items.first { $0.range.contains(t) }.map { ActiveCaption(item: $0, track: track.id) }
        }
    }

    // MARK: Ripple support (used by the timeline-wide edits; only unlocked, sync-locked tracks follow)

    /// Captions, sequence markers and the In/Out range follow a ripple that closes `span`.
    mutating func closeCaptionSpan(_ span: TimeRange) {
        for i in captionTracks.indices where captionTracks[i].followsRipple { captionTracks[i].closeSpan(span) }
        shiftMarkers(from: span.end, by: .zero - span.duration)
        shiftInOut(from: span.end, by: .zero - span.duration)
    }

    mutating func openCaptionGap(at pivot: Time, by length: Time) {
        for i in captionTracks.indices where captionTracks[i].followsRipple {
            captionTracks[i].openGap(at: pivot, by: length)
        }
        shiftMarkers(from: pivot, by: length)
        shiftInOut(from: pivot, by: length)
    }

    /// Same point rule as `shiftMarkers`: points at or after `editPoint` move by `delta`; points inside a removed
    /// span collapse to its start. A range that collapses to nothing is cleared.
    mutating func shiftInOut(from editPoint: Time, by delta: Time) {
        guard let r = inOut else { return }
        let floor = editPoint + min(delta, .zero)
        func shifted(_ p: Time) -> Time { p >= editPoint ? p + delta : (p >= floor ? floor : p) }
        let outOnly = explicitMarks.markIn == nil
        let n = TimeRange(start: outOnly ? r.start : shifted(r.start), end: shifted(r.end))
        inOut = n.isEmpty ? nil : n
        if inOut == nil { inOutKind = nil }
    }
}
