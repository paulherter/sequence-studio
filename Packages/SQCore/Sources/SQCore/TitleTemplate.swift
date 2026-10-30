import Foundation

// Title templates (TEMPLATE-ECOSYSTEM T1/T2, DECISIONS 2026-10-06): several layers (text, shape, graphic) saved as ONE
// template, applied as ONE nested clip. The template is a nested-sequence snapshot (`content`, layers from time 0) plus
// editable slots (text, color, font, number: a key path into a layer's generator payload JSON) and animation zones
// (intro/outro keep their length when the applied clip is trimmed; AnimationZones.swift). Applying copies the snapshot
// into a new inner sequence with fresh ids, so every use is independent; the clip remembers its slots (`Clip.templateSlots`,
// v58) so the text can be changed later without opening the nest.
//
// SQCore does not know the text payload type (SQText): slots address payload JSON by dot path, e.g. "template.text",
// "template.style.color", "template.style.fontName", "template.style.size".

public enum TitleTemplateError: Error, Equatable, Sendable {
    /// Auto-detect found no keyframes on the clip.
    case noKeyframes
    /// The slot's path does not exist in its layer's payload (or the layer is not a generator).
    case slotPathNotFound(String)
    /// The clip has no slot with this id, or is not an applied template.
    case slotNotFound
    /// A template file written by a newer app.
    case newerFormat(found: Int, supported: Int)
}

/// What a layer of a template is.
public enum TemplateLayerKind: String, Sendable, Hashable, Codable {
    case text, shape, graphic, other

    init(generator kind: String?) {
        switch kind {
        case GeneratorRef.text: self = .text
        case GeneratorRef.shape: self = .shape
        case GeneratorRef.graphics, GeneratorRef.lottie, GeneratorRef.solid: self = .graphic
        default: self = .other
        }
    }
}

/// One layer of a template: a clip of `TitleTemplate.content`.
public struct TemplateLayer: Sendable, Hashable {
    public var clip: Clip.ID
    public var name: String
    public var kind: TemplateLayerKind
}

/// A value a slot can hold.
public enum SlotValue: Sendable, Hashable, Codable {
    case text(String)
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    case font(String)
    case number(Double)

    /// The payload JSON value (a color is written like SQText's `RGBAColor`).
    var json: Any {
        switch self {
        case let .text(s), let .font(s): s
        case let .number(n): n
        case let .color(r, g, b, a): ["red": r, "green": g, "blue": b, "alpha": a]
        }
    }
}

/// An editable value of a template: one key path in one layer's generator payload.
public struct TemplateSlot: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case text, color, font, number }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// The layer clip (inside the template content, or inside the applied clip's inner sequence).
    public var layer: Clip.ID
    /// v62: when `layer` is a graphics clip, the text layer inside it that `path` addresses (its `GeneratorRef` payload).
    /// nil = the clip's own generator payload.
    public var graphicsLayer: UUID?
    /// Dot path into the layer's generator payload JSON.
    public var path: String
    /// Current (template: default) value.
    public var value: SlotValue

    public init(id: UUID = UUID(), name: String, kind: Kind, layer: Clip.ID, graphicsLayer: UUID? = nil, path: String,
                value: SlotValue) {
        self.id = id; self.name = name; self.kind = kind; self.layer = layer; self.graphicsLayer = graphicsLayer
        self.path = path; self.value = value
    }
}

public struct TitleTemplate: Sendable, Hashable, Codable, Identifiable {
    /// On-disk format of a template (PresetStore payload, packs). Raise when a field changes meaning.
    public static let formatVersion = 5
    /// Format 3 when a graphics layer of the content follows another (G11, `GraphicsLayer.follow`); 2 when some slot
    /// addresses a graphics layer (`TemplateSlot.graphicsLayer`). An older build then refuses the template (`newerFormat`)
    /// instead of dropping the field. Format 4 when layers carry Fast Cut attachments (v67 field). Format 5 when an item
    /// of a Graphic has a range (`GraphicsLayer.range`, v74 field): an older build would draw it for the whole clip.
    /// Plain templates stay format 1, byte-identical.
    public var writtenFormatVersion: Int {
        if content.containsItemRanges { return 5 }
        if content.hasAttachments { return 4 }
        if content.containsFollow { return 3 }
        return slots.contains { $0.graphicsLayer != nil } ? 2 : 1
    }

    public var id: UUID
    public var name: String
    /// Library grouping (Titles, Lower thirds, Captions, Social ...); nil = uncategorised.
    public var category: String?
    /// The nested-sequence snapshot: layers on video tracks (bottom first), starting at 0.
    public var content: Timeline
    public var slots: [TemplateSlot]
    /// Template-level zones; `designDuration` is the template length.
    public var zones: AnimationZones

    public init(id: UUID = UUID(), name: String, category: String? = nil, content: Timeline, slots: [TemplateSlot] = [],
                zones: AnimationZones? = nil) {
        self.id = id; self.name = name; self.category = category; self.content = content; self.slots = slots
        let d = content.duration
        var z = zones ?? AnimationZones(introEnd: .zero, outroLength: .zero, designDuration: d)
        z.designDuration = d
        self.zones = z
    }

    /// Default length: the content's.
    public var duration: Time { content.duration }

    /// Every layer, bottom track first.
    public var layers: [TemplateLayer] {
        content.tracks.filter { $0.kind == .video }.flatMap { t in
            t.clips.map { TemplateLayer(clip: $0.id, name: $0.name, kind: TemplateLayerKind(generator: $0.generator?.kind)) }
        }
    }

    /// Zones from the first/last keys of every layer (`AnimationZones.detect`); `extraKeyTimes` (content time) adds keys
    /// SQCore cannot see, such as a text layer's anchored in/out animation.
    public static func detectZones(in content: Timeline, extraKeyTimes: [Time] = []) -> AnimationZones {
        let d = content.duration
        var times = extraKeyTimes
        for t in content.tracks where t.kind == .video { for c in t.clips { times += c.keyframeTimes.map { $0 + c.start } } }
        return AnimationZones.detect(keyTimes: times, duration: d, designDuration: d)
            ?? AnimationZones(introEnd: .zero, outroLength: .zero, designDuration: d)
    }

    /// Save as Template: the video clips `ids` of `timeline` become one template (shifted so the earliest starts at 0,
    /// one content track per involved track, transitions between them kept). Each text layer gets a text slot
    /// ("Text 1", "Text 2" ...); zones are auto-detected. Throws `.emptyClip` (no ids / no video clip),
    /// `.clipNotFound`, `.timelineNotFound`.
    public static func capture(clips ids: [Clip.ID], in timeline: Timeline.ID, of project: Project, name: String,
                               extraKeyTimes: [Time] = []) throws -> TitleTemplate {
        guard let tl = project.timeline(timeline) else { throw EditError.timelineNotFound }
        guard !ids.isEmpty else { throw EditError.emptyClip }
        let all = Set(tl.tracks.flatMap { $0.clips.map(\.id) })
        guard ids.allSatisfy(all.contains) else { throw EditError.clipNotFound }
        let wanted = Set(ids)
        let involved = tl.tracks.filter { $0.kind == .video && $0.clips.contains { wanted.contains($0.id) } }
        let picked = involved.flatMap { $0.clips.filter { wanted.contains($0.id) } }
        guard let s = picked.map(\.start).min() else { throw EditError.emptyClip }
        var trackIDs: [Track.ID: Track.ID] = [:]
        let tracks = involved.map { t in
            let clips = t.clips.filter { wanted.contains($0.id) }.map { c -> Clip in var c = c; c.start = c.start - s; return c }
            let carried = t.transitions.filter { tr in
                (tr.outgoing.map(wanted.contains) ?? true) && (tr.incoming.map(wanted.contains) ?? true)
            }
            let n = Track(kind: .video, clips: clips, syncLock: t.syncLock, name: t.name, isVisible: t.isVisible,
                          height: t.height, transitions: carried)
            trackIDs[t.id] = n.id
            return n
        }
        var content = Timeline(name: name, format: tl.format, tracks: tracks)
        content.remapPictureMasks(trackIDs: trackIDs)
        content.dropAttachmentsToMissingHosts()
        var slots: [TemplateSlot] = []
        for c in picked.sorted(by: { a, b in
            let ia = involved.firstIndex { $0.clips.contains { $0.id == a.id } } ?? 0
            let ib = involved.firstIndex { $0.clips.contains { $0.id == b.id } } ?? 0
            return ia != ib ? ia < ib : a.start < b.start
        }) {
            let path = "template.text"
            if c.generator?.kind == GeneratorRef.text {
                let text = (try? PayloadPath.value(at: path, in: c.generator!.payload)) as? String ?? ""
                slots.append(TemplateSlot(name: "Text \(slots.count + 1)", kind: .text, layer: c.id, path: path, value: .text(text)))
            } else if c.isGraphics, let doc = c.graphics {
                // v62: each text layer of a graphics clip is a field of its own.
                for l in doc.layers {
                    guard case let .text(ref) = l.content else { continue }
                    let text = (try? PayloadPath.value(at: path, in: ref.payload)) as? String ?? ""
                    slots.append(TemplateSlot(name: "Text \(slots.count + 1)", kind: .text, layer: c.id, graphicsLayer: l.id,
                                              path: path, value: .text(text)))
                }
            }
        }
        return TitleTemplate(name: name, content: content, slots: slots,
                             zones: detectZones(in: content, extraKeyTimes: extraKeyTimes))
    }

    /// The content with fresh ids for the inner sequence, every track, clip, transition, link and bundle, and the slots
    /// pointing at the new layer ids (slot ids stay, so callers can address them by the template's slot ids).
    func instantiated() -> (Timeline, [TemplateSlot]) {
        let (inner, clipMap) = content.copyWithFreshIDs()
        let slots = self.slots.map { s in var s = s; s.layer = clipMap[s.layer] ?? s.layer; return s }
        return (inner, slots)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, id, name, category, content, slots, zones }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        if v > Self.formatVersion { throw TitleTemplateError.newerFormat(found: v, supported: Self.formatVersion) }
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  category: try c.decodeIfPresent(String.self, forKey: .category),
                  content: try c.decode(Timeline.self, forKey: .content),
                  slots: try c.decodeIfPresent([TemplateSlot].self, forKey: .slots) ?? [],
                  zones: try c.decodeIfPresent(AnimationZones.self, forKey: .zones))
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(writtenFormatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encode(content, forKey: .content)
        try c.encode(slots, forKey: .slots)
        try c.encode(zones, forKey: .zones)
    }
}

/// Dot-path access into a generator payload's JSON object.
enum PayloadPath {
    static func value(at path: String, in payload: Data) throws -> Any {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty, var node = try? JSONSerialization.jsonObject(with: payload) else {
            throw TitleTemplateError.slotPathNotFound(path)
        }
        for k in keys {
            guard let d = node as? [String: Any], let next = d[k] else { throw TitleTemplateError.slotPathNotFound(path) }
            node = next
        }
        return node
    }

    /// The payload with the existing value at `path` replaced (keys sorted, like SQText writes it).
    static func setting(_ value: Any, at path: String, in payload: Data) throws -> Data {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty, var root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw TitleTemplateError.slotPathNotFound(path)
        }
        func set(_ d: inout [String: Any], _ k: ArraySlice<String>) throws {
            guard let key = k.first, d[key] != nil else { throw TitleTemplateError.slotPathNotFound(path) }
            if k.count == 1 { d[key] = value; return }
            guard var sub = d[key] as? [String: Any] else { throw TitleTemplateError.slotPathNotFound(path) }
            try set(&sub, k.dropFirst())
            d[key] = sub
        }
        try set(&root, keys[...])
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

extension Timeline {
    /// Writes `value` into the payload of the generator layer `layer` at `path`. Throws `.slotPathNotFound`.
    mutating func setSlot(layer: Clip.ID, graphicsLayer: UUID? = nil, path: String, value: SlotValue) throws {
        for i in tracks.indices {
            guard var c = tracks[i].clips.first(where: { $0.id == layer }) else { continue }
            if let graphicsLayer {
                guard var doc = c.graphics, let k = doc.index(of: graphicsLayer), case var .text(ref) = doc.layers[k].content else {
                    throw TitleTemplateError.slotPathNotFound(path)
                }
                ref.payload = try PayloadPath.setting(value.json, at: path, in: ref.payload)
                doc.layers[k].content = .text(ref: ref)
                c.graphics = doc
                tracks[i].replace(c)
                return
            }
            guard var g = c.generator else { throw TitleTemplateError.slotPathNotFound(path) }
            g.payload = try PayloadPath.setting(value.json, at: path, in: g.payload)
            c.generator = g
            tracks[i].replace(c)
            return
        }
        throw TitleTemplateError.slotPathNotFound(path)
    }
}

extension Timeline {
    /// A copy with fresh ids for the timeline, every track, clip, transition, link and bundle. Returns the old -> new clip
    /// id map so callers can repoint what refers to clips of the copy.
    func copyWithFreshIDs() -> (Timeline, [Clip.ID: Clip.ID]) {
        var inner = self
        inner.id = UUID()
        var clipMap: [UUID: UUID] = [:], groupMap: [UUID: UUID] = [:]
        func fresh(_ id: UUID?, _ map: inout [UUID: UUID]) -> UUID? {
            guard let id else { return nil }
            if let n = map[id] { return n }
            let n = UUID(); map[id] = n; return n
        }
        var trackIDs: [Track.ID: Track.ID] = [:]
        for i in inner.tracks.indices {
            let old = inner.tracks[i].id
            inner.tracks[i].id = UUID()
            trackIDs[old] = inner.tracks[i].id
            inner.tracks[i].mapClipsKeepingTiming { c in
                var c = c
                let n = fresh(c.id, &clipMap)!
                if c.media == c.id { c.media = n }      // generators use their own id as media
                c.id = n
                c.link = fresh(c.link, &groupMap)
                c.bundle = fresh(c.bundle, &groupMap)
                return c
            }
            inner.tracks[i].transitions = inner.tracks[i].transitions.map { tr in
                var tr = tr
                tr.id = UUID()
                tr.outgoing = tr.outgoing.map { clipMap[$0] ?? $0 }
                tr.incoming = tr.incoming.map { clipMap[$0] ?? $0 }
                return tr
            }
        }
        inner.remapPictureMasks(trackIDs: trackIDs)
        inner.remapAttachments(clipMap)
        return (inner, clipMap)
    }
}

extension Project {
    /// Inner sequences of applied title template clips. They are not filed in bins (`normalizeBins`).
    public var titleTemplateInsides: Set<Timeline.ID> {
        var out = Set<Timeline.ID>()
        for t in timelines { for tr in t.tracks { for c in tr.clips where c.templateSlots != nil { if let s = c.sequence { out.insert(s) } } } }
        return out
    }

    /// Applies a title template as ONE nested clip on video track `track` of `timeline` at `start` (overwrite), `duration`
    /// long (default: the template's, in whole host frames). The content is copied into a new inner sequence with fresh
    /// ids; `values` replace slot values (by the template's slot ids). The clip carries the template's zones, so trimming
    /// it keeps the intro and outro whole. One mutation: one undo step. Throws `.timelineNotFound`, `.clipNotFound`
    /// (track), `.wrongTrackKind`, `.trackLocked`, `.emptyClip`, `TitleTemplateError.slotPathNotFound`.
    @discardableResult
    public mutating func applyTitleTemplate(_ template: TitleTemplate, in timeline: Timeline.ID, track: Track.ID, at start: Time,
                                            duration: Time? = nil, values: [TemplateSlot.ID: SlotValue] = [:]) throws -> Clip.ID {
        guard let host = self.timeline(timeline) else { throw EditError.timelineNotFound }
        guard let tr = host.tracks.firstIndex(where: { $0.id == track }) else { throw EditError.clipNotFound }
        guard host.tracks[tr].kind == .video else { throw EditError.wrongTrackKind }
        guard !host.tracks[tr].isLocked else { throw EditError.trackLocked }
        let fd = host.frameDuration
        guard template.duration > .zero, start >= .zero else { throw EditError.emptyClip }
        let len = max((duration ?? template.duration).snapped(to: fd), fd)

        var (inner, slots) = template.instantiated()
        for i in slots.indices {
            if let v = values[slots[i].id] { slots[i].value = v }
            if values[slots[i].id] != nil || slots[i].value != template.slots[i].value {
                try inner.setSlot(layer: slots[i].layer, graphicsLayer: slots[i].graphicsLayer, path: slots[i].path, value: slots[i].value)
            }
        }
        var c = Clip(name: template.name, media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: len),
                     start: start, mediaDuration: template.duration, sequence: inner.id)
        c.zones = template.zones
        c.templateSlots = slots
        var work = self
        work.timelines.append(inner)
        try work.edit(timeline) { try $0.tracks[tr].overwrite(c) }
        self = work
        return c.id
    }

    /// Changes one slot of an applied template clip: writes the value into its layer inside the clip's inner sequence and
    /// remembers it on the clip. One mutation: one undo step. Throws `.clipNotFound`, `.trackLocked`,
    /// `TitleTemplateError.slotNotFound` / `.slotPathNotFound`.
    public mutating func setTemplateSlot(_ slot: TemplateSlot.ID, to value: SlotValue, clip id: Clip.ID) throws {
        var work = self
        var target: (Timeline.ID, TemplateSlot)?
        // Copy on write: a copy of an applied clip shares the inner sequence until one of them is edited, then that one
        // gets its own copy (fresh ids, slots repointed), so the other keeps its text.
                let uses = allClips().filter { $0.templateSlots != nil && $0.sequence != nil }
        var fork: Timeline?
        var clipMap: [Clip.ID: Clip.ID] = [:]
        if let me = uses.first(where: { $0.id == id }), let seq = me.sequence,
           uses.filter({ $0.sequence == seq }).count > 1, let inner = timeline(seq) {
            (fork, clipMap) = inner.copyWithFreshIDs()
        }
        try work.modifyClipForZones(id) { c in
            guard let seq = c.sequence, var slots = c.templateSlots, let k = slots.firstIndex(where: { $0.id == slot }) else {
                throw TitleTemplateError.slotNotFound
            }
            if let fork {
                for i in slots.indices { slots[i].layer = clipMap[slots[i].layer] ?? slots[i].layer }
                c.sequence = fork.id
                if c.media == seq { c.media = fork.id }
            }
            slots[k].value = value
            c.templateSlots = slots
            target = (fork?.id ?? seq, slots[k])
        }
        if let fork { work.timelines.append(fork) }
        guard let (seq, s) = target, let ti = work.timelines.firstIndex(where: { $0.id == seq }) else {
            throw TitleTemplateError.slotNotFound
        }
        try work.timelines[ti].setSlot(layer: s.layer, graphicsLayer: s.graphicsLayer, path: s.path, value: value)
        self = work
    }
}
