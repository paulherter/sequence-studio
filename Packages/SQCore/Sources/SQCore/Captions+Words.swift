import Foundation

// Word-level caption editing (captions are corrected directly on the caption track): edit, delete and insert a word,
// split before a word, join with a neighbor, retime a word edge, search and replace. All of it keeps the word timings
// the caption carries (`CaptionItem.words`, relative to the caption's start); a caption without timings stays without
// them (its words keep spreading over the range by length) until a word edge is dragged.

/// The caption before or after one on the same track.
public enum CaptionNeighbor: Sendable, Hashable { case previous, next }

/// One find result on a caption track.
public struct CaptionTextMatch: Sendable, Hashable {
    public var track: CaptionTrack.ID
    public var caption: CaptionItem.ID
    /// Index into `CaptionItem.lines`.
    public var line: Int
    /// Character offsets of the match in that line.
    public var range: Range<Int>
    /// The words (indices into `CaptionItem.tokens`) the match touches.
    public var words: ClosedRange<Int>
    /// Start of the caption (matches are listed in time order).
    public var time: Time
}

extension CaptionItem {
    /// The shortest a refitted word gets (one tick): a word must stay something that can be drawn, grabbed and lit.
    static let wordTick = Time(1, 1000)

    /// `words` spread over `span` by their length (the same rule as `effectiveWords` without timings). When that would
    /// leave a word shorter than a tick, they share the span evenly instead.
    static func spread(_ toks: [String], over span: TimeRange) -> [CaptionWord] {
        let total = Int64(toks.reduce(0) { $0 + max($1.count, 1) })
        var cum: Int64 = 0
        let byLength = toks.map { tok -> CaptionWord in
            let a = cum; cum += Int64(max(tok.count, 1))
            func at(_ n: Int64) -> Time {
                n == total ? span.end : min(max(span.start + Time.scaled(span.duration, by: n, over: total), span.start), span.end)
            }
            let s = at(a)
            return CaptionWord(text: tok, range: TimeRange(start: s, end: max(at(cum), s)))
        }
        return byLength.contains { $0.range.duration < wordTick } ? even(toks, over: span) : byLength
    }

    /// `words` sharing `span` in equal parts.
    static func even(_ toks: [String], over span: TimeRange) -> [CaptionWord] {
        let n = Int64(toks.count)
        func at(_ i: Int64) -> Time { i == n ? span.end : span.start + Time.scaled(span.duration, by: i, over: n) }
        return toks.enumerated().map { i, tok in CaptionWord(text: tok, range: TimeRange(start: at(Int64(i)), end: at(Int64(i) + 1))) }
    }

    /// The timings after the words `r` of `old` were replaced by `new`. Every other word keeps its time.
    /// - same count: one to one, only the text changes;
    /// - other count: the new words share the time span of the replaced ones by their length;
    /// - insertion (`r` empty): the new words take the pause between the neighbors; without a pause they take the second
    ///   half of the word before (the first half of the word after, at the very start);
    /// - no word ends up without a duration: when the span is shorter than a tick per word, the new words and their
    ///   neighbors (one more on each side until there is room, at last the whole caption) share their span evenly.
    static func refit(_ old: [CaptionWord], replacing r: Range<Int>, with new: [String], duration: Time) -> [CaptionWord] {
        var out = Array(old[..<r.lowerBound]), tail = Array(old[r.upperBound...])
        guard !new.isEmpty else { return out + tail }
        if !r.isEmpty, new.count == r.count {
            return out + zip(new, old[r]).map { CaptionWord(text: $0, range: $1.range, confidence: $0 == $1.text ? $1.confidence : nil) } + tail
        }
        var span: TimeRange
        if r.isEmpty {
            let lo = out.last?.range.end ?? .zero
            let hi = tail.first?.range.start ?? max(duration, lo)
            if hi > lo { span = TimeRange(start: lo, end: hi) }
            else if let p = out.last, p.range.duration > .zero {
                let mid = p.range.start + p.range.duration.halved
                out[out.count - 1].range = TimeRange(start: p.range.start, end: mid)
                span = TimeRange(start: mid, end: p.range.end)
            } else if let n = tail.first, n.range.duration > .zero {
                let mid = n.range.start + n.range.duration.halved
                tail[0].range = TimeRange(start: mid, end: n.range.end)
                span = TimeRange(start: n.range.start, end: mid)
            } else { span = TimeRange(start: lo, duration: .zero) }
        } else {
            let a = old[r.lowerBound].range.start
            span = TimeRange(start: a, end: max(old[r.upperBound - 1].range.end, a))
        }
        // Too short for its words: take the neighbors in and share.
        var pool = new, widened = false
        var poolConfidence = [Float?](repeating: nil, count: new.count)   // the new words are unconfirmed-free: nil
        func tooShort() -> Bool { span.duration < Self.wordTick * Int64(pool.count) }
        while tooShort(), !(out.isEmpty && tail.isEmpty) {
            widened = true
            if let p = out.popLast() {
                pool.insert(p.text, at: 0); poolConfidence.insert(p.confidence, at: 0)
                span = TimeRange(start: min(p.range.start, span.start), end: max(p.range.end, span.end))
            }
            if let n = tail.first {
                tail.removeFirst()
                pool.append(n.text); poolConfidence.append(n.confidence)
                span = TimeRange(start: min(n.range.start, span.start), end: max(n.range.end, span.end))
            }
        }
        if tooShort(), duration > .zero { widened = true; span = TimeRange(start: .zero, end: duration) }
        var fitted = widened ? even(pool, over: span) : spread(pool, over: span)
        for i in fitted.indices { fitted[i].confidence = poolConfidence[i] }
        return out + fitted + tail
    }

    /// Replaces the words `r` (indices into `tokens`, empty = insert before `r.lowerBound`) by `new`. Line breaks are
    /// kept: the new words stand on the line of the first replaced word (an inserted word on the line of the word
    /// before it). A line left without words disappears. Timings follow by `refit`.
    mutating func replaceTokens(_ r: Range<Int>, with new: [String]) {
        let timed = hasWordTimings, old = words
        // Each word remembers whether whitespace stood before it, so untouched words keep their spacing (CJK has none); nil = first of its line, the seam rule decides.
        var perLine: [[(text: String, gap: Bool?)]] = lines.map { line in
            let chars = Array(line)
            return WordSegmentation.spans(chars).map { (text: String(chars[$0]), gap: $0.lowerBound > 0 ? chars[$0.lowerBound - 1].isWhitespace : nil) }
        }
        var flat: [(line: Int, k: Int)] = []
        for (l, toks) in perLine.enumerated() { for k in toks.indices { flat.append((l, k)) } }
        guard r.lowerBound >= 0, r.upperBound <= flat.count else { return }
        var target: (line: Int, k: Int)
        if !r.isEmpty { target = flat[r.lowerBound] }
        else if r.lowerBound > 0 { let p = flat[r.lowerBound - 1]; target = (p.line, p.k + 1) }
        else if let f = flat.first { target = f }
        else { if perLine.isEmpty { perLine = [[]] }; target = (0, 0) }
        // The first new word takes the spacing of the first word it replaces.
        let inherited: Bool? = r.isEmpty ? nil : perLine[flat[r.lowerBound].line][flat[r.lowerBound].k].gap
        for i in r.reversed() { perLine[flat[i].line].remove(at: flat[i].k) }
        var fresh: [(text: String, gap: Bool?)] = new.map { (text: $0, gap: nil) }
        if !fresh.isEmpty { fresh[0].gap = inherited }
        perLine[target.line].insert(contentsOf: fresh, at: target.k)
        let rebuilt = perLine.filter { !$0.isEmpty }.map { line -> String in
            var s = ""
            for w in line {
                if !s.isEmpty, w.gap ?? !WordSegmentation.isTight(s, w.text) { s += " " }
                s += w.text
            }
            return s
        }
        lines = rebuilt.isEmpty ? [""] : rebuilt
        words = timed ? Self.refit(old, replacing: r, with: new, duration: range.duration) : []
    }

    /// New text with the timings following it: the words both texts share at the start and at the end keep their
    /// time, the changed middle is refitted (`refit`). Without timings the caption stays without them.
    public mutating func setLinesRefittingWords(_ newLines: [String]) {
        let timed = hasWordTimings, oldToks = tokens, old = words
        lines = newLines
        guard timed else { words = []; return }
        let new = tokens
        let n = min(oldToks.count, new.count)
        var p = 0
        while p < n, oldToks[p] == new[p] { p += 1 }
        var s = 0
        while s < n - p, oldToks[oldToks.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        words = Self.refit(old, replacing: p..<(oldToks.count - s), with: Array(new[p..<(new.count - s)]), duration: range.duration)
    }

    /// Character spans of the words of a line.
    static func wordSpans(_ chars: [Character]) -> [Range<Int>] {
        WordSegmentation.spans(chars)
    }

    /// Replaces the characters `r` of line `line`. The timings follow by position, not by text: a word that stands
    /// whole before or after the replaced characters keeps its time (in "the the cat" with the first "the " removed,
    /// the second "the" keeps its own), only the words the replacement touches are refitted. A line left without words
    /// disappears; a caption left without words is for the caller to remove. Out-of-range input is ignored (false).
    @discardableResult
    mutating func replaceCharacters(_ r: Range<Int>, inLine line: Int, with new: String) -> Bool {
        guard lines.indices.contains(line) else { return false }
        let chars = Array(lines[line])
        guard r.lowerBound >= 0, r.upperBound <= chars.count else { return false }
        let timed = hasWordTimings, old = words
        let base = lines[..<line].reduce(0) { $0 + Self.wordSpans(Array($1)).count }
        let after = Array(chars[..<r.lowerBound]) + Array(new) + Array(chars[r.upperBound...])
        let was = Self.wordSpans(chars), now = Self.wordSpans(after)
        let shift = new.count - r.count, shared = min(was.count, now.count)
        var p = 0
        while p < shared, was[p].upperBound <= r.lowerBound, now[p] == was[p] { p += 1 }
        var s = 0
        while s < shared - p {
            let a = was[was.count - 1 - s], b = now[now.count - 1 - s]
            guard a.lowerBound >= r.upperBound, b == (a.lowerBound + shift)..<(a.upperBound + shift) else { break }
            s += 1
        }
        lines[line] = String(after)
        lines.removeAll { $0.allSatisfy(\.isWhitespace) }
        if lines.isEmpty { lines = [""] }
        let fresh = now[p..<(now.count - s)].map { String(after[$0]) }
        words = timed ? Self.refit(old, replacing: (base + p)..<(base + was.count - s), with: fresh, duration: range.duration) : []
        return true
    }

    /// Every match of `find`, line by line, left to right, not overlapping. The case option is the only one (no
    /// diacritic folding), so what is counted is what a replace changes.
    func textMatches(find: String, caseSensitive: Bool) -> [(line: Int, range: Range<Int>, words: ClosedRange<Int>)] {
        guard !find.isEmpty else { return [] }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var out: [(line: Int, range: Range<Int>, words: ClosedRange<Int>)] = []
        var base = 0
        for (li, line) in lines.enumerated() {
            // Character spans of the words of this line.
            let spans = WordSegmentation.spans(of: line)
            defer { base += spans.count }
            guard line.range(of: find, options: opts) != nil else { continue }
            var rest = line[...]
            while let r = rest.range(of: find, options: opts), !r.isEmpty {
                let a = line.distance(from: line.startIndex, to: r.lowerBound), b = line.distance(from: line.startIndex, to: r.upperBound)
                let touched = spans.indices.filter { spans[$0].upperBound > a && spans[$0].lowerBound < b }
                let lo = touched.first ?? min(spans.firstIndex { $0.lowerBound >= a } ?? max(spans.count - 1, 0), max(spans.count - 1, 0))
                let hi = touched.last ?? lo
                out.append((li, a..<b, (base + lo)...(base + hi)))
                rest = rest[r.upperBound...]
            }
        }
        return out
    }
}

extension CaptionTrack {
    /// Replaces word `index` by the words of `text` (several when it holds spaces, none when it is empty: the word is
    /// deleted; the caption goes with its last word). Returns how many words stand there now, nil for unknown input.
    mutating func setWord(_ id: CaptionItem.ID, index: Int, text: String) -> Int? {
        let new = WordSegmentation.words(text)
        return withItems { items in
            guard let i = items.firstIndex(where: { $0.id == id }), items[i].tokens.indices.contains(index) else { return nil }
            items[i].replaceTokens(index..<(index + 1), with: new)
            if items[i].tokens.isEmpty { items.remove(at: i) }
            return new.count
        }
    }

    /// Inserts the words of `text` before word `index` (`tokens.count` = at the end). Returns the number inserted.
    mutating func insertWord(_ id: CaptionItem.ID, at index: Int, text: String) -> Int? {
        let new = WordSegmentation.words(text)
        return withItems { items in
            guard let i = items.firstIndex(where: { $0.id == id }), index >= 0, index <= items[i].tokens.count else { return nil }
            if !new.isEmpty { items[i].replaceTokens(index..<index, with: new) }
            return new.count
        }
    }

    /// Splits so that word `k` starts the second caption. The cut never lands inside a word: it is the frame (`snap`)
    /// nearest to where that word starts or to where the word before ends, when that frame lies in the pause between
    /// the two; else it is the word boundary itself, off the frame grid. So no word is cut short. The halves touch.
    mutating func split(_ id: CaptionItem.ID, beforeWord k: Int, snap: (Time) -> Time) -> (CaptionItem.ID, CaptionItem.ID)? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items[i].range, eff = items[i].effectiveWords
        guard k > 0, k < eff.count else { return nil }
        let lo = eff[k - 1].range.end, hi = max(eff[k].range.start, lo)
        func fits(_ t: Time) -> Bool { t > r.start && t < r.end && t >= lo && t <= hi }
        guard let t = [snap(hi), snap(lo), hi, lo].first(where: fits) else { return nil }
        return splitItem(at: i, time: t, leftWords: k)
    }

    /// The item before or after `id`.
    func neighbor(of id: CaptionItem.ID, _ side: CaptionNeighbor) -> CaptionItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let j = side == .next ? i + 1 : i - 1
        return items.indices.contains(j) ? items[j] : nil
    }

    /// Moves one edge of word `index` to timeline time `t`. Nothing ripples: the edge stops at the neighboring word and
    /// at the caption's own edges, and the word keeps at least `minDuration` (one already shorter cannot shrink).
    /// With `rolling`, an edge that touches the neighboring word takes that word's edge along (the boundary between the
    /// two moves; the neighbor keeps `minDuration`). A caption without timings gets them here, from its spread words.
    /// Returns the word's new range on the timeline.
    mutating func retimeWord(_ id: CaptionItem.ID, index: Int, edge: ClipEdge, to t: Time, minDuration: Time, rolling: Bool) -> TimeRange? {
        withItems { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
            let origin = items[i].range.start, d = items[i].range.duration
            var w = CaptionTrack.relativeWords(items[i].effectiveWords, to: items[i].range)
            guard w.indices.contains(index) else { return nil }
            let cur = w[index].range, rel = t - origin
            switch edge {
            case .head:
                let prev = index > 0 ? w[index - 1].range : nil
                let rolls = rolling && prev.map { $0.end >= cur.start } == true
                let lo = prev.map { rolls ? min($0.end, $0.start + minDuration) : $0.end } ?? .zero
                let hi = max(cur.start, cur.end - minDuration)
                let s = min(max(rel, lo), hi)
                w[index].range = TimeRange(start: s, end: cur.end)
                if rolls, let prev { w[index - 1].range = TimeRange(start: min(prev.start, s), end: s) }
            case .tail:
                let next = index + 1 < w.count ? w[index + 1].range : nil
                let rolls = rolling && next.map { $0.start <= cur.end } == true
                let hi = next.map { rolls ? max($0.start, $0.end - minDuration) : $0.start } ?? max(d, cur.end)
                let lo = min(cur.end, cur.start + minDuration)
                let e = max(min(rel, hi), lo)
                w[index].range = TimeRange(start: cur.start, end: e)
                if rolls, let next { w[index + 1].range = TimeRange(start: e, end: max(next.end, e)) }
            }
            items[i].words = w
            return TimeRange(start: origin + w[index].range.start, end: origin + w[index].range.end)
        }
    }
}

extension Timeline {
    /// Replaces one word of a caption by `text` (see `CaptionTrack.setWord`): several words when it holds spaces,
    /// deletion when it is empty. Returns the number of words that stand there now.
    @discardableResult
    public mutating func setCaptionWord(_ id: CaptionItem.ID, index: Int, text: String) throws -> Int {
        let i = try captionLocation(id)
        guard let n = captionTracks[i].setWord(id, index: index, text: text) else { throw EditError.clipNotFound }
        return n
    }

    /// Deletes one word; its time becomes a pause. The caption goes with its last word.
    public mutating func deleteCaptionWord(_ id: CaptionItem.ID, index: Int) throws {
        try setCaptionWord(id, index: index, text: "")
    }

    /// Inserts the words of `text` before word `index` (`tokens.count` appends). Returns the number inserted.
    @discardableResult
    public mutating func insertCaptionWord(_ id: CaptionItem.ID, at index: Int, text: String) throws -> Int {
        let i = try captionLocation(id)
        guard let n = captionTracks[i].insertWord(id, at: index, text: text) else { throw EditError.clipNotFound }
        return n
    }

    /// Splits a caption at a word boundary: word `index` starts the second caption. Word timings stay with their words.
    @discardableResult
    public mutating func splitCaption(_ id: CaptionItem.ID, beforeWord index: Int) throws -> (CaptionItem.ID, CaptionItem.ID) {
        let i = try captionLocation(id)
        let fd = frameDuration
        guard let r = captionTracks[i].split(id, beforeWord: index, snap: { $0.snapped(to: fd) }) else { throw EditError.emptyClip }
        return r
    }

    /// Joins a caption with the one before or after it (word timings are kept). Returns the joined caption's ID.
    @discardableResult
    public mutating func joinCaption(_ id: CaptionItem.ID, with side: CaptionNeighbor) throws -> CaptionItem.ID {
        let i = try captionLocation(id)
        guard let other = captionTracks[i].neighbor(of: id, side) else { throw EditError.clipNotFound }
        guard let m = captionTracks[i].merge([id, other.id]) else { throw EditError.emptyClip }
        return m
    }

    /// Moves one edge of a word to `t` (see `CaptionTrack.retimeWord`: clamped at the neighboring word and the caption,
    /// one frame minimum, nothing ripples). Returns the word's new range.
    @discardableResult
    public mutating func retimeCaptionWord(_ id: CaptionItem.ID, index: Int, edge: ClipEdge, to t: Time, rolling: Bool = true) throws -> TimeRange {
        let i = try captionLocation(id)
        guard let r = captionTracks[i].retimeWord(id, index: index, edge: edge, to: t, minDuration: frameDuration, rolling: rolling)
        else { throw EditError.clipNotFound }
        return r
    }

    /// Every match of `find` on the caption tracks (one track with `track`), in time order. Locked tracks are searched
    /// too; replacing there throws.
    public func captionTextMatches(find: String, caseSensitive: Bool, track: CaptionTrack.ID? = nil) -> [CaptionTextMatch] {
        guard !find.isEmpty else { return [] }
        var out: [CaptionTextMatch] = []
        for t in captionTracks where track == nil || t.id == track {
            for item in t.items {
                for m in item.textMatches(find: find, caseSensitive: caseSensitive) {
                    out.append(CaptionTextMatch(track: t.id, caption: item.id, line: m.line, range: m.range, words: m.words, time: item.range.start))
                }
            }
        }
        // Stable by time: matches of one caption keep their reading order.
        return out.enumerated().sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }.map(\.element)
    }

    /// Replaces one match (from `captionTextMatches` of the current timeline) by `new`; word timings follow the text.
    public mutating func replaceCaptionMatch(_ m: CaptionTextMatch, with new: String) throws {
        let i = try captionLocation(m.caption)
        let ok = captionTracks[i].withItems { items -> Bool in
            guard let k = items.firstIndex(where: { $0.id == m.caption }) else { return false }
            guard items[k].replaceCharacters(m.range, inLine: m.line, with: new) else { return false }
            if items[k].tokens.isEmpty { items.remove(at: k) }       // the caption goes with its last word
            return true
        }
        guard ok else { throw EditError.clipNotFound }
    }
}
