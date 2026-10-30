import Foundation

// COLOR-GRADE-LINKS (v45, docs/proposals/COLOR-GRADE-LINKS.md).
// Linked grades: clips with the same `Clip.gradeLink` share their base grade (every Color effect without a range: values,
// keys, switches, LUTs, curves). Every member keeps a full copy (denormalised), so rendering and the panels need no lookup;
// `Project.propagateGradeLinks(from:)` copies an edited member's base grade onto the others after each edit.
// Range grades: a Color effect with `colorRange` (clip-local) grades only that part of the clip, on top of the base grade.

extension ClipEffect {
    /// A Color effect that grades a part of the clip only.
    public var isRangeGrade: Bool { isColor && colorRange != nil }
}

extension Clip {
    /// The Color effects a grade link shares: every Color effect without a range, in order.
    public var baseGradeEffects: [ClipEffect] { effects.filter { $0.isColor && $0.colorRange == nil } }

    /// `fx` without effect ids, to compare grades.
    static func comparableGrade(_ fx: [ClipEffect]) -> [ClipEffect] {
        fx.map { var c = $0; c.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); return c }
    }

    /// `comparableGrade` without key times (keys in id order): what is left of a grade when a trim, retime or crop moved
    /// its keys. Those moves are no grade edit.
    static func timingFreeGrade(_ fx: [ClipEffect]) -> [ClipEffect] {
        func strip<V>(_ p: AnimatedProperty<V>) -> AnimatedProperty<V> {
            var c = p
            c.track.keys = p.track.keys.map { var k = $0; k.time = .zero; return k }.sorted { $0.id.uuidString < $1.id.uuidString }
            return c
        }
        return comparableGrade(fx).map { e in
            var c = e
            c.parameters = e.parameters.mapValues { strip($0) }
            c.colors = e.colors.mapValues { strip($0) }
            c.points = e.points.mapValues { strip($0) }
            return c
        }
    }

    /// Same place, length, speed and direction: an edit that changes none of these cannot have moved keys.
    func hasSameTiming(as o: Clip) -> Bool {
        start == o.start && source == o.source && speed == o.speed && reversed == o.reversed && speedKeys == o.speedKeys
            && holdFrame == o.holdFrame
    }

    /// Replaces the base grade with copies of `fx`, keeping this clip's own effect ids and the place of its range grades
    /// (base slot n takes `fx[n]`; extra effects go after the last base slot, missing ones are removed). The conversion
    /// LUT and the look are media-specific: an embedded LUT of other media falls back (`adaptingLUTs`), a clip's own
    /// embedded LUT stays, and when `previous` (the source's base grade before the edit) shows the slot did not change, this
    /// clip keeps whatever it had there, so an adapted copy never travels back. Keys are moved from `src`'s clip-local
    /// time to this clip's through the source time both play (`mappingKeyTimes`). Ignored on clips that take no color.
    mutating func replaceBaseGrade(with fx: [ClipEffect], previous: [ClipEffect]? = nil, from src: Clip? = nil) {
        guard acceptsColor else { return }
        // The source's Pro grade (and Simple | Pro) goes along, same rule as a paste.
        if let src { applyCopiedGraph(src.colorGraph) }
        let incoming = fx.filter { $0.isColor }
        let colour = effects.filter(\.isColor)
        var out: [ClipEffect] = []
        var n = 0
        func next(_ own: ClipEffect?) -> ClipEffect {
            let e = incoming[n]
            var c = (src.map { mappingKeyTimes(of: e, from: $0) } ?? e).adaptingLUTs(toMedia: media, primary: n == 0)
            c.id = own?.id ?? UUID()
            c.colorRange = nil
            if let own {
                var d = c.colorData
                let mine = own.colorData, prev = previous.flatMap { n < $0.count ? $0[n].colorData : nil }
                if prev?.inputLUT == e.colorData.inputLUT || Self.isOwnEmbedded(mine.inputLUT, media: media) && Self.isEmbedded(e.colorData.inputLUT) {
                    d.inputLUT = n == 0 ? mine.inputLUT : (mine.inputLUT == .automatic ? nil : mine.inputLUT)
                }
                if prev?.look == e.colorData.look || Self.isOwnEmbedded(mine.look, media: media) && Self.isEmbedded(e.colorData.look) {
                    d.look = mine.look
                }
                c.grade = d
            }
            n += 1
            return c
        }
        var lastBase = -1
        for e in colour {
            if e.isRangeGrade { out.append(e); continue }
            guard n < incoming.count else { continue }
            out.append(next(e))
            lastBase = out.count - 1
        }
        var extra: [ClipEffect] = []
        while n < incoming.count { extra.append(next(nil)) }
        out.insert(contentsOf: extra, at: lastBase + 1)
        if let first = out.first, first.isRangeGrade { out.insert(Self.neutralBaseGrade(), at: 0) }
        effects.removeAll { $0.isColor }
        effects.insert(contentsOf: out, at: 0)
    }

    /// `e` (a Color effect of `src`) with its key times moved from `src`'s clip-local time to this clip's, through the
    /// source time both play: linked cuts of one source take a key on the same frame of the footage. Other media,
    /// generators, nested clips and freeze frames keep the times as they are.
    func mappingKeyTimes(of e: ClipEffect, from src: Clip) -> ClipEffect {
        guard src.id != id, src.media == media, !src.isGenerator, !isGenerator, !src.isNested, !isNested,
              src.holdFrame == nil, holdFrame == nil else { return e }
        func map<V>(_ p: AnimatedProperty<V>) -> AnimatedProperty<V> {
            guard !p.track.keys.isEmpty else { return p }
            var c = p
            c.track.keys = p.track.keys.map { k in
                var m = k
                m.time = localTime(forInstant: src.sourceInstant(atLocal: k.time))
                return m
            }.sorted { $0.time < $1.time }
            return c
        }
        var c = e
        c.parameters = e.parameters.mapValues { map($0) }
        c.colors = e.colors.mapValues { map($0) }
        c.points = e.points.mapValues { map($0) }
        return c
    }

    private static func isEmbedded(_ l: LUTRef?) -> Bool { if case .embedded? = l { return true }; return false }
    private static func isOwnEmbedded(_ l: LUTRef?, media: UUID) -> Bool { if case .embedded(let m)? = l { return m == media }; return false }

    /// The neutral first Color effect (automatic conversion), placed under a range grade on a clip without a grade.
    static func neutralBaseGrade() -> ClipEffect { ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic)) }

    /// `r` (clip-local) cut to the clip; nil when nothing is left.
    func clampedColorRange(_ r: TimeRange) -> TimeRange? {
        guard duration > .zero, let x = r.intersection(TimeRange(start: .zero, duration: duration)), x.duration > .zero else { return nil }
        return x
    }

    /// Adds a neutral Color effect that grades only `range` (clip-local, cut to the clip) behind the clip's Color effects.
    /// A clip without a grade first gets a neutral base effect (the first Color effect never takes a range). Returns the
    /// new effect's id, nil when the range misses the clip or the clip takes no color.
    @discardableResult
    public mutating func addRangeGrade(_ range: TimeRange) -> ClipEffect.ID? {
        guard acceptsColor, let r = clampedColorRange(range) else { return nil }
        if colorEffectIndices.isEmpty { effects.insert(Self.neutralBaseGrade(), at: 0) }
        var fx = ClipEffect.colorGrade(ColorEffect(id: colorEffectIndices.count + 1))
        fx.colorRange = r
        let at = (colorEffectIndices.last ?? -1) + 1
        effects.insert(fx, at: at)
        return fx.id
    }

    /// Sets (cut to the clip) or clears the range of Color effect `id`. Refused for the first Color effect, for other
    /// effects and for a range that misses the clip.
    @discardableResult
    public mutating func setColorRange(_ id: ClipEffect.ID, _ range: TimeRange?) -> Bool {
        let colour = colorEffectIndices
        guard let n = colour.firstIndex(where: { effects[$0].id == id }), n > 0 else { return false }
        if let range {
            guard let r = clampedColorRange(range) else { return false }
            effects[colour[n]].colorRange = r
        } else {
            effects[colour[n]].colorRange = nil
        }
        return true
    }

    /// A first Color effect that carries a range (its base effect was removed) gets a neutral base effect in front, so
    /// the range grade still grades only its range. True when something changed.
    mutating func ensureBaseUnderRangeGrades() -> Bool {
        guard let first = colorEffectIndices.first, effects[first].colorRange != nil else { return false }
        effects.insert(Self.neutralBaseGrade(), at: first)
        return true
    }

    /// Color effects that render at clip-local `t`: switched on, and (after the first one) inside their range.
    func colorEffectRenders(_ e: ClipEffect, position n: Int, atLocal t: Time) -> Bool {
        guard e.enabled else { return false }
        guard n > 0, let r = e.colorRange else { return true }
        return r.contains(t)
    }
}

extension Project {
    /// Runs `body` on every clip of every sequence (nested sequences are timelines of their own, so they are included).
    mutating func forEachClipInPlace(_ body: (inout Clip) -> Void) {
        for t in timelines.indices {
            for k in timelines[t].tracks.indices {
                timelines[t].tracks[k].mapClipsKeepingTiming { c in var c = c; body(&c); return c }
            }
        }
    }

    /// Every LUT file path a grade of any clip refers to (Input LUT and Creative look), each once, in first-seen order.
    public var referencedLUTFiles: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in allClips() {
            for fx in c.effects where fx.isColor {
                let d = fx.colorData
                for case .file(let p)? in [d.inputLUT, d.look] where seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    /// Rewrites LUT file paths in every grade through `map` (nil keeps the path). Not an edit: callers use it on the
    /// history-neutral amend path.
    public mutating func replaceLUTPaths(_ map: (String) -> String?) {
        func swap(_ r: LUTRef?) -> LUTRef? {
            if case .file(let p)? = r, let n = map(p), n != p { return .file(n) }
            return r
        }
        forEachClipInPlace { c in
            for i in c.effects.indices where c.effects[i].isColor {
                var d = c.effects[i].colorData
                d.inputLUT = swap(d.inputLUT); d.look = swap(d.look)
                c.effects[i].grade = d
            }
        }
    }

    func allClips() -> [Clip] { timelines.flatMap { $0.tracks.flatMap(\.clips) } }

    func anyClip(_ id: Clip.ID) -> Clip? {
        for t in timelines { for tr in t.tracks { if let c = tr.clips.first(where: { $0.id == id }) { return c } } }
        return nil
    }

    /// The clips sharing `id`'s grade, in project order (empty when it is not linked).
    public func gradeLinkMembers(of id: Clip.ID) -> [Clip.ID] {
        guard let l = anyClip(id)?.gradeLink else { return [] }
        return allClips().filter { $0.gradeLink == l }.map(\.id)
    }

    /// Links the picture clips of `ids` (plus `source`) so they share one grade: they take `source`'s base grade and its
    /// link (a new one when it has none). Clips leaving another group dissolve it when one member is left. nil (nothing
    /// changes) when fewer than two clips can take color.
    @discardableResult
    public mutating func linkGrades(_ ids: Set<Clip.ID>, source: Clip.ID) -> UUID? {
        guard let src = anyClip(source), src.acceptsColor else { return nil }
        let members = Set(allClips().filter { (ids.contains($0.id) || $0.id == source) && $0.acceptsColor }.map(\.id))
        guard members.count >= 2 else { return nil }
        let link = src.gradeLink ?? UUID()
        let base = src.baseGradeEffects
        forEachClipInPlace { c in
            guard members.contains(c.id) else { return }
            c.gradeLink = link
            c.gradeIndependent = false
            if c.id != source { c.replaceBaseGrade(with: base, from: src) }
        }
        dissolveLonelyGradeLinks()
        return link
    }

    /// Links every picture clip of `id`'s media in the project to `id`'s grade.
    @discardableResult
    public mutating func linkAllClipsOfSource(_ id: Clip.ID) -> UUID? {
        guard let src = anyClip(id), src.acceptsColor, !src.isGenerator, !src.isNested else { return nil }
        let same = allClips().filter { $0.media == src.media && $0.acceptsColor && !$0.isGenerator && !$0.isNested }.map(\.id)
        return linkGrades(Set(same), source: id)
    }

    /// Takes `ids` out of their grade links (each keeps its grade). A clip taken out has "Linked" off from then on
    /// (`gradeIndependent`, v47), so its next Color edit does not pull it back into its source's grade. True when a
    /// link changed.
    @discardableResult
    public mutating func unlinkGrades(_ ids: Set<Clip.ID>) -> Bool {
        var changed = false
        forEachClipInPlace { c in
            guard ids.contains(c.id), c.gradeLink != nil else { return }
            c.gradeLink = nil
            if c.isSourceGradeable { c.gradeIndependent = true }
            changed = true
        }
        if changed { dissolveLonelyGradeLinks() }
        return changed
    }

    /// A link with a single member is no link.
    mutating func dissolveLonelyGradeLinks() {
        var count: [UUID: Int] = [:]
        for c in allClips() { if let l = c.gradeLink { count[l, default: 0] += 1 } }
        let lonely = Set(count.filter { $0.value < 2 }.keys)
        guard !lonely.isEmpty else { return }
        forEachClipInPlace { c in if let l = c.gradeLink, lonely.contains(l) { c.gradeLink = nil } }
    }

    /// Runs after every edit (`old` = the project before it): the first member of each grade link (project order) whose base
    /// grade changed in the edit becomes the grade of the others; links left with one member dissolve; a range grade that
    /// became a clip's first Color effect gets a neutral base under it.
    public mutating func propagateGradeLinks(from old: Project) {
        var linked = false, rangeFix = false
        for c in allClips() {
            if c.gradeLink != nil { linked = true }
            if let f = c.effects.first(where: \.isColor), f.colorRange != nil { rangeFix = true }
        }
        if rangeFix { forEachClipInPlace { _ = $0.ensureBaseUnderRangeGrades() } }
        guard linked || old.allClips().contains(where: { $0.gradeLink != nil }) else { return }
        var before: [Clip.ID: Clip] = [:]
        for c in old.allClips() where c.gradeLink != nil { before[c.id] = c }
        // A member whose grade changed only because its keys moved with a trim, retime or crop is no source.
        var source: [UUID: (clip: Clip, fx: [ClipEffect], previous: [ClipEffect])] = [:]
        for c in allClips() {
            guard let l = c.gradeLink, source[l] == nil, let b = before[c.id] else { continue }
            let now = c.baseGradeEffects, was = b.baseGradeEffects
            let edited = c.hasSameTiming(as: b)
                ? Clip.comparableGrade(now) != Clip.comparableGrade(was)
                : Clip.timingFreeGrade(now) != Clip.timingFreeGrade(was)
            // The Pro grade has no keys: any change of it, or of Simple | Pro, is an edit.
            if edited || c.colorGraph != b.colorGraph { source[l] = (c, now, was) }
        }
        if !source.isEmpty {
            forEachClipInPlace { c in
                guard let l = c.gradeLink, let s = source[l], s.clip.id != c.id else { return }
                c.replaceBaseGrade(with: s.fx, previous: s.previous, from: s.clip)
            }
        }
        dissolveLonelyGradeLinks()
    }

    /// A Color effect holds a Color Range (HSL secondary): the file needs v48.
    public var containsColorRangeQualifiers: Bool {
        allClips().contains { c in
            c.effects.contains { $0.kind == ClipEffect.colorKind && $0.grade?.hslSecondary != nil }
        }
    }

    /// A grade link or a range grade exists: the file needs v45.
    public var containsGradeLinksOrRanges: Bool {
        allClips().contains { c in c.gradeLink != nil || c.effects.contains(where: \.isRangeGrade) }
    }
}
