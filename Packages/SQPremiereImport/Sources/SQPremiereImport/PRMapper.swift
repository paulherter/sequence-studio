import Foundation
import SQCore
import SQText

public struct PRImportResult: Sendable {
    public var project: Project
    public var report: PRImportReport
}

/// `PRDocument` -> SQCore `Project`. Maps only to existing model features; everything else lands in the report.
/// Coordinates: Premiere points are normalized (Motion/Geometry2 Position to the frame they live in, Motion Anchor to the
/// clip's own frame); SQ uses px offsets from the center (sequence px for Motion position, clip px for anchors and stages).
public enum PRMapper {
    /// Absolute paths of every media file the document uses (what the caller should probe before `map`).
    public static func mediaPaths(_ doc: PRDocument) -> [String] {
        var seen = Set<String>(), out = [String]()
        for s in doc.sequences {
            for item in (s.videoTracks + s.audioTracks).flatMap(\.items) {
                if case .media(let m) = item.source, let p = m.path, seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    /// Where each stored media path is on this Mac (`MediaPathResolver` order: as stored, RelativePath against the
    /// project folder, same name in the project folder tree and its parent, then `searchFolders` from earlier Locates).
    /// Keyed by the stored path (what `map(media:)` expects); unresolved paths are absent. File I/O: call off the main thread.
    public static func resolveMedia(_ doc: PRDocument, projectFile: URL, searchFolders: [URL] = []) -> [String: MediaPathResolver.Hit] {
        var seen = Set<String>(), requests = [MediaPathResolver.Request]()
        for s in doc.sequences {
            for item in (s.videoTracks + s.audioTracks).flatMap(\.items) {
                if case .media(let m) = item.source, let p = m.path, seen.insert(p).inserted {
                    requests.append(.init(storedPath: p, relativePath: m.relativePath))
                }
            }
        }
        let resolver = MediaPathResolver(projectFolder: projectFile.deletingLastPathComponent(), searchFolders: searchFolders)
        return resolver.resolve(requests)
    }

    /// `media`: probed refs by absolute path (the app probes before mapping); paths without one get a placeholder ref
    /// (offline until relinked).
    /// `shapes`: map the Shape layers of a graphic onto Graphics layers (templates); a project import leaves them out.
    public static func map(_ doc: PRDocument, name: String, media: [String: MediaRef] = [:], shapes: Bool = false) -> PRImportResult {
        // Text clips resolve the same few fonts again and again (point text layout): resolve each once per map.
        FontResolver.withScopedCache { mapUncached(doc, name: name, media: media, shapes: shapes) }
    }

    static func mapUncached(_ doc: PRDocument, name: String, media: [String: MediaRef], shapes: Bool = false) -> PRImportResult {
        var m = Mapping(doc: doc, probed: media)
        m.mapShapes = shapes
        let timelines = doc.sequences.map { m.timeline($0) }
        // Active: a sequence no other one nests, the longest such.
        let nested = Set(doc.sequences.flatMap { s in (s.videoTracks + s.audioTracks).flatMap(\.items).compactMap { i -> String? in
            if case .sequence(let id) = i.source, !m.cyclicEdges.contains("\(s.id)|\(id)") { return id } else { return nil } } })
        let top = doc.sequences.filter { !nested.contains($0.id) }.max { m.length(of: $0) < m.length(of: $1) }
        let project = Project(name: name, media: m.mediaOrder.compactMap { m.refs[$0] }, timelines: timelines,
                              activeTimeline: top.flatMap { m.timelineIDs[$0.id] })
        return PRImportResult(project: project, report: m.report)
    }
}

/// Text placement calibration against Premiere renders (vertical offset of the glyph center from the Geometry2 point, px).
/// Measured by Tools/PrprojFidelity on iOS 27 Features #1: ours sat 29-30 px high on 32 caption samples (1080x1920).
let textCentreOffsetY = 29.0

struct Mapping {
    let doc: PRDocument
    var refs: [String: MediaRef] = [:]
    var mediaOrder: [String] = []
    var timelineIDs: [String: UUID] = [:]
    var report = PRImportReport()
    var mapShapes = false
    let sequences: [String: PRSequence]
    /// Nesting edges "from|to" that close a cycle (A nests B nests A): dropped on import.
    let cyclicEdges: Set<String>

    init(doc: PRDocument, probed: [String: MediaRef]) {
        self.doc = doc
        refs = probed
        var ids = [String: UUID](), seqs = [String: PRSequence]()
        for s in doc.sequences { ids[s.id] = UUID(); seqs[s.id] = s }
        timelineIDs = ids; sequences = seqs
        cyclicEdges = Self.cyclicNesting(doc.sequences)
    }

    /// Back edges of the nesting graph (depth-first in document order): removing them leaves it acyclic.
    static func cyclicNesting(_ list: [PRSequence]) -> Set<String> {
        var edges = [String: [String]](), known = Set<String>()
        for s in list {
            known.insert(s.id)
            edges[s.id] = (s.videoTracks + s.audioTracks).flatMap(\.items).compactMap { i -> String? in
                if case .sequence(let id) = i.source { return id } else { return nil } }
        }
        var state = [String: Int](), back = Set<String>()  // 1 = on the stack, 2 = done
        for root in list.map(\.id) where state[root] == nil {
            var stack: [(String, Int)] = [(root, 0)]
            state[root] = 1
            while let (node, i) = stack.last {
                let out = edges[node] ?? []
                if i >= out.count { state[node] = 2; stack.removeLast(); continue }
                stack[stack.count - 1].1 += 1
                let next = out[i]
                guard known.contains(next) else { continue }
                switch state[next] {
                case 1: back.insert("\(node)|\(next)")
                case nil: state[next] = 1; stack.append((next, 0))
                default: break
                }
            }
        }
        return back
    }

    func length(of s: PRSequence) -> Int64 { (s.videoTracks + s.audioTracks).flatMap(\.items).map(\.end).max() ?? 0 }

    // MARK: Sequences and tracks

    mutating func timeline(_ s: PRSequence) -> Timeline {
        let format = SequenceFormat(width: s.width, height: s.height, frameDuration: s.frameDuration).sanitized()
        let all = s.videoTracks.map { (TrackKind.video, $0) } + s.audioTracks.map { (TrackKind.audio, $0) }
        var lanes = all.map { clips($0.1, kind: $0.0, seq: s) }
        link(&lanes, kinds: all.map(\.0))
        var counts = [TrackKind: Int]()
        let tracks = zip(all, lanes).map { pair, clips -> Track in
            let (kind, t) = pair
            counts[kind, default: 0] += 1
            var track = Track(kind: kind, clips: clips, name: "\(kind == .video ? "V" : "A")\(counts[kind]!)", isMuted: t.isMuted && kind == .audio)
            // A muted video track is Premiere's "output off" (the eye): hidden in SQ.
            if t.isMuted && kind == .video { track.isVisible = false }
            if t.isMuted { report.note(kind == .audio ? "Track mute" : "Video track output off", .mapped) }
            track.transitions = t.transitions.compactMap { transition($0, kind: kind, clips: clips, seq: s) }
            return track
        }
        var timeline = Timeline(id: timelineIDs[s.id]!, name: s.name, format: format, tracks: tracks)
        timeline.markers = s.markers.map { Self.marker($0, at: PRTicks.time($0.ticks), frame: s.frameDuration) }
        if !s.markers.isEmpty { report.note("Sequence markers", .mapped, "\(s.markers.count)") }
        return timeline
    }

    mutating func clips(_ t: PRTrack, kind: TrackKind, seq: PRSequence) -> [Clip] {
        var clips = [Clip]()
        for item in t.items {
            guard let c = clip(item, kind: kind, seq: seq) else { continue }
            if let last = clips.last, last.timeline.end > c.start {
                report.note("Overlapping clip", .dropped, "a clip starting inside the previous one on the same track")
                continue
            }
            clips.append(c)
        }
        return clips
    }

    mutating func transition(_ t: PRTransitionItem, kind trackKind: TrackKind = .video, clips: [Clip], seq: PRSequence) -> Transition? {
        let start = PRTicks.time(t.start), end = PRTicks.time(t.end)
        let kind: TransitionKind
        switch t.matchName {
        case let n where trackKind == .audio && n.contains("Constant Gain"): kind = .constantGain
        case let n where trackKind == .audio && n.contains("Constant Power"): kind = .constantPower
        case _ where trackKind == .audio:
            // Exponential Fade, Custom Fade (curve unknown): SQ's default audio crossfade.
            report.note("Transition \(t.matchName)", .approximated, "played as Constant Power")
            kind = .constantPower
        case let n where n.contains("Cross Dissolve"): kind = .crossDissolve
        case let n where n.contains("Dip to Black") || n.contains("DipToBlack"): kind = .dipToBlack
        case let n where n.contains("Dip to White") || n.contains("DipToWhite"): kind = .dipToWhite
        default:
            report.note("Transition \(t.matchName)", .approximated, "played as Cross Dissolve")
            kind = .crossDissolve
        }
        // The cut: a clip ending inside the transition span, or the span's edge for a one-sided one.
        let out = clips.first { $0.timeline.end > start && $0.timeline.end <= end }
        let inc = clips.first { $0.start >= start && $0.start < end && $0.id != out?.id }
        guard out != nil || inc != nil else { report.note("Transition", .dropped, "no clip at its cut"); return nil }
        var tr = Transition(kind: kind, duration: (end - start).snapped(to: seq.frameDuration), outgoing: out?.id, incoming: inc?.id)
        let cut = out?.timeline.end ?? inc!.start
        if cut == start { tr.alignment = .startAtCut } else if cut == end { tr.alignment = .endAtCut }
        else if cut - start != end - cut { tr.alignment = .custom; tr.customBefore = cut - start }
        report.note(kind == .crossDissolve ? "Cross Dissolve" : kind.rawValue, .mapped)
        return tr
    }

    /// Links video and audio clips of the same media over the same range (Premiere's linked A/V pair; stereo pairs on
    /// two audio tracks join the same link).
    func link(_ lanes: inout [[Clip]], kinds: [TrackKind]) {
        struct Key: Hashable { let media: UUID; let start: Time; let end: Time }
        func key(_ c: Clip) -> Key { Key(media: c.media, start: c.start, end: c.timeline.end) }
        var byKey = [Key: [(Int, Int)]]()
        for (li, lane) in lanes.enumerated() {
            for (ci, c) in lane.enumerated() where !c.isGenerator { byKey[key(c), default: []].append((li, ci)) }
        }
        for (_, members) in byKey {
            let hasVideo = members.contains { kinds[$0.0] == .video }, hasAudio = members.contains { kinds[$0.0] == .audio }
            guard hasVideo, hasAudio, members.filter({ kinds[$0.0] == .video }).count == 1 else { continue }
            let id = UUID()
            for (li, ci) in members { lanes[li][ci].link = id }
        }
    }

    // MARK: Clips

    static let stillExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "psd", "tga", "exr", "dpx"]

    mutating func mediaRef(_ m: PRMedia) -> MediaRef? {
        guard let path = m.path else { return nil }
        if refs[path] == nil {
            refs[path] = MediaRef(name: m.title, path: path, fingerprint: MediaFingerprint(size: 0))
            report.note("Offline media", .approximated, "not probed (missing file): placeholder until relinked")
        }
        if !mediaOrder.contains(path) { mediaOrder.append(path) }
        return refs[path]
    }

    /// Maps one item and ties every approximated / dropped note it caused to the new clip, for the checklist's "Show".
    mutating func clip(_ item: PRItem, kind: TrackKind, seq: PRSequence) -> Clip? {
        report.beginCollect()
        let c = clipUntracked(item, kind: kind, seq: seq)
        let loc = c.flatMap { c in timelineIDs[seq.id].map { PRImportReport.Location(timeline: $0, clip: c.id) } }
        report.endCollect(attachingTo: loc)
        if let loc, case .media(let pm) = item.source, let path = pm.path, let ref = refs[path], ref.fingerprint.size == 0, ref.info == nil {
            report.attach("Offline media", .approximated, to: loc)
        }
        return c
    }

    private mutating func clipUntracked(_ item: PRItem, kind: TrackKind, seq: PRSequence) -> Clip? {
        let start = PRTicks.time(item.start), end = PRTicks.time(item.end)
        guard end > start else { return nil }
        if item.isAdjustmentLayer { return adjustmentClip(item, kind: kind, seq: seq, start: start, duration: end - start) }
        var speed = ClipSpeed.normal, reversed = false
        if item.speed != 1 {
            speed = ClipSpeed(percent: abs(item.speed) * 100)
            reversed = item.speed < 0
            report.note("Speed", .mapped)
        }
        let duration = end - start
        let sourceDuration = speed.scale(duration)
        let ctx = ClipContext(inPoint: item.inPoint, speed: speed, sequence: seq)
        var c: Clip
        var frame = Vec2(Double(seq.width), Double(seq.height))
        var textOffset = Vec2.zero, stageOffset = Vec2.zero
        var pixelAspect = 1.0
        switch item.source {
        case .media(let pm):
            guard let ref = mediaRef(pm) else { return nil }
            // Unprobed (offline at import): judged by the extension, so the clip is a still before the relink probe too.
            let still = ref.info?.isStill ?? Self.stillExtensions.contains((ref.path as NSString).pathExtension.lowercased())
            // The media item already desqueezes by its own pixel aspect (the file's tag); only what Premiere's
            // interpretation adds on top of it becomes a horizontal scale, so a tagged file is not stretched twice.
            // A project that does not say how it read the pixels (no OriginalPAR) adds nothing: unknown is not square.
            let own = ref.info?.video?.displayPixelAspect.value ?? 1
            if let v = ref.info?.video { frame = Vec2(Double(v.desqueezedWidth), Double(v.height)) }
            if let theirs = pm.pixelAspect { pixelAspect = abs(theirs / own - 1) < 0.005 ? 1 : theirs / own }
            if pixelAspect != 1 { report.note("Pixel aspect ratio", .mapped, "non-square pixels as a horizontal scale") }
            c = Clip(name: item.name.isEmpty ? pm.title : item.name, media: ref.id, kind: kind,
                     source: TimeRange(start: still ? .zero : PRTicks.time(item.inPoint), duration: sourceDuration), start: start,
                     mediaDuration: ref.duration, isStill: still, speed: speed, reversed: reversed)
        case .sequence(let id):
            guard let tl = timelineIDs[id], let inner = sequences[id] else {
                report.note("Nested sequence", .dropped, "unknown sequence"); return nil
            }
            guard !cyclicEdges.contains("\(seq.id)|\(id)") else {
                report.note("Nested sequence", .dropped, "cyclic nesting"); return nil
            }
            frame = Vec2(Double(inner.width), Double(inner.height))
            c = Clip(name: item.name.isEmpty ? inner.name : item.name, media: tl, kind: kind,
                     source: TimeRange(start: PRTicks.time(item.inPoint), duration: sourceDuration), start: start,
                     mediaDuration: PRTicks.time(length(of: inner)), sequence: tl, speed: speed, reversed: reversed)
            report.note("Nested sequence", .mapped)
        case .graphic(let title):
            guard kind == .video else { return nil }
            // Text and (templates only) Shape layers in component order, which lists the top layer first.
            var texts = [(GeneratorRef, Vec2, Vec2)](), layers = [GraphicsLayer]()
            for comp in item.components where comp.matchName == "AE.ADBE Text" || (mapShapes && comp.matchName == Self.shapeMatchName) {
                if comp.matchName == "AE.ADBE Text" {
                    guard let layer = Self.textLayer(comp), let t = textGenerator(item, seq: seq, layer: layer) else { continue }
                    texts.append(t)
                    var l = GraphicsLayer.text(t.0, name: "Text \(texts.count)")
                    l.animation.position = AnimatedProperty(t.1)
                    layers.append(l)
                } else if let l = shapeLayer(comp, ctx: ctx, frame: frame, name: "Shape \(layers.count + 1)") {
                    layers.append(l)
                }
            }
            let hasShape = layers.count > texts.count
            guard !layers.isEmpty else {
                report.note("Graphic without text", .dropped, "\(title): shapes / graphic groups have no model yet")
                return nil
            }
            let id = UUID()
            let name = item.name.isEmpty ? title : item.name
            if texts.count == 1, !hasShape {
                let (ref, offset, stage) = texts[0]
                textOffset = offset
                stageOffset = stage
                c = Clip(id: id, name: name, media: id, kind: .video,
                         source: TimeRange(start: .zero, duration: duration), start: start, generator: ref)
            } else {
                // Several layers: one Graphics clip. Premiere draws the graphic's effects (Drop Shadow, Transform, blur)
                // on all layers together, so the shadow lies under every text; split into clips, an upper text's shadow
                // darkened the lower text. Each layer sits at its own raster offset in the graphic's canvas; the Motion
                // anchor then needs no text offset, and the effects keep the first layer's stage pivot (offset vs raster).
                if let first = texts.first { stageOffset = Vec2(first.2.x - first.1.x, first.2.y - first.1.y) }
                c = Clip(id: id, name: name, media: id, kind: .video,
                         source: TimeRange(start: .zero, duration: duration), start: start, generator: .graphicsClip)
                // Graphics layers are listed bottom first, Premiere's components top first.
                c.graphics = GraphicsDocument(layers: Array(layers.reversed()))
                if texts.count > 1 { report.note("Second text layer in a graphic", .mapped, "one Graphics clip, a layer per text; effects act on the whole graphic") }
            }
        case .colorMatte(let rgb):
            guard kind == .video else { return nil }
            let id = UUID()
            c = Clip(id: id, name: item.name.isEmpty ? "Color Matte" : item.name, media: id, kind: .video,
                     source: TimeRange(start: .zero, duration: duration), start: start, generator: .solid(rgb: rgb))
            report.note("Color matte", .mapped, "solid color generator")
        case .unknown:
            report.note("Clip without source", .dropped)
            return nil
        }
        if kind == .video {
            c.animation = motion(item, ctx: ctx, frame: frame, textOffset: textOffset, pixelAspect: pixelAspect)
            c.effects = effects(item, ctx: ctx, frame: frame, textOffset: stageOffset)
            c.blendMode = blendMode(item)
            // Premiere shows camera log as is (no source conversion) and the look LUT does the log-to-display mapping;
            // our automatic conversion would apply it twice. A look LUT therefore pins the footage to Rec. 709 as shot.
            if case .media = item.source, c.effects.contains(where: { $0.isColor && $0.colorData.look != nil }) {
                c.footageColor = ClipFootageColor(source: .rec709, useEmbeddedLUT: false)
            }
            if case .media(let pm) = item.source, Self.isDisplayReferred709(pm.colorProfile) { applyDisplayGamma(to: &c) }
        } else {
            audio(item, ctx: ctx, into: &c)
        }
        clipMarkers(item, into: &c, seq: seq)
        report.note(kind == .video ? "Video clip" : "Audio clip", .mapped)
        return c
    }

    /// An SQ marker for a Premiere one placed at `time` (snapped to `frame`); unknown color indices become green.
    /// A sequence marker: time and duration on the sequence frame.
    static func marker(_ m: PRMarker, at time: Time, frame: Time) -> Marker {
        marker(m, time: time.snapped(to: frame), duration: PRTicks.time(m.durationTicks).snapped(to: frame))
    }

    static func marker(_ m: PRMarker, time: Time, duration: Time) -> Marker {
        let colors = MarkerColor.allCases
        return Marker(time: time, name: m.name, color: colors.indices.contains(m.colorIndex) ? colors[m.colorIndex] : .green,
                      comment: m.comment, duration: duration)
    }

    /// Clip markers (media ticks, like the in point) as `Clip.markers` in SQ source time: `source.start` is the in point
    /// for media and nested clips and 0 for generators. Only the markers inside the used source range are kept; the rest
    /// are master-clip markers Premiere shows only when the clip is trimmed out to them.
    /// Snapping happens where the marker shows: the clip-local time ((t - source.start) / speed, from the end for a
    /// reversed clip) goes onto the sequence frame and is mapped back to source time, and so does the length. Snapping the
    /// source time itself with the sequence frame would put markers of a retimed clip between the frames it plays.
    mutating func clipMarkers(_ item: PRItem, into c: inout Clip, seq: PRSequence) {
        guard !item.markers.isEmpty else { return }
        let shift = c.source.start - PRTicks.time(item.inPoint), fd = seq.frameDuration
        var kept = [Marker](), outside = 0
        for m in item.markers {
            let t = PRTicks.time(m.ticks) + shift
            guard t >= c.source.start, t < c.source.end else { outside += 1; continue }
            let local = min(c.localTime(forInstant: t).snapped(to: fd), max(.zero, c.duration - fd))
            let length = c.speed.scale(c.speed.unscale(PRTicks.time(m.durationTicks)).snapped(to: fd))
            kept.append(Self.marker(m, time: min(max(c.sourceInstant(atLocal: local), c.source.start), c.source.end), duration: length))
        }
        if !kept.isEmpty { c.markers = kept; report.note("Clip markers", .mapped, "in source time, on the sequence frame the clip shows them at") }
        if outside > 0 {
            report.note("Clip markers outside the used range", .dropped, "master-clip markers Premiere shows only after trimming out to them")
        }
    }

    /// Bounding box (px, the shape's own space) of an `AE.ADBE Shape` path blob (param 1), layout seen in all 140 real
    /// instances: UInt32 2, UInt32 point count, then per point a Float32 (0) and three (x, y) Float32 pairs (vertex and
    /// its tangents); one closing byte. nil when the blob does not fit that layout.
    static func shapeBounds(_ base64: String?) -> (min: Vec2, max: Vec2)? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count >= 8 else { return nil }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << UInt32(8 * $1) } }
        let count = Int(u32(4))
        guard u32(0) == 2, count >= 3, count <= 4096, b.count >= 8 + count * 28 else { return nil }
        var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
        for i in 0..<count {
            let x = Double(Float(bitPattern: u32(8 + i * 28 + 4))), y = Double(Float(bitPattern: u32(8 + i * 28 + 8)))
            guard x.isFinite, y.isFinite else { return nil }
            lo = Vec2(min(lo.x, x), min(lo.y, y)); hi = Vec2(max(hi.x, x), max(hi.y, y))
        }
        return (lo, hi)
    }

    /// True when a Shape layer's bounding box, through its own static transform (Position 4 and Anchor 10 as 0...1 of the
    /// frame, Scale 5, Horizontal Scale 6 unless Uniform 7, no Rotation 8), covers the whole frame within a pixel.
    static func shapeCoversFrame(_ comp: PRComponent, frame: Vec2) -> Bool {
        guard let box = shapeBounds(comp.param(1)?.blob), ![4, 5, 6, 8, 10].contains(where: { comp.param($0)?.isAnimated == true }),
              (PRParamValue.double(comp.param(8)?.staticValue) ?? 0) == 0 else { return false }
        let pos = PRParamValue.point(comp.param(4)?.staticValue) ?? Vec2(0.5, 0.5)
        let anchor = PRParamValue.point(comp.param(10)?.staticValue) ?? Vec2(0, 0)
        let sy = (PRParamValue.double(comp.param(5)?.staticValue) ?? 100) / 100
        let sx = PRParamValue.bool(comp.param(7)?.staticValue) == false ? (PRParamValue.double(comp.param(6)?.staticValue) ?? 100) / 100 : sy
        guard sx > 0, sy > 0 else { return false }
        func x(_ q: Double) -> Double { pos.x * frame.x + sx * (q - anchor.x * frame.x) }
        func y(_ q: Double) -> Double { pos.y * frame.y + sy * (q - anchor.y * frame.y) }
        return x(box.min.x) <= 1 && y(box.min.y) <= 1 && x(box.max.x) >= frame.x - 1 && y(box.max.y) >= frame.y - 1
    }

    // MARK: Shape layers (templates)

    static let shapeMatchName = "AE.ADBE Shape"

    /// One vertex of a Shape path with its two tangent handles, all absolute px in the shape's own space.
    struct ShapePoint: Equatable { var v: Vec2; var tin: Vec2; var tout: Vec2 }

    enum ShapeForm: Equatable { case rectangle(radius: Double), ellipse, polygon, curved }

    /// The vertices of an `AE.ADBE Shape` path blob (layout in `shapeBounds`); nil when it does not fit.
    static func shapePoints(_ base64: String?) -> [ShapePoint]? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count >= 8 else { return nil }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << UInt32(8 * $1) } }
        func f(_ o: Int) -> Double { Double(Float(bitPattern: u32(o))) }
        let count = Int(u32(4))
        guard u32(0) == 2, count >= 3, count <= 4096, b.count >= 8 + count * 28 else { return nil }
        var out = [ShapePoint]()
        for i in 0..<count {
            let o = 8 + i * 28
            let p = ShapePoint(v: Vec2(f(o + 4), f(o + 8)), tin: Vec2(f(o + 12), f(o + 16)), tout: Vec2(f(o + 20), f(o + 24)))
            guard [p.v, p.tin, p.tout].allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            out.append(p)
        }
        return out
    }

    /// What the Graphics model can draw for a path: an axis-aligned rectangle (4 corners, or 8 vertices of a rounded one),
    /// an ellipse (4 curved vertices at the middle of the box edges), a straight polygon; anything else is `.curved`.
    static func classifyShape(_ pts: [ShapePoint]) -> (form: ShapeForm, lo: Vec2, hi: Vec2) {
        let xs = pts.map(\.v.x), ys = pts.map(\.v.y)
        let lo = Vec2(xs.min() ?? 0, ys.min() ?? 0), hi = Vec2(xs.max() ?? 0, ys.max() ?? 0)
        let w = hi.x - lo.x, h = hi.y - lo.y, tol = 0.5
        guard w > tol, h > tol else { return (.curved, lo, hi) }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tol }
        let straight = pts.allSatisfy { (($0.tin - $0.v).length < 0.01) && (($0.tout - $0.v).length < 0.01) }
        let cx = (lo.x + hi.x) / 2, cy = (lo.y + hi.y) / 2
        func corner(_ p: Vec2) -> Bool { (near(p.x, lo.x) || near(p.x, hi.x)) && (near(p.y, lo.y) || near(p.y, hi.y)) }
        if pts.count == 4 {
            if straight, pts.allSatisfy({ corner($0.v) }) {
                let distinct = Set(pts.map { "\(PRSafe.int(($0.v.x - lo.x).rounded()) ?? 0)|\(PRSafe.int(($0.v.y - lo.y).rounded()) ?? 0)" })
                if distinct.count == 4 { return (.rectangle(radius: 0), lo, hi) }
            }
            let mids = pts.allSatisfy { p in
                (near(p.v.x, cx) && (near(p.v.y, lo.y) || near(p.v.y, hi.y))) || (near(p.v.y, cy) && (near(p.v.x, lo.x) || near(p.v.x, hi.x)))
            }
            if mids, !straight {
                // Handles lie along the edge's tangent at about 0.5523 of the radius (a circle quadrant).
                let ok = pts.allSatisfy { p in
                    let horizontal = near(p.v.y, lo.y) || near(p.v.y, hi.y)
                    let r = horizontal ? w / 2 : h / 2
                    return [p.tin, p.tout].allSatisfy { t in
                        let d = t - p.v
                        let along = horizontal ? abs(d.x) : abs(d.y), across = horizontal ? abs(d.y) : abs(d.x)
                        return abs(along - 0.5523 * r) <= 0.08 * r && across <= tol
                    }
                }
                if ok { return (.ellipse, lo, hi) }
            }
        }
        if pts.count == 8 {
            // Rounded rectangle: every vertex on the box edge, a corner radius away from its corner.
            func onEdge(_ p: Vec2) -> Bool { near(p.x, lo.x) || near(p.x, hi.x) || near(p.y, lo.y) || near(p.y, hi.y) }
            func gap(_ p: Vec2) -> Double {
                // Distance along the edge to the nearest corner.
                let onVertical = near(p.x, lo.x) || near(p.x, hi.x)
                return onVertical ? min(abs(p.y - lo.y), abs(p.y - hi.y)) : min(abs(p.x - lo.x), abs(p.x - hi.x))
            }
            if pts.allSatisfy({ onEdge($0.v) && !corner($0.v) }) {
                let r = gap(pts[0].v)
                if r > tol, r * 2 <= min(w, h) + tol, pts.allSatisfy({ near(gap($0.v), r) }) { return (.rectangle(radius: r), lo, hi) }
            }
        }
        return straight ? (.polygon, lo, hi) : (.curved, lo, hi)
    }

    /// Fill, outline and shadow switch of a Shape layer's Appearance (param 2: 8-byte header, UTF-16 JSON `mStyle`).
    struct ShapeAppearance {
        var fill: PRText.RGB?
        var stroke: (color: PRText.RGB, width: Double)?
        var hasShadow = false
    }

    static func shapeAppearance(_ base64: String?) -> ShapeAppearance {
        var out = ShapeAppearance(fill: PRText.RGB(red: 0, green: 0, blue: 0))
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count > 8,
              var s = String(bytes: [UInt8](data)[8...], encoding: .utf16LittleEndian) else { return out }
        while s.last == "\0" { s.removeLast() }
        guard let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let style = json["mStyle"] as? [String: Any] else { return out }
        func rgb(_ v: Any?) -> PRText.RGB? {
            guard let n = (v as? NSNumber)?.intValue else { return nil }
            return PRText.RGB(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
        }
        func on(_ k: String) -> Bool { (style[k] as? NSNumber)?.boolValue ?? false }
        out.fill = on("mFillVisible") ? rgb(style["mFillColor"]) : nil
        if on("mStrokeVisible"), let c = rgb(style["mStrokeColor"]), let w = (style["mStrokeWidth"] as? NSNumber)?.doubleValue, w > 0 {
            out.stroke = (c, w)
        }
        out.hasShadow = on("mShadowVisible")
        return out
    }

    /// A Shape component as a Graphics layer: Rectangle / Ellipse (with fill, outline, corner radius, size and position) or a
    /// straight polygon as a closed path. Pen paths with curves stay out and are listed in the report.
    /// Position 4 and Anchor 10 are fractions of the frame, Scale 5 / Horizontal Scale 6 (unless Uniform 7), Rotation 8,
    /// Opacity 9 in percent; position and opacity keys carry over, other keys use their first value.
    mutating func shapeLayer(_ comp: PRComponent, ctx: ClipContext, frame: Vec2, name: String) -> GraphicsLayer? {
        guard let pts = Self.shapePoints(comp.param(1)?.blob) else {
            report.note("Shape layer", .dropped, "unreadable path"); return nil
        }
        let (form, lo, hi) = Self.classifyShape(pts)
        if form == .curved {
            report.note("Shape layer", .dropped, "pen path with curves (\(pts.count) points) has no counterpart in the Graphics model")
            return nil
        }
        let pos = PRParamValue.point(comp.param(4)?.staticValue) ?? Vec2(0.5, 0.5)
        let anchor = PRParamValue.point(comp.param(10)?.staticValue) ?? .zero
        let sy = (PRParamValue.double(comp.param(5)?.staticValue) ?? 100) / 100
        let sx = PRParamValue.bool(comp.param(7)?.staticValue) == false ? (PRParamValue.double(comp.param(6)?.staticValue) ?? 100) / 100 : sy
        let rot = PRParamValue.double(comp.param(8)?.staticValue) ?? 0
        let (cs, sn) = (cos(rot * .pi / 180), sin(rot * .pi / 180))
        // The shape's local point as an offset from the frame center after anchor, scale, rotation (position added by the caller).
        func offset(_ q: Vec2) -> Vec2 {
            let dx = sx * (q.x - anchor.x * frame.x), dy = sy * (q.y - anchor.y * frame.y)
            return Vec2(dx * cs - dy * sn, dx * sn + dy * cs)
        }
        let appearance = Self.shapeAppearance(comp.param(2)?.blob)
        let width = (hi.x - lo.x) * sx, height = (hi.y - lo.y) * sy
        let strokeWidth = (appearance.stroke?.width ?? 0) * (sx + sy) / 2
        var layer: GraphicsLayer
        var e: ClipEffect
        switch form {
        case .polygon:
            let canvas = pts.map { p -> Vec2 in let o = offset(p.v); return Vec2(pos.x * frame.x + o.x - frame.x / 2, pos.y * frame.y + o.y - frame.y / 2) }
            layer = GraphicsLayer.path(canvasPoints: canvas, closed: true, color: .white, strokeWidth: 1)
            layer.name = name
            e = layer.shapeEffect ?? ClipEffect.make(kind: ClipEffect.shapeEffectKind)!
            if comp.param(4)?.isAnimated == true { report.note("Shape layer position keys", .approximated, "polygon: first position") }
        default:
            let kind: ShapeKind = form == .ellipse ? .ellipse : .rectangle
            let o = offset(Vec2((lo.x + hi.x) / 2, (lo.y + hi.y) / 2))
            e = ClipEffect.make(kind: ClipEffect.shapeEffectKind)!
            e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(width)
            e.parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(height)
            if case let .rectangle(r) = form, r > 0 { e.parameters[ClipEffect.shapeCornerRadiusKey] = AnimatedProperty(r * (sx + sy) / 2) }
            var a = ClipAnimation()
            let base = Vec2(o.x - frame.x / 2, o.y - frame.y / 2)
            a.position = ctx.animated(comp.param(4), Vec2(pos.x * frame.x + base.x, pos.y * frame.y + base.y), PRParamValue.point) {
                Vec2($0.x * frame.x + base.x, $0.y * frame.y + base.y)
            }
            a.rotation = AnimatedProperty(rot)
            layer = GraphicsLayer(name: name, content: .shape(kind: kind), animation: a, effects: [e])
        }
        if [5, 6, 8, 10].contains(where: { comp.param($0)?.isAnimated == true }) {
            report.note("Shape layer keys", .approximated, "scale / rotation / anchor keys: the first value")
        }
        e.parameters[ClipEffect.shapeFillKey] = AnimatedProperty(appearance.fill == nil ? 0 : 1)
        if let f = appearance.fill { e.colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(EffectColor(red: f.red, green: f.green, blue: f.blue)) }
        e.parameters[ClipEffect.shapeStrokeKey] = AnimatedProperty(appearance.stroke == nil ? 0 : 1)
        if let s = appearance.stroke {
            e.colors[ClipEffect.shapeStrokeColorKey] = AnimatedProperty(EffectColor(red: s.color.red, green: s.color.green, blue: s.color.blue))
            e.parameters[ClipEffect.shapeStrokeWidthKey] = AnimatedProperty(strokeWidth)
        }
        if let i = layer.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) { layer.effects[i] = e }
        layer.animation.opacity = ctx.animated(comp.param(9), 1, PRParamValue.double) { $0 / 100 }
        if appearance.hasShadow { report.note("Shape layer shadow", .dropped, "the shadow of a shape has no counterpart") }
        let label: String = switch form { case .ellipse: "ellipse"; case .polygon: "polygon"; default: "rectangle" }
        report.note("Shape layer", .mapped, label)
        return layer
    }

    /// A Premiere adjustment layer (also a graphic flagged as one) becomes an SQ Adjustment Layer clip with its Motion,
    /// Opacity and effects. Text and Shape layers of such a graphic are not drawn (as in Premiere); see the area note below.
    mutating func adjustmentClip(_ item: PRItem, kind: TrackKind, seq: PRSequence, start: Time, duration: Time) -> Clip? {
        guard kind == .video else { return nil }
        let id = UUID()
        var c = Clip(id: id, name: item.name.isEmpty ? "Adjustment Layer" : item.name, media: id, kind: .video,
                     source: TimeRange(start: .zero, duration: duration), start: start, generator: .adjustmentLayer)
        let ctx = ClipContext(inPoint: item.inPoint, speed: .normal, sequence: seq)
        let frame = Vec2(Double(seq.width), Double(seq.height))
        c.animation = motion(item, ctx: ctx, frame: frame, textOffset: .zero)
        c.effects = effects(item, ctx: ctx, frame: frame, textOffset: .zero)
        c.blendMode = blendMode(item)
        // Text and Shape layers of an adjustment graphic are not drawn by Premiere either; they only limit where the effects
        // reach. Checked 2026-10-06: all 140 such clips in the maintainer's projects are Mister Horse carriers (texts "Mister Horse
        // Adjustment" and a help note, one Shape covering the frame), so the whole frame is affected, as in SQ: silent.
        // Any other text / shape content means Premiere's effect area is smaller than SQ's: reported.
        let shapes = item.components("AE.ADBE Shape")
        if !(shapes.isEmpty && item.components("AE.ADBE Text").isEmpty), !shapes.contains(where: { Self.shapeCoversFrame($0, frame: frame) }) {
            report.note("Adjustment layer area", .approximated, "effect area not limited to the shape/text: SQ applies the effects to the whole frame")
        }
        clipMarkers(item, into: &c, seq: seq)
        report.note("Adjustment layer", .mapped)
        return c
    }

    // MARK: Text

    /// Premiere sets the same font size about 2 % larger than CoreText (Inter, measured on caption and title widths).
    static let textSizeScale = 1.02
    /// Premiere's tracking (1/1000 em) spaces glyphs less than CoreText kerning of the same amount: 60 % fits best
    /// (fidelity sweep over captions + titles: 25.1 dB at 1.0/1.0, 29.4 dB at 1.02/0.6).
    static let textTrackingScale = 0.6
    /// Premiere's text shadow Blur / Size (px at text-layer scale) to SQ's blur radius and spread; see docs/PRPROJ-IMPORT.md.
    /// Fitted on the maintainer's caption look (blur 17.8, size 19.3, distance 20.5 at 73 px; those numbers were read from the wrong fields: the real look is size 20.5, blur 178.6, so the scales were re-based 2026-10-21 to keep the same pixels: 178.6 x 0.26 = 46 px, 20.5 x 0.28 = 5.8 px) against Premiere's export of 'iOS 27
    /// Features #1' over a light UI: caption-band RMSE 28.9 (old: size folded into blur) -> 19.0. Flat optimum: blur 2.5...3,
    /// size 0.25...0.35; a spread of 1.0 or a blur of 1.0 is clearly worse (25.3).
    static let shadowBlurScale = 0.26
    static let shadowSizeScale = 0.28

    /// The text clip, its raster offset from the canvas center (Motion anchor) and the offset the Transform stage uses.
    /// The decodable text layers of a graphic (Essential Graphics can hold several; layer 0 is the first).
    static func textLayers(_ item: PRItem) -> [(PRText, PRComponent)] {
        item.components("AE.ADBE Text").compactMap { textLayer($0) }
    }

    static func textLayer(_ t: PRComponent) -> (PRText, PRComponent)? {
        guard let blob = t.param(1)?.blob, let text = PRTextBlob.decode(base64: blob), !text.text.isEmpty else { return nil }
        return (text, t)
    }

    /// SQ weight from a PostScript name's suffix (BasicSans-Bold -> bold).
    static func weight(_ fontName: String) -> FontWeight {
        let lower = fontName.lowercased()
        for (suffix, w) in [("black", FontWeight.black), ("heavy", .heavy), ("extrabold", .heavy), ("semibold", .semibold),
                            ("bold", .bold), ("medium", .medium), ("light", .light), ("thin", .thin)] where lower.hasSuffix(suffix) {
            return w
        }
        return .regular
    }

    /// `layer`: one entry of `textLayers(item)` (decoded once per item by the caller).
    mutating func textGenerator(_ item: PRItem, seq: PRSequence, layer: (PRText, PRComponent)) -> (GeneratorRef, Vec2, Vec2)? {
        let (text, comp) = layer
        let layerPos = PRParamValue.point(comp.param(3)?.staticValue)
        // Point text placed by its layer (titles): the layer's Scale multiplies the font size.
        let pointText = text.boxSize == nil && layerPos != nil && layerPos != Vec2(0.5, 0.5)
        let layerScale = pointText ? (PRParamValue.double(comp.param(4)?.staticValue) ?? 100) / 100 : 1
        let size = (text.size ?? 48) * layerScale * Self.textSizeScale
        let font = text.fontName ?? "Helvetica"
        // Point text keeps the paragraph alignment (the layer position is its aligned edge); area text stays centered.
        let align: TextAlignment = pointText ? (text.alignment == 1 ? .right : text.alignment == 2 ? .center : .left) : .center
        var style = TextStyle(fontName: font, size: size, weight: Self.weight(font), color: .white, alignment: align,
                              tracking: (text.tracking ?? 0) / 1000 * size * Self.textTrackingScale)
        if let f = text.fill { style.color = RGBAColor(red: f.red, green: f.green, blue: f.blue) }
        // Lines 2+ in another font / size (TCL C8L 'Bis zu' / '3.200'): SQ's second-line style.
        if let l = text.secondLine {
            let name = l.fontName ?? font
            style.secondLine = TextLineStyle(fontName: name, size: (l.size ?? text.size ?? 48) * layerScale * Self.textSizeScale,
                                             weight: Self.weight(name), color: style.color)
            report.note("Text second line style", .mapped, "lines 2+ in their own font and size")
        } else if text.mixedStyles {
            report.note("Text with mixed styles", .approximated, "font / size changes inside a line: the first run's style for all")
        }
        if let s = text.stroke { style.stroke = TextStroke(color: RGBAColor(red: s.color.red, green: s.color.green, blue: s.color.blue), width: s.width * layerScale) }
        if let b = text.background {
            style.background = TextBackground(color: RGBAColor(red: b.color.red, green: b.color.green, blue: b.color.blue, alpha: b.opacity),
                                              padding: BoxPadding(horizontal: b.size * layerScale, vertical: b.size * layerScale),
                                              cornerRadius: b.cornerRadius * layerScale)
            report.note("Text background", .approximated, "color, opacity, size as padding, corner radius")
        }
        if let s = text.shadow {
            var shadow = TextShadow(color: RGBAColor(red: s.red, green: s.green, blue: s.blue, alpha: s.opacity),
                                    angle: s.angle, distance: s.distance * layerScale, blur: s.blur * layerScale * Self.shadowBlurScale)
            shadow.spread = s.size * layerScale * Self.shadowSizeScale
            style.shadow = shadow
        }
        let template = TextTemplate(name: text.text, text: text.text, style: style)
        guard let ref = try? TextGenerator.makeRef(template: template, animations: nil) else { return nil }
        report.note("Text", .approximated, "string, font, size, tracking, fill color, alignment (point text; area text centered), shadow (size as spread), background")
        let canvas = Vec2(Double(seq.width), Double(seq.height))
        if pointText, let p = layerPos, let line = TextLayout.layout(text: text.text, style: style, maxWidth: nil).lines.first {
            // Point text: the layer position is the first line's baseline at its aligned edge (left / right / center),
            // moved by the Graphic Group (Vector Motion) position relative to its anchor. A Transform effect keeps
            // pivoting at its own point, so the stage offset is the text center itself.
            var origin = Vec2(p.x * canvas.x, p.y * canvas.y)
            if let g = item.components("AE.ADBE Graphic Group").first, let gp = PRParamValue.point(g.param(1)?.staticValue) {
                let ga = PRParamValue.point(g.param(6)?.staticValue) ?? Vec2(0.5, 0.5)
                origin = Vec2(origin.x + (gp.x - ga.x) * canvas.x, origin.y + (gp.y - ga.y) * canvas.y)
                if (PRParamValue.double(g.param(2)?.staticValue) ?? 100) != 100 || g.params.contains(where: \.isAnimated) {
                    report.note("Graphic Group", .approximated, "position only (scale / keys ignored)")
                }
            }
            let dx: Double = switch text.alignment ?? 0 { case 1: -line.width / 2; case 2: 0; default: line.width / 2 }
            let centre = Vec2(origin.x + dx - canvas.x / 2, origin.y - line.baseline + line.height / 2 - canvas.y / 2)
            report.note("Point text", .approximated, "placed by layer position (baseline, aligned edge) and scale")
            return (ref, centre, centre)
        }
        // Area text (captions): at the Transform (Geometry2) point when there is one, else at the Text layer's own position.
        var centre = Vec2.zero
        if let g = item.components("AE.ADBE Geometry2").first, let p = PRParamValue.point(g.param(2)?.staticValue) {
            centre = Vec2((p.x - 0.5) * canvas.x, (p.y - 0.5) * canvas.y + textCentreOffsetY)
        } else if let p = layerPos, p != Vec2(0.5, 0.5) {
            centre = Vec2((p.x - 0.5) * canvas.x, (p.y - 0.5) * canvas.y)
            report.note("Text position", .approximated, "Text layer position taken as the text center")
        }
        // The stage pivots at the Transform point itself: only the raster (anchor) carries the glyph-center calibration.
        return (ref, centre, centre == .zero ? .zero : Vec2(centre.x, centre.y - textCentreOffsetY))
    }

    // MARK: Motion / Opacity

    /// `pixelAspect`: the source's pixel width / height (Premiere shows non-square pixels stretched; SQ has no PAR, so it
    /// becomes part of the horizontal scale).
    mutating func motion(_ item: PRItem, ctx: ClipContext, frame: Vec2, textOffset: Vec2, pixelAspect: Double = 1) -> ClipAnimation {
        var a = ClipAnimation()
        let par = pixelAspect
        if par != 1 { a.scale = AnimatedProperty(Vec2(par, 1)) }
        let canvas = Vec2(Double(ctx.sequence.width), Double(ctx.sequence.height))
        if let m = item.components("AE.ADBE Motion").first {
            a.position = ctx.animated(m.param(1), .zero, PRParamValue.point) { Vec2(($0.x - 0.5) * canvas.x, ($0.y - 0.5) * canvas.y) }
            let uniform = PRParamValue.bool(m.param(4)?.staticValue) ?? true
            if uniform {
                a.scale = ctx.animated(m.param(2), Vec2(par, 1), PRParamValue.double) { Vec2(par * $0 / 100, $0 / 100) }
            } else {
                let w = PRParamValue.double(m.param(3)?.staticValue) ?? 100
                a.scale = ctx.animated(m.param(2), Vec2(par, 1), PRParamValue.double) { Vec2(par * w / 100, $0 / 100) }
                if m.param(3)?.isAnimated == true { report.note("Motion non-uniform scale keys", .approximated, "width keys dropped") }
            }
            a.rotation = ctx.animated(m.param(5), 0, PRParamValue.double) { $0 }
            a.anchor = ctx.animated(m.param(6), .zero, PRParamValue.point) {
                Vec2(($0.x - 0.5) * frame.x - textOffset.x, ($0.y - 0.5) * frame.y - textOffset.y)
            }
            report.note("AE.ADBE Motion", .mapped)
        }
        if textOffset != .zero, !a.anchor.isAnimated, item.components("AE.ADBE Motion").isEmpty {
            a.anchor = AnimatedProperty(Vec2(-textOffset.x, -textOffset.y))
        }
        if let o = item.components("AE.ADBE Opacity").first {
            a.opacity = ctx.animated(o.param(1), 1, PRParamValue.double) { $0 / 100 }
            report.note("AE.ADBE Opacity", .mapped)
        }
        return a
    }

    /// Opacity > Blend Mode: param 2 is Premiere's internal code (18 Normal, 22 Add, 11 Color Dodge, 17 Color Burn, 12 Soft Light),
    /// param 3 the position in the blend menu (Normal 0, Dissolve 1, Darken 2 ... Add 10, Lighter Color 11, Overlay 12 ...
    /// Exclusion 20 ... Luminosity 26). Pairs measured on 662 clips of the maintainer's projects; the menu index covers the modes no sample used. Static only.
    mutating func blendMode(_ item: PRItem) -> BlendMode {
        guard let o = item.components("AE.ADBE Opacity").first else { return .normal }
        // The menu index is the position in the standard 27-mode list, which is SQ's `BlendMode.allCases` order too.
        let byIndex = Dictionary(uniqueKeysWithValues: BlendMode.allCases.enumerated().map { ($0.offset, $0.element) })
        let byCode: [Int: BlendMode] = [18: .normal, 22: .add, 11: .colorDodge, 17: .colorBurn, 12: .softLight]
        let code = PRParamValue.double(o.param(2)?.staticValue).flatMap { PRSafe.int($0) }
        let index = PRParamValue.double(o.param(3)?.staticValue).flatMap { PRSafe.int($0) }
        guard code != nil || index != nil else { return .normal }
        let mode = index.flatMap { byIndex[$0] } ?? (index == nil ? code.flatMap { byCode[$0] } : nil)
        if o.param(2)?.isAnimated == true { report.note("Opacity blend mode", .approximated, "keys dropped") }
        if let mode {
            if mode != .normal { report.note("Opacity blend mode", .mapped, mode.title) }
            return mode
        }
        report.note("Opacity blend mode", .dropped, "unknown blend menu index: drawn as Normal")
        return .normal
    }

    mutating func audio(_ item: PRItem, ctx: ClipContext, into c: inout Clip) {
        // Audio Gain (linear, 1 = 0 dB) is Premiere's input level: it feeds the clip's effects, the Volume level comes after
        // them. SQ has the same thing, `Clip.audioGainDB` (applied in front of the effect chain, AudioFeeder), so it maps there
        // (clamped to SQ's range; any rest stays in the volume). Folded into the volume, +6 dB of Audio Gain lifted a limiter
        // held at -0.1 dBFS to +5.9 dBFS (hard clipping).
        let gainDB = item.clipGain > 0 ? 20 * log10(item.clipGain) : 0
        c.audioGainDB = item.clipGain != 1 ? min(AudioGain.maxGainDB, max(AudioGain.minGainDB, gainDB)) : 0
        let gain = item.clipGain / pow(10, c.audioGainDB / 20)
        var hasVolume = false
        for comp in item.components where comp.isAudio {
            let bypassed = PRParamValue.bool(comp.param(at: 0)?.staticValue) == true
            switch comp.matchName {
            case "Internal Volume Stereo", "Internal Volume Mono", "Internal Volume 5.1":
                // Level is linear with 1.0 = +15 dB.
                hasVolume = true
                c.animation.volume = ctx.animated(comp.param(at: 1), gain, PRParamValue.double) {
                    gain * pow(10, (20 * log10(max($0, 1e-9)) + 15) / 20)
                }
                report.note("Clip volume", .mapped)
            case "Internal Channel Volume Stereo", "Internal Channel Volume Mono":
                break
            case Self.noiseReductionMatchName:
                // "Stärke" / Amount: Premiere stores the percentage as 0...1.
                var e = ClipEffect.make(kind: ClipEffect.audioNoiseReductionKind)!
                e.parameters[ClipEffect.noiseAmountReductionKey] = ctx.animated(comp.param(at: 1), 0, PRParamValue.double) { min(100, max(0, $0 * 100)) }
                e.enabled = !bypassed
                c.effects.append(e)
                report.note(comp.displayName, .approximated, "Amount = Strength x 100 %; Makeup / Auto Gain / Boost Type not mapped")
            case let m where m.hasPrefix(Self.multibandMatchPrefix):
                var e = ClipEffect.make(kind: ClipEffect.audioMultibandKind)!
                mapMultiband(comp, ctx: ctx, into: &e)
                e.enabled = !bypassed
                c.effects.append(e)
                report.note(comp.displayName, .approximated, "Multiband: output gain, thresholds, ratios, band gains, attack (x 500 ms), release (x 5 s), crossovers (20 Hz + x 19980 Hz) exact; band bypass / solo / link mapped; Limiter = gain margin - threshold + brickwall at the margin (LMAX positions 48-53; threshold, margin and attack scales assumed); band mute and LMAX ratio not mapped")
            case let m where m.hasPrefix(Self.parametricEQMatchPrefix):
                var e = ClipEffect.make(kind: ClipEffect.audioParametricEQKind)!
                mapParametricEQ(comp, ctx: ctx, into: &e)
                e.enabled = !bypassed
                c.effects.append(e)
                var notes = ["Parametric EQ: band / shelf / HP / LP frequency, gain, Q and on/off exact; HP / LP slope fixed at 12 dB/oct"]
                if let g = PRParamValue.double(comp.param(at: 25)?.staticValue), abs(g - 0.6667) > 0.001 { notes.append("output gain not mapped") }
                report.note(comp.displayName, .approximated, notes.joined(separator: "; "))
            default:
                report.note(comp.displayName, .dropped, "audio effect has no SQ counterpart yet")
            }
        }
        if !hasVolume, gain != 1 { c.animation.volume = AnimatedProperty(gain) }
        if item.clipGain != 1 { report.note("Audio Gain", .mapped) }
    }

    static let noiseReductionMatchName = "c6762838-e451-4d22-9c90-b0eaa734605a"
    static let multibandMatchPrefix = "3981e750-"
    /// Largest multiband limiter drive (margin - threshold, dB) the importer sets up.
    static let maxLimiterDriveDB = 12.0
    static let parametricEQMatchPrefix = "8edcd326-"

    /// Multiband Compressor, normalized params by position (docs/PRPROJ-IMPORT.md "Audio mapping"): 1 output gain, 2-5 thresholds,
    /// 6-9 ratios, 10-13 attack, 14-17 release, 18-21 band gains, 24 link, 25-28 bypass, 29-32 solo, 34-36 crossovers,
    /// 37-40 crossover band bypass, 41-44 band mute (not mapped), 48-53 LMAX limiter
    /// (threshold, margin, ratio, attack, release, bypass). The order is Premiere's own parameter table (dvaaudiofilters
    /// "MultiBandCompressor/..." strings); scales are Audition's panel ranges (MultiBandCompressor.adm): threshold -60...0 dB,
    /// gain -18...18 dB, ratio 1...30, attack 0...500 ms, release 0...5000 ms, crossover 20...20000 Hz.
    func mapMultiband(_ comp: PRComponent, ctx: ClipContext, into e: inout ClipEffect) {
        func p(_ key: String, _ i: Int, _ fallback: Double, _ f: @escaping (Double) -> Double) {
            e.parameters[key] = ctx.animated(comp.param(at: i), fallback, PRParamValue.double, f)
        }
        func flag(_ i: Int) -> Bool { (PRParamValue.double(comp.param(at: i)?.staticValue) ?? 0) != 0 }
        p(ClipEffect.mbOutputGainKey, 1, 0) { $0 * 36 - 18 }
        for b in 1...4 {
            p(ClipEffect.mbThresholdKey(b), 1 + b, -20) { $0 * 60 - 60 }
            p(ClipEffect.mbRatioKey(b), 5 + b, 2) { 1 + 29 * $0 }
            p(ClipEffect.mbAttackKey(b), 9 + b, 10) { min(500, max(0.1, $0 * 500)) }
            p(ClipEffect.mbReleaseKey(b), 13 + b, 100) { min(2_000, max(5, $0 * 5_000)) }
            p(ClipEffect.mbGainKey(b), 17 + b, 0) { $0 * 36 - 18 }
            // 25-28 Bypass, 37-40 crossover band bypass (either one bypasses the band), 29-32 Solo. 41-44 band mute: no SQ counterpart.
            e.parameters[ClipEffect.mbBypassKey(b)] = AnimatedProperty(flag(24 + b) || flag(36 + b) ? 1 : 0)
            e.parameters[ClipEffect.mbSoloKey(b)] = AnimatedProperty(flag(28 + b) ? 1 : 0)
        }
        e.parameters[ClipEffect.mbLinkKey] = AnimatedProperty(flag(24) ? 1 : 0)
        for x in 1...3 { p(ClipEffect.mbCrossoverKey(x), 33 + x, [120, 700, 3_000][x - 1]) { min(20_000, max(20, 20 + $0 * 19_980)) } }
        // Limiter (LMAX): on when its threshold is stored and its bypass is not set.
        if comp.param(at: 48) != nil, comp.param(at: 49) != nil {
            let bypassed = (PRParamValue.double(comp.param(at: 53)?.staticValue) ?? 0) != 0
            e.parameters[ClipEffect.mbLimiterOnKey] = AnimatedProperty(bypassed ? 0 : 1)
            p(ClipEffect.mbLimiterMarginKey, 49, -0.1) { min(0, max(-18, $0 * 36 - 18)) }
            // Drive = margin - threshold. Conservative: at most `maxLimiterDriveDB` (the maintainer's Broadcast: 8.9 dB), so an unknown
            // preset can never push tens of dB into the limiter.
            // Keyed margin: the cap holds against its highest key (so at every moment the drive is <= the cap).
            let m = e.parameters[ClipEffect.mbLimiterMarginKey]
            let margin = ([m?.value ?? -0.1] + (m?.track.keys.map(\.value) ?? [])).max()!
            p(ClipEffect.mbLimiterThresholdKey, 48, -10) { max(margin - Self.maxLimiterDriveDB, min(0, max(-60, $0 * 60 - 60))) }
            p(ClipEffect.mbLimiterAttackKey, 51, 0) { min(500, max(0, $0 * 500)) }      // ASSUMED: the band attack scale
            p(ClipEffect.mbLimiterReleaseKey, 52, 500) { min(5_000, max(5, $0 * 5_000)) }
        }
    }

    /// Parametric EQ, normalized params by position: 1/2 low shelf freq/gain, 3/4 high shelf, bands 1-5 at 5+4k (freq, Q, gain,
    /// enable), 30/31 shelf enable, 32 original sample rate / 192 kHz, 38/39 HP enable/freq, 41/42 LP enable/freq. A checkbox
    /// without a stored value is on; a stored 0 is off. Scales confirmed on a real preset (docs/PRPROJ-IMPORT.md): frequency
    /// = 20 Hz + value x (sample rate / 2 - 20 Hz) (defaults 50/200/800/3200/12800 Hz land exactly), Q = value x 5000 (the
    /// bandwidth readouts 33-37 = value x 20 kHz equal frequency / Q), gain = (value - 0.5) x 48 dB. Not mapped: 25 output gain
    /// (0.6667 = 0 dB, scale unknown), 26 constant Q / constant width, 40/43 HP/LP slope (SQ: 12 dB/oct).
    func mapParametricEQ(_ comp: PRComponent, ctx: ClipContext, into e: inout ClipEffect) {
        let sampleRate = (PRParamValue.double(comp.param(at: 32)?.staticValue) ?? 0.25) * 192_000
        let nyquist = max(sampleRate, 8_000) / 2
        func on(_ i: Int) -> AnimatedProperty<Double> {
            let off = PRParamValue.double(comp.param(at: i)?.staticValue).map { $0 == 0 } ?? (comp.param(at: i)?.staticValue == "false")
            return AnimatedProperty(off ? 0 : 1)
        }
        func freq(_ key: String, _ i: Int, _ fallback: Double) {
            e.parameters[key] = ctx.animated(comp.param(at: i), fallback, PRParamValue.double) { min(20_000, max(20, 20 + $0 * (nyquist - 20))) }
        }
        func gain(_ key: String, _ i: Int) {
            e.parameters[key] = ctx.animated(comp.param(at: i), 0, PRParamValue.double) { ($0 - 0.5) * 48 }
        }
        func q(_ key: String, _ i: Int) {
            e.parameters[key] = ctx.animated(comp.param(at: i), 1, PRParamValue.double) { min(10, max(0.1, $0 * 5_000)) }
        }
        let k = ClipEffect.peqKey
        e.parameters[k("ls", "On")] = on(30); freq(k("ls", "Freq"), 1, 120); gain(k("ls", "Gain"), 2)
        e.parameters[k("hs", "On")] = on(31); freq(k("hs", "Freq"), 3, 8_000); gain(k("hs", "Gain"), 4)
        for b in 1...5 {
            let base = 5 + 4 * (b - 1), id = "b\(b)"
            freq(k(id, "Freq"), base, [100, 400, 1_500, 4_000, 10_000][b - 1]); q(k(id, "Q"), base + 1)
            gain(k(id, "Gain"), base + 2); e.parameters[k(id, "On")] = on(base + 3)
        }
        e.parameters[k("hp", "On")] = on(38); freq(k("hp", "Freq"), 39, 80)
        e.parameters[k("lp", "On")] = on(41); freq(k("lp", "Freq"), 42, 16_000)
    }

    // MARK: Effects

    mutating func effects(_ item: PRItem, ctx: ClipContext, frame: Vec2, textOffset: Vec2) -> [ClipEffect] {
        var out = [ClipEffect]()
        for comp in item.components where !comp.isAudio {
            switch comp.matchName {
            case "AE.ADBE Motion":
                // Motion's crop (params 8-11, %) as a Crop effect.
                let ids = [8, 9, 10, 11], keys = [ClipEffect.cropLeftKey, ClipEffect.cropTopKey, ClipEffect.cropRightKey, ClipEffect.cropBottomKey]
                guard ids.contains(where: { (PRParamValue.double(comp.param($0)?.staticValue) ?? 0) != 0 || comp.param($0)?.isAnimated == true })
                else { continue }
                var e = ClipEffect.make(kind: ClipEffect.cropKind)!
                for (id, key) in zip(ids, keys) { e.parameters[key] = ctx.animated(comp.param(id), 0, PRParamValue.double) { $0 } }
                out.append(e)
                report.note("Motion crop", .mapped)
            case "AE.ADBE Opacity", "AE.ADBE Text", "AE.ADBE MPEG.SourceSettings", "AE.ADBE Graphic Group":
                continue
            case "AE.ADBE Shape" where item.isAdjustmentLayer || mapShapes:
                continue        // layer of an adjustment graphic: not drawn; its area is judged in adjustmentClip
            case "AE.ADBE Geometry2":
                out.append(transformStage(comp, ctx: ctx, frame: frame, textOffset: textOffset))
            case "AE.ADBE Gaussian Blur 2", "AE.ADBE Gaussian Blur":
                var e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
                // Blurriness 1:1: SQ's Gaussian Blur uses Premiere's units (ClipEffect.gaussianSigmaPerBlurriness).
                e.parameters[ClipEffect.blurrinessKey] = ctx.animated(comp.param(1), 0, PRParamValue.double) { $0 }
                // Repeat Edge Pixels (param 3): the edge stays opaque instead of fading into black.
                if PRParamValue.bool(comp.param(3)?.staticValue) == true {
                    e.parameters[ClipEffect.repeatEdgePixelsKey] = AnimatedProperty(1)
                }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE Drop Shadow":
                var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
                if let col = PRParamValue.color(comp.param(1)?.staticValue) {
                    e.colors[ClipEffect.shadowColorKey] = AnimatedProperty(EffectColor(red: col.red, green: col.green, blue: col.blue))
                }
                e.parameters[ClipEffect.shadowOpacityKey] = ctx.animated(comp.param(2), 50, PRParamValue.double) { $0 / 255 * 100 }
                e.parameters[ClipEffect.shadowDirectionKey] = ctx.animated(comp.param(3), 135, PRParamValue.double) { $0 }
                e.parameters[ClipEffect.shadowDistanceKey] = ctx.animated(comp.param(4), 5, PRParamValue.double) { $0 }
                e.parameters[ClipEffect.shadowSoftnessKey] = ctx.animated(comp.param(5), 5, PRParamValue.double) { $0 }
                if PRParamValue.bool(comp.param(6)?.staticValue) == true { e.parameters[ClipEffect.shadowOnlyKey] = AnimatedProperty(1) }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE Lumetri":
                if let e = lumetri(comp) { out.append(e) }
                if let e = lumetriSharpen(comp) { out.append(e) }
            case "AE.ADBE Mosaic":
                var e = ClipEffect.make(kind: ClipEffect.mosaicKind)!
                e.parameters[ClipEffect.mosaicColumnsKey] = ctx.animated(comp.param(1), 10, PRParamValue.double) { $0 }
                e.parameters[ClipEffect.mosaicRowsKey] = ctx.animated(comp.param(2), 10, PRParamValue.double) { $0 }
                if PRParamValue.bool(comp.param(3)?.staticValue) == true { e.parameters[ClipEffect.mosaicSharpKey] = AnimatedProperty(1) }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE Tint":
                var e = ClipEffect.make(kind: ClipEffect.tintKind)!
                if let c = PRParamValue.color(comp.param(1)?.staticValue) {
                    e.colors[ClipEffect.tintBlackKey] = AnimatedProperty(EffectColor(red: c.red, green: c.green, blue: c.blue))
                }
                if let c = PRParamValue.color(comp.param(2)?.staticValue) {
                    e.colors[ClipEffect.tintWhiteKey] = AnimatedProperty(EffectColor(red: c.red, green: c.green, blue: c.blue))
                }
                e.parameters[ClipEffect.tintAmountKey] = ctx.animated(comp.param(3), 100, PRParamValue.double) { $0 }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE Horizontal Flip":
                out.append(ClipEffect.make(kind: ClipEffect.horizontalFlipKind)!)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE_Noise_FX":
                // Premiere's grain effect (Intensity 3, Saturation 8, Master 10): the closest SQ effect is Noise.
                var e = ClipEffect.make(kind: ClipEffect.noiseKind)!
                let master = (PRParamValue.double(comp.param(10)?.staticValue) ?? 100) / 100
                e.parameters[ClipEffect.noiseAmountKey] = ctx.animated(comp.param(3), 50, PRParamValue.double) { min(100, $0 * master) }
                let sat = PRParamValue.double(comp.param(8)?.staticValue) ?? 50
                e.parameters[ClipEffect.noiseColorKey] = AnimatedProperty(sat > 0 ? 1 : 0)
                out.append(e)
                report.note(comp.matchName, .approximated, "film grain drawn as Noise (Intensity x Master); shadow/midtone/highlight split and blend mode dropped")
            case "AE.ADBE Motion Blur", "AE.ADBE Directional Blur":
                // Directional Blur (legacy match name "Motion Blur"): direction 0 = vertical smear, length px.
                var e = ClipEffect.make(kind: ClipEffect.directionalBlurKind)!
                e.parameters[ClipEffect.blurDirectionKey] = ctx.animated(comp.param(1), 0, PRParamValue.double) { $0 }
                e.parameters[ClipEffect.blurLengthKey] = ctx.animated(comp.param(2), 0, PRParamValue.double) { $0 }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.ADBE Alpha Adjust" where (PRParamValue.double(comp.param(1)?.staticValue) ?? 100) == 100
                && comp.param(1)?.isAnimated != true && PRParamValue.bool(comp.param(3)?.staticValue) != true
                && PRParamValue.bool(comp.param(4)?.staticValue) != true:
                report.note(comp.matchName, .mapped, "neutral (100 %, no invert / mask only): no effect needed")
            case "AE.ADBE Mirror" where out.contains { $0.kind == ClipEffect.transformKind && $0.parameters[ClipEffect.stageScaleKey]?.value != 100 }:
                // Measured on the "seamless slide" preset (Transform 200 % + Mirror + Transform 50 %): Premiere's reflection
                // line then lies outside the picture (it works in the enlarged layer's coordinates). SQ's stage space differs,
                // so the line would cut through the frame: dropped (fidelity 18.1 dB with it, 24.0 dB without).
                report.note(comp.matchName, .dropped, "after a scaled Transform (reflection line in Premiere's enlarged layer)")
            case "AE.ADBE Mirror":
                var e = ClipEffect.make(kind: ClipEffect.mirrorKind)!
                e.points[ClipEffect.mirrorCenterKey] = ctx.animated(comp.param(1), .zero, PRParamValue.point) {
                    Vec2(($0.x - 0.5) * frame.x - textOffset.x, ($0.y - 0.5) * frame.y - textOffset.y)
                }
                e.parameters[ClipEffect.mirrorAngleKey] = ctx.animated(comp.param(2), 0, PRParamValue.double) { $0 }
                out.append(e)
                report.note(comp.matchName, .mapped)
            case "AE.Impact_Crop_FX":
                out.append(contentsOf: roundedCrop(comp, ctx: ctx, frame: frame))
            case "AE.ADBE Ultra Key":
                if let e = ultraKey(comp, ctx: ctx) { out.append(e) }
            case "AE.ADBE Ramp":
                // Ramp (ids checked on the maintainer's instance): Start 1, Start Color 2, End 3, End Color 4, Shape 5 (0 linear,
                // 1 radial), Scatter 6, Blend With Original 7. Points are 0...1 of the frame; SQ's are px from its center.
                var e = ClipEffect.make(kind: ClipEffect.gradientKind)!
                func point(_ id: Int, _ fallback: Vec2) -> AnimatedProperty<Vec2> {
                    ctx.animated(comp.param(id), fallback, PRParamValue.point) {
                        Vec2(($0.x - 0.5) * frame.x - textOffset.x, ($0.y - 0.5) * frame.y - textOffset.y)
                    }
                }
                e.points[ClipEffect.gradientStartKey] = point(1, Vec2(0, -frame.y / 2))
                e.points[ClipEffect.gradientEndKey] = point(3, Vec2(0, frame.y / 2))
                for (id, key) in [(2, ClipEffect.gradientColor1Key), (4, ClipEffect.gradientColor2Key)] {
                    // Colors keep their keys; alpha is dropped like before (the ramp covers the frame).
                    guard PRParamValue.color(comp.param(id)?.staticValue) != nil || comp.param(id)?.isAnimated == true else { continue }
                    e.colors[key] = ctx.animated(comp.param(id), .black, PRParamValue.color) {
                        EffectColor(red: $0.red, green: $0.green, blue: $0.blue)
                    }
                }
                e.parameters[ClipEffect.gradientTypeKey] = AnimatedProperty(PRParamValue.double(comp.param(5)?.staticValue) == 1 ? 1 : 0)
                e.parameters[ClipEffect.gradientBlendKey] = ctx.animated(comp.param(7), 100, PRParamValue.double) { 100 - $0 }
                out.append(e)
                var lost = [String]()
                if (PRParamValue.double(comp.param(6)?.staticValue) ?? 0) != 0 { lost.append("Ramp Scatter dropped") }
                report.note(comp.matchName, lost.isEmpty ? .mapped : .approximated, lost.joined(separator: ", "))
            default:
                report.note(comp.matchName, .dropped, comp.displayName)
            }
        }
        return out
    }

    /// Ultra Key as SQ's Color Key. Param ids checked 2026-10-06 on the maintainer's four instances (German UI, all with Premiere's
    /// defaults except the key color): Output 1 (0 Composite, 1 Alpha Channel, 2 Color Channel), Setting 2, Key Color 3,
    /// Matte Generation 5-9 (Transparency, Highlight, Shadow, Tolerance, Pedestal), Matte Cleanup 12-15 (Choke, Soften,
    /// Contrast, Mid Point), Spill Suppression 18-21 (Desaturate, Range, Spill, Luma), Color Correction 24-26 (Saturation,
    /// Hue, Luminance); 4, 11, 17, 23 are the group headers. The key hue and the controls with the same meaning in SQ are
    /// copied (Premiere's Spill 20 is SQ's Spill; Desaturate 18 and spill Luma 21 have no SQ control and are not carried). Premiere's matte generation is a different formulation (the design notes, Keying family), so Tolerance,
    /// Soften, Keep Highlights and Keep Shadows start from SQ's Green Screen preset: approximated, to be tuned by eye.
    mutating func ultraKey(_ comp: PRComponent, ctx: ClipContext) -> ClipEffect? {
        guard let c = PRParamValue.color(comp.param(3)?.staticValue), let hue = Self.hue(c) else {
            report.note(comp.matchName, .dropped, "no key color picked (black or gray keys nothing)")
            return nil
        }
        var e = ClipEffect.make(kind: ClipEffect.ultraKeyKind)!
        e.parameters[ClipEffect.keyHueKey] = AnimatedProperty(hue)
        for (key, value) in [(ClipEffect.toleranceKey, 45.0), (ClipEffect.softenKey, 20), (ClipEffect.keyHighlightKey, 10),
                             (ClipEffect.keyShadowKey, 20)] {
            e.parameters[key] = AnimatedProperty(value)
        }
        for (id, key, fallback) in [(9, ClipEffect.pedestalKey, 10.0), (12, ClipEffect.chokeKey, 0), (14, ClipEffect.keyContrastKey, 0),
                                    (15, ClipEffect.keyMidpointKey, 50), (20, ClipEffect.spillKey, 50), (19, ClipEffect.spillRangeKey, 50),
                                    (24, ClipEffect.keySaturationKey, 100), (25, ClipEffect.keyHueShiftKey, 0), (26, ClipEffect.keyLumaKey, 100)] {
            e.parameters[key] = ctx.animated(comp.param(id), fallback, PRParamValue.double) { $0 }
        }
        // Alpha Channel shows the matte; Color Channel (the color before the matte applies) is closest to SQ's Source.
        let output = PRSafe.int(PRParamValue.double(comp.param(1)?.staticValue)) ?? 0
        e.parameters[ClipEffect.keyOutputKey] = AnimatedProperty(Double((0...2).contains(output) ? output : 0))
        report.note(comp.matchName, .approximated,
                    "key hue, matte clean-up, Spill, Range and color correction copied; Transparency, Highlight, Shadow, Tolerance and matte Soften use SQ's Green Screen starting values; spill Desaturate and Luma have no SQ control\(comp.param(3)?.isAnimated == true ? "; key colour keys dropped" : "")")
        return e
    }

    /// Hue in degrees (0...360) of a color; nil for black, white and grays.
    static func hue(_ c: EffectColor) -> Double? {
        let hi = max(c.red, c.green, c.blue), d = hi - min(c.red, c.green, c.blue)
        guard d > 0.02 else { return nil }
        let h: Double
        if hi == c.red { h = (c.green - c.blue) / d } else if hi == c.green { h = 2 + (c.blue - c.red) / d } else { h = 4 + (c.red - c.green) / d }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    mutating func transformStage(_ comp: PRComponent, ctx: ClipContext, frame: Vec2, textOffset: Vec2) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.transformKind)!
        func axis(_ id: Int, _ x: Bool) -> AnimatedProperty<Double> {
            ctx.animated(comp.param(id), 0, PRParamValue.point) {
                x ? ($0.x - 0.5) * frame.x - textOffset.x : ($0.y - 0.5) * frame.y - textOffset.y
            }
        }
        // Premiere maps q -> R s (q - A) + P; an SQ stage maps p -> R s (p - a) + a + position in the clip's own frame (the
        // text raster sits at `textOffset`): a = A - textOffset, position = P - A.
        e.parameters[ClipEffect.stageAnchorXKey] = axis(1, true)
        e.parameters[ClipEffect.stageAnchorYKey] = axis(1, false)
        let anchor = PRParamValue.point(comp.param(1)?.staticValue) ?? Vec2(0.5, 0.5)
        if comp.param(1)?.isAnimated == true { report.note("Transform anchor keys", .approximated, "position uses the static anchor") }
        e.parameters[ClipEffect.stagePositionXKey] = ctx.animated(comp.param(2), 0, PRParamValue.point) { ($0.x - anchor.x) * frame.x }
        e.parameters[ClipEffect.stagePositionYKey] = ctx.animated(comp.param(2), 0, PRParamValue.point) { ($0.y - anchor.y) * frame.y }
        e.parameters[ClipEffect.stageScaleKey] = ctx.animated(comp.param(3), 100, PRParamValue.double) { $0 }
        e.parameters[ClipEffect.stageRotationKey] = ctx.animated(comp.param(7), 0, PRParamValue.double) { $0 }
        e.parameters[ClipEffect.stageOpacityKey] = ctx.animated(comp.param(8), 100, PRParamValue.double) { $0 }
        if PRParamValue.bool(comp.param(9)?.staticValue) == false {
            e.parameters[ClipEffect.stageShutterAngleKey] = ctx.animated(comp.param(10), 0, PRParamValue.double) { $0 }
        }
        var approx = [String]()
        if PRParamValue.bool(comp.param(11)?.staticValue) == false,
           (PRParamValue.double(comp.param(4)?.staticValue) ?? 100) != (PRParamValue.double(comp.param(3)?.staticValue) ?? 100) {
            approx.append("non-uniform scale (height used)")
        }
        if (PRParamValue.double(comp.param(5)?.staticValue) ?? 0) != 0 || comp.param(5)?.isAnimated == true { approx.append("skew") }
        report.note("AE.ADBE Geometry2", approx.isEmpty ? .mapped : .approximated, approx.joined(separator: ", "))
        return e
    }

    /// Lumetri Creative > Sharpen (param 29, -100...100; 20 is the maintainer's usual value) as a Sharpen effect after the Color effect.
    /// Only positive values: a negative amount would be a blur. Static value; units differ slightly (approximated).
    mutating func lumetriSharpen(_ comp: PRComponent) -> ClipEffect? {
        guard PRParamValue.bool(comp.param(23)?.staticValue) != false,
              let amount = PRParamValue.double(comp.param(29)?.staticValue), amount > 0 else { return nil }
        var e = ClipEffect.make(kind: ClipEffect.sharpenKind)!
        e.parameters[ClipEffect.sharpenAmountKey] = AnimatedProperty(amount)
        report.note("Lumetri sharpen", .approximated, "Lumetri Sharpen amount used as SQ Sharpen amount")
        return e
    }

    mutating func lumetri(_ comp: PRComponent) -> ClipEffect? {
        if PRParamValue.bool(comp.param(3)?.staticValue) == false {
            report.note("AE.ADBE Lumetri", .approximated, "Basic Correction off: only Basic is read")
            return nil
        }
        var c = ColorEffect(id: 1)
        func v(_ id: Int) -> Float? { PRParamValue.double(comp.param(id)?.staticValue).map(Float.init) }
        if let x = v(7) { c.basic.temperature = x }
        if let x = v(8) { c.basic.tint = x }
        if let x = v(11) { c.basic.exposure = x }
        if let x = v(12) { c.basic.contrast = x }
        if let x = v(13) { c.basic.highlights = x }
        if let x = v(14) { c.basic.shadows = x }
        if let x = v(15) { c.basic.whites = x }
        if let x = v(16) { c.basic.blacks = x }
        if let x = v(20) { c.basic.saturation = x }
        if let x = v(30) { c.basic.vibrance = x }
        // Creative (switch 23): look LUT path (24, UTF-16LE) and intensity (26), faded film (28), saturation (31).
        if PRParamValue.bool(comp.param(23)?.staticValue) != false {
            if let x = v(28) { c.creative.fadedFilm = x }
            if let x = v(31) { c.creative.saturation = x }
            if let path = Self.lutPath(comp.param(24)?.blob) {
                c.creative.look = .file(path)
                if let x = v(26) { c.creative.intensity = x }
                report.note("Lumetri look LUT", .mapped)
                // Look color space (130): Premiere converts the LUT output from that space into the sequence space.
                if PRParamValue.double(comp.param(130)?.staticValue) == Self.lookSpaceRec709Gamma24 {
                    c.curves.master = Self.lookSpaceCurve
                    report.note("Lumetri look color space", .approximated, "Rec.709 gamma 2.4 look output as a master curve (power 2.4/1.961)")
                }
            }
        }
        // Curves (switch 37): RGB curves blob (39) = master, red, green, blue.
        if PRParamValue.bool(comp.param(37)?.staticValue) != false, let curves = Self.rgbCurves(comp.param(39)?.blob) {
            if !curves.isNeutral {
                c.curves.master = Self.composed(curves.master, after: c.curves.master)
                c.curves.red = curves.red; c.curves.green = curves.green; c.curves.blue = curves.blue
                report.note("Lumetri RGB curves", .mapped)
            }
        }
        // Vignette (switch 50): amount 51, midpoint 52, roundness 53, feather 54.
        if PRParamValue.bool(comp.param(50)?.staticValue) != false, let amount = v(51), amount != 0 {
            c.vignette.amount = amount
            if let x = v(52) { c.vignette.midpoint = x }
            if let x = v(53) { c.vignette.roundness = x }
            if let x = v(54) { c.vignette.feather = x }
            report.note("Lumetri vignette", .mapped)
        }
        // Color wheels (switch 46, blob 47): decoded, never applied (the design notes 2026-10-06: the luma scale and wheel
        // order rest on one sample and SQ's wheel maths is not Lumetri's). Every set wheel is counted, never silent.
        if PRParamValue.bool(comp.param(46)?.staticValue) != false {
            switch Self.wheels(comp.param(47)?.blob) {
            case .absent: break
            case .unreadable:
                report.note("Lumetri color wheels", .dropped, Self.wheelsDroppedNote)
            case .values(let w):
                if w.lumaEdited || w.pucksEdited { report.note("Lumetri color wheels", .dropped, Self.wheelsDroppedNote) }
                if w.specularEdited { report.note("Lumetri HDR specular wheel", .dropped, "no SQ equivalent") }
            }
        }
        // Hue Saturation Curves: flat blobs (point count 0) are skipped; an edited curve is counted, never silent.
        if Self.hueCurveIDs.contains(where: { Self.hueCurveEdited(comp.param($0)?.blob) }) {
            report.note("Lumetri hue saturation curves", .dropped, "point scale not decoded (no sample with an edited curve)")
        }
        let keyed = comp.params.contains { $0.isAnimated }
        report.note("AE.ADBE Lumetri", .approximated,
                    "Basic, Creative, RGB curves, vignette, look LUT (static)\(keyed ? ", keys dropped" : ""); wheels, hue curves and HSL not read")
        return ClipEffect.colorGrade(c)
    }

    /// Lumetri Color Wheels blob (param 47), checked 2026-10-06 on all 809 Lumetri instances of the maintainer's 16 projects plus the
    /// 325 Lumetri presets shipped with Premiere 26: little-endian doubles, three per wheel (puck a, luma slider, puck b),
    /// neutral (0, 0.5, 0). Premiere 25/26 writes four wheels (96 bytes; the fourth is the HDR Specular wheel, appended to
    /// the three-wheel 72-byte layout of the presets). Only one instance was edited (luma 0.4977 and 0.4388 on wheels one
    /// and two, pucks untouched), so the wheel order (Shadows, Midtones, Highlights, the order of Premiere's own label
    /// strings) and the slider scale are inferred, and the puck pair's meaning (x/y or hue/amount) is unknown.
    /// Nothing of it is applied to the grade until it is verified against a Premiere render.
    struct LumetriWheels {
        var values: [Double]
        /// Luma slider of wheel `i` in SQ units (-100...100), by the inferred scale.
        func luma(_ i: Int) -> Float { Float((values[3 * i + 1] - 0.5) * 200) }
        private func edited(_ i: Int) -> Bool { abs(values[i] - (i % 3 == 1 ? 0.5 : 0)) > 1e-9 }
        var lumaEdited: Bool { [1, 4, 7].contains(where: edited) }
        var pucksEdited: Bool { [0, 2, 3, 5, 6, 8].contains(where: edited) }
        var specularEdited: Bool { values.count == 12 && (9..<12).contains(where: edited) }
    }

    /// One report text for every wheel loss (the report keeps the first note per feature).
    static let wheelsDroppedNote = "luma sliders decoded, not applied (scale and wheel order unverified against a Premiere render); puck colors and unreadable blobs not decoded"

    enum WheelBlob {
        /// No blob (the param is missing or empty).
        case absent
        /// A blob that is not 9 or 12 finite doubles within -1...1: the layout this decoder knows does not fit.
        case unreadable
        case values(LumetriWheels)
    }

    static func wheels(_ base64: String?) -> WheelBlob {
        guard let base64, !base64.isEmpty else { return .absent }
        guard let data = Data(base64Encoded: base64), data.count == 72 || data.count == 96 else { return .unreadable }
        let values = (0..<data.count / 8).map { i -> Double in
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(data[data.startIndex + i * 8 + k]) << UInt64(8 * k) }
            return Double(bitPattern: bits)
        }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { return .unreadable }
        return .values(LumetriWheels(values: values))
    }

    /// Hue Saturation Curves params: Hue vs Sat (42), Hue vs Hue (106), Hue vs Luma (108), Luma vs Sat (110), Sat vs Sat (112).
    static let hueCurveIDs = [42, 106, 108, 110, 112]

    /// A hue curve blob (520 bytes: UInt32 axis kind, 3 = hue axis, 2 = luma/sat axis, 1 in old presets; UInt32 point
    /// count; then 32 (x, y) doubles like the RGB curves) with points set. All 4,045 hue curve blobs in the maintainer's projects
    /// have count 0 (flat, with stale default points after it).
    static func hueCurveEdited(_ base64: String?) -> Bool {
        guard let base64, let data = Data(base64Encoded: base64), data.count == 520 else { return false }
        let count = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + 4 + $1]) << UInt32(8 * $1) }
        return count > 0
    }

    /// Lumetri RGB curves blob (param 39): four blocks of 520 bytes (master, red, green, blue), each
    /// `UInt32 0, UInt32 pointCount, 32 x (x, y: Double)`. nil when the blob is missing or does not parse.
    static func rgbCurves(_ base64: String?) -> RGBCurves? {
        guard let base64, let data = Data(base64Encoded: base64), data.count >= 4 * 520 else { return nil }
        func double(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(data[data.startIndex + o + i]) << UInt64(8 * i) }
            return Double(bitPattern: bits)
        }
        func block(_ i: Int) -> [CurvePoint]? {
            let base = i * 520
            let n = Int(data[data.startIndex + base + 4])
            guard (2...32).contains(n) else { return nil }
            let pts = (0..<n).map { CurvePoint(Float(double(base + 8 + 16 * $0)), Float(double(base + 16 + 16 * $0))) }
            guard pts.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  zip(pts, pts.dropFirst()).allSatisfy({ $0.x < $1.x }) else { return nil }
            return pts
        }
        guard let m = block(0), let r = block(1), let g = block(2), let b = block(3) else { return nil }
        var c = RGBCurves()
        c.master = m; c.red = r; c.green = g; c.blue = b
        return c
    }

    /// The user's master curve applied after `first` (the look-space curve or the diagonal): sampled at `first`'s points,
    /// the user curve interpolated linearly.
    static func composed(_ user: [CurvePoint], after first: [CurvePoint]) -> [CurvePoint] {
        if first == RGBCurves.diagonal { return user }
        func eval(_ x: Float) -> Float {
            guard let i = user.firstIndex(where: { $0.x >= x }) else { return user.last?.y ?? x }
            if i == 0 || user[i].x == x { return user[i].y }
            let a = user[i - 1], b = user[i]
            return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
        }
        return first.map { CurvePoint($0.x, eval($0.y)) }
    }

    /// Lumetri look color space id (param 130) seen on every graded clip of iOS 27 Features #1. Measured with
    /// Tools/PrprojFidelity: Premiere's output = (LUT output)^1.224 on all 40 graded clips (a clean power law over the whole
    /// range, = 2.4 / 1.961: the look output read as gamma 2.4 and written as Rec.709 at gamma 1.961).
    static let lookSpaceRec709Gamma24 = 28.0
    static let lookSpaceGamma: Float = 2.4 / 1.961
    /// The power law as master-curve points (denser at the dark end where it bends most).
    static let lookSpaceCurve: [CurvePoint] = [0, 0.03, 0.07, 0.12, 0.2, 0.3, 0.42, 0.55, 0.7, 0.85, 1].map {
        CurvePoint($0, Float(pow(Double($0), Double(lookSpaceGamma))))
    }

    /// Premiere 25 color management shows files tagged "BT.709,…,Display-Referred" with the same power law as the look
    /// color space (gamma 2.4 read, 1.961 out). Full-range RGB graphics ("BT.709 RGB Full") pass unchanged.
    static func isDisplayReferred709(_ profile: String?) -> Bool {
        guard let p = profile else { return false }
        return p.hasPrefix("BT.709") && p.contains("Display-Referred")
    }

    /// Puts the display-gamma curve on the clip's first Color effect (master curve, unless Lumetri already set one),
    /// or adds a Color effect holding only that curve in front of the other effects.
    mutating func applyDisplayGamma(to c: inout Clip) {
        report.note("Premiere display gamma", .approximated, "BT.709 display-referred source: master curve (power 2.4/1.961)")
        if let i = c.effects.firstIndex(where: \.isColor) {
            var e = c.effects[i].colorEffect(atLocal: nil, id: 1)
            guard e.curves.master.count <= 2 else { return }
            e.curves.master = Self.lookSpaceCurve
            c.effects[i].setColorEffect(e, atLocal: nil)
        } else {
            var e = ColorEffect(id: 1)
            e.curves.master = Self.lookSpaceCurve
            c.effects.insert(ClipEffect.colorGrade(e), at: 0)
        }
    }

    /// A LUT file path stored as a NUL-terminated UTF-16LE string (Lumetri Look / Input LUT).
    static func lutPath(_ base64: String?) -> String? {
        guard let base64, let data = Data(base64Encoded: base64), data.count >= 4 else { return nil }
        let units = stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8 }
        let path = String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
        return path.hasPrefix("/") && path.lowercased().hasSuffix(".cube") ? path : nil
    }

    /// Impact Rounded Crop: crop % per side + roundness (as a share of half the short side).
    mutating func roundedCrop(_ comp: PRComponent, ctx: ClipContext, frame: Vec2) -> [ClipEffect] {
        var out = [ClipEffect]()
        let sides = [(8182, ClipEffect.cropLeftKey), (8184, ClipEffect.cropTopKey), (8183, ClipEffect.cropRightKey), (8185, ClipEffect.cropBottomKey)]
        if sides.contains(where: { (PRParamValue.double(comp.param($0.0)?.staticValue) ?? 0) != 0 || comp.param($0.0)?.isAnimated == true }) {
            var e = ClipEffect.make(kind: ClipEffect.cropKind)!
            for (id, key) in sides { e.parameters[key] = ctx.animated(comp.param(id), 0, PRParamValue.double) { $0 } }
            out.append(e)
        }
        let round = PRParamValue.double(comp.param(8187)?.staticValue) ?? 0
        if round > 0 { out.append(ClipEffect.roundedCorners(radius: round / 100 * min(frame.x, frame.y) / 2)) }
        report.note("AE.Impact_Crop_FX", .approximated, "Crop + Rounded Corners; roundness scale and feather estimated")
        return out
    }
}

/// Converts one item's Premiere params into clip-local animated properties.
struct ClipContext {
    let inPoint: Int64
    let speed: ClipSpeed
    let sequence: PRSequence

    /// Key time (absolute source ticks) -> clip-local timeline time.
    func local(_ ticks: Int64) -> Time { speed.unscale(PRTicks.time(PRTicks.sub(ticks, inPoint))) }

    func animated<R, V: KeyframeValue>(_ p: PRParamValue?, _ fallback: V, _ parse: (String?) -> R?, _ convert: (R) -> V) -> AnimatedProperty<V> {
        guard let p else { return AnimatedProperty(fallback) }
        let value = parse(p.staticValue).map(convert) ?? fallback
        var keys = [Keyframe<V>]()
        // Raw (Premiere unit) values: slopes are in those units per second.
        let parsed = p.keys.compactMap { k in parse(k.value).map { (key: k, raw: $0, value: convert($0)) } }
        for (i, e) in parsed.enumerated() {
            var key = Keyframe(time: local(e.key.ticks), value: e.value)
            switch e.key.interpolation {
            case 4: key.interpolation = .hold
            case 5...8:
                key.interpolation = .bezier
                if i + 1 < parsed.count {
                    let n = parsed[i + 1]
                    key.outHandle = handle(slope: e.key.outSlope, influence: e.key.outInfluence, from: e.key, e.raw, to: n.key, n.raw)
                }
            default: break
            }
            // The in-handle shapes the segment that ends here: it counts whenever that segment is a curve (this key or the
            // one before is bezier), also on a linear key after a bezier one.
            if i > 0, (5...8).contains(e.key.interpolation) || (5...8).contains(parsed[i - 1].key.interpolation) {
                let p = parsed[i - 1]
                key.inHandle = handle(slope: e.key.inSlope, influence: e.key.inInfluence, from: p.key, p.raw, to: e.key, e.raw)
            }
            keys.append(key)
        }
        return AnimatedProperty(keys.isEmpty ? value : keys[0].value, track: KeyframeTrack(keys: keys))
    }

    /// Premiere's speed (value units per second) + influence (share of the segment) as a normalized bezier handle.
    func handle<R>(slope: Double, influence: Double, from a: PRKey, _ va: R, to b: PRKey, _ vb: R) -> EaseHandle {
        let dx = min(max(influence, 0), 1)
        let seconds = (Double(b.ticks) - Double(a.ticks)) / Double(PRTicks.perSecond)
        let delta = distance(va, vb)
        guard abs(delta) > 1e-12 else { return EaseHandle(dx: dx, dy: 0) }
        return EaseHandle(dx: dx, dy: slope * dx * seconds / delta)
    }

    func distance<R>(_ a: R, _ b: R) -> Double {
        if let a = a as? Double, let b = b as? Double { return b - a }
        if let a = a as? Vec2, let b = b as? Vec2 { return (b - a).length }
        return 1
    }
}
