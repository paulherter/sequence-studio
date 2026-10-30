import Foundation

// W6.7 MasksV1: masks on a clip's picture, like Premiere's Opacity masks. They cut the finished picture of the clip (after
// all effects), before its Motion places it: the mask moves with the clip. Stored in `Clip.masks` (ProjectFile v32).

/// One point of a mask path: position and bezier tangents (offsets from the point), all in fractions of the clip's own frame
/// (0...1, origin top left, y down), so a mask survives proxies and reduced-quality decodes.
public struct MaskVertex: Sendable, Hashable, Codable {
    public var point: Vec2
    public var inTangent: Vec2
    public var outTangent: Vec2
    public init(_ point: Vec2, inTangent: Vec2 = .zero, outTangent: Vec2 = .zero) {
        self.point = point; self.inTangent = inTangent; self.outTangent = outTangent
    }
    public var isCorner: Bool { inTangent == .zero && outTangent == .zero }
}

/// A closed bezier path. Rectangle and ellipse are just paths with four vertices (as in Premiere, they stay editable).
public struct MaskPath: Sendable, Hashable, Codable {
    public var vertices: [MaskVertex]
    public init(vertices: [MaskVertex]) { self.vertices = vertices }

    /// Line pieces per curved segment when flattened (`polygon()`).
    public static let curveSubdivisions = 16
    /// Most polygon points one mask hands to the renderer.
    public static let maxPolygonPoints = 1024

    /// Corners clockwise from the top left.
    public static func rectangle(_ a: Vec2, _ b: Vec2) -> MaskPath {
        let lo = Vec2(min(a.x, b.x), min(a.y, b.y)), hi = Vec2(max(a.x, b.x), max(a.y, b.y))
        return MaskPath(vertices: [MaskVertex(lo), MaskVertex(Vec2(hi.x, lo.y)), MaskVertex(hi), MaskVertex(Vec2(lo.x, hi.y))])
    }

    /// Four-point bezier ellipse (top, right, bottom, left), tangents at the circle constant.
    public static func ellipse(center c: Vec2, radius r: Vec2) -> MaskPath {
        let k = 0.5522847498307936
        let kx = r.x * k, ky = r.y * k
        return MaskPath(vertices: [
            MaskVertex(Vec2(c.x, c.y - r.y), inTangent: Vec2(-kx, 0), outTangent: Vec2(kx, 0)),
            MaskVertex(Vec2(c.x + r.x, c.y), inTangent: Vec2(0, -ky), outTangent: Vec2(0, ky)),
            MaskVertex(Vec2(c.x, c.y + r.y), inTangent: Vec2(kx, 0), outTangent: Vec2(-kx, 0)),
            MaskVertex(Vec2(c.x - r.x, c.y), inTangent: Vec2(0, ky), outTangent: Vec2(0, -ky)),
        ])
    }

    /// The path as a closed polygon (frame fractions): straight segments give one point, curved ones `curveSubdivisions`.
    public func polygon() -> [Vec2] {
        let n = vertices.count
        guard n > 0 else { return [] }
        var out: [Vec2] = []
        out.reserveCapacity(n * 4)
        for i in 0..<n {
            let a = vertices[i], b = vertices[(i + 1) % n]
            out.append(a.point)
            guard a.outTangent != .zero || b.inTangent != .zero else { continue }
            let p0 = a.point, p1 = a.point + a.outTangent, p2 = b.point + b.inTangent, p3 = b.point
            for s in 1..<Self.curveSubdivisions {
                let t = Double(s) / Double(Self.curveSubdivisions), u = 1 - t
                let w0: Double = u * u * u, w1: Double = 3 * u * u * t, w2: Double = 3 * u * t * t, w3: Double = t * t * t
                let x: Double = p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3
                let y: Double = p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3
                out.append(Vec2(x, y))
            }
        }
        if out.count > Self.maxPolygonPoints {
            let step = Double(out.count) / Double(Self.maxPolygonPoints)
            out = (0..<Self.maxPolygonPoints).map { out[Int(Double($0) * step)] }
        }
        return out
    }

    /// Moves a vertex; its tangents go along.
    public mutating func moveVertex(_ i: Int, to p: Vec2) {
        guard vertices.indices.contains(i) else { return }
        vertices[i].point = p
    }

    /// Moves every vertex by `d` (frame fractions).
    public func translated(by d: Vec2) -> MaskPath {
        MaskPath(vertices: vertices.map { var v = $0; v.point = v.point + d; return v })
    }

    /// The vertex within `radius` px of `p` (frame px, `frame` = frame size in px), the nearest one; nil when none.
    public func vertexIndex(near p: Vec2, frame: Vec2, radius: Double) -> Int? {
        var best: (Int, Double)?
        for (i, v) in vertices.enumerated() {
            let d = (Vec2(v.point.x * frame.x, v.point.y * frame.y) - p).length
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }
}

extension MaskVertex {
    static func sum(_ a: MaskVertex, _ b: MaskVertex) -> MaskVertex {
        MaskVertex(a.point + b.point, inTangent: a.inTangent + b.inTangent, outTangent: a.outTangent + b.outTangent)
    }
    static func difference(_ a: MaskVertex, _ b: MaskVertex) -> MaskVertex {
        MaskVertex(a.point - b.point, inTangent: a.inTangent - b.inTangent, outTangent: a.outTangent - b.outTangent)
    }
}

/// Path keys interpolate vertex by vertex. Two paths with different vertex counts cannot be blended: the earlier one holds
/// until the next key (Premiere does the same after a vertex was added on one key only).
extension MaskPath: KeyframeValue {
    public static func lerp(_ a: MaskPath, _ b: MaskPath, _ t: Double) -> MaskPath {
        guard a.vertices.count == b.vertices.count else { return t < 1 ? a : b }
        var out = a
        for i in out.vertices.indices {
            let x = a.vertices[i], y = b.vertices[i]
            out.vertices[i] = MaskVertex(Vec2.lerp(x.point, y.point, t), inTangent: Vec2.lerp(x.inTangent, y.inTangent, t),
                                         outTangent: Vec2.lerp(x.outTangent, y.outTangent, t))
        }
        return out
    }
    public static func + (a: MaskPath, b: MaskPath) -> MaskPath {
        guard a.vertices.count == b.vertices.count else { return a }
        var out = a
        for i in out.vertices.indices { out.vertices[i] = MaskVertex.sum(a.vertices[i], b.vertices[i]) }
        return out
    }
    public static func - (a: MaskPath, b: MaskPath) -> MaskPath {
        var out = a
        guard a.vertices.count == b.vertices.count else {
            for i in out.vertices.indices { out.vertices[i] = MaskVertex(.zero) }
            return out
        }
        for i in out.vertices.indices { out.vertices[i] = MaskVertex.difference(a.vertices[i], b.vertices[i]) }
        return out
    }
    /// Largest vertex move.
    public var speedMagnitude: Double { vertices.map(\.point.length).max() ?? 0 }
}

/// How a mask combines with the masks above it in the list (Premiere's Mask Mode, After Effects semantics).
public enum MaskMode: String, Sendable, Hashable, Codable, CaseIterable {
    case add, subtract, intersect, difference
    public var title: String {
        switch self {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .difference: "Difference"
        }
    }
}

/// Which tool drew the mask (UI only; the path is the truth).
public enum MaskShapeKind: String, Sendable, Hashable, Codable { case rectangle, ellipse, bezier }

/// A mask on a clip. Values are keyframable, keys are clip-local (like `ClipAnimation`).
public struct ClipMask: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: MaskShapeKind
    public var enabled: Bool
    public var mode: MaskMode
    public var inverted: Bool
    public var path: AnimatedProperty<MaskPath>
    /// Soft edge width in px of the clip's own frame, centered on the path (half inside, half outside). >= 0.
    public var feather: AnimatedProperty<Double>
    /// 0...100 %.
    public var opacity: AnimatedProperty<Double>
    /// Grows (positive) or shrinks the shape, px of the clip's own frame.
    public var expansion: AnimatedProperty<Double>
    /// W9.8: where the shape comes from. Stored only when not `.path` (optional key "source", ProjectFile v37 gate): a path
    /// mask encodes as before; an older build reads a subject mask as its path (a full-frame rectangle, nothing cut).
    var sourceStore: MaskSource?
    public var source: MaskSource {
        get { sourceStore ?? .path }
        set { sourceStore = newValue == .path ? nil : newValue }
    }
    /// Magic masks: the picked points (v54). nil for other sources.
    public var magic: MagicSelection?
    /// v54: false = the mask only feeds the effects that take it as input (`ClipEffect.maskInput`) and no longer cuts the
    /// clip's picture (Opacity). Stored only when false ("opacityOff").
    var opacityOffStore: Bool?
    public var usedByOpacity: Bool {
        get { opacityOffStore != true }
        set { opacityOffStore = newValue ? nil : true }
    }

    /// C6 Picture masks (v65): the video track of the same timeline whose picture is the matte; nil = none picked (or the
    /// track was deleted): covers nothing. Stored only when set.
    public var pictureTrack: Track.ID?
    /// C6: which channel of that picture is read. Stored only when not `.shape` on a Picture mask ("pictureChannel").
    var pictureChannelStore: MatteChannel?
    public var pictureChannel: MatteChannel {
        get { source == .picture ? pictureChannelStore ?? .shape : .shape }
        set { pictureChannelStore = newValue == .shape || source != .picture ? nil : newValue }
    }

    /// v87 Color range masks: the picked color and its tolerance / softness. Stored only on a `.colorRange` mask
    /// ("colorRange"); not keyframable (shortcut: one static pick, upgrade when a key must follow a changing picture).
    var colorRangeStore: ColorRangeKey?
    public var colorRange: ColorRangeKey {
        get { source == .colorRange ? colorRangeStore ?? .default : .default }
        set { colorRangeStore = source == .colorRange ? newValue : nil }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, mode, inverted, path, feather, opacity, expansion, magic, pictureTrack
        case colorRangeStore = "colorRange"
        case sourceStore = "source"
        case opacityOffStore = "opacityOff"
        case pictureChannelStore = "pictureChannel"
    }

    public static let defaultFeather = 10.0

    public init(id: UUID = UUID(), name: String = "Mask", kind: MaskShapeKind = .bezier, path: MaskPath,
                enabled: Bool = true, mode: MaskMode = .add, inverted: Bool = false,
                feather: Double = 0, opacity: Double = 100, expansion: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.mode = mode; self.inverted = inverted
        self.path = AnimatedProperty(path); self.feather = AnimatedProperty(feather)
        self.opacity = AnimatedProperty(opacity); self.expansion = AnimatedProperty(expansion)
    }

    /// A new Rectangle / Ellipse mask in the middle of the frame (half its size), Premiere's default feather.
    public static func make(_ kind: MaskShapeKind, name: String) -> ClipMask {
        let path = kind == .ellipse ? MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.25, 0.25))
            : MaskPath.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75))
        return ClipMask(name: name, kind: kind, path: path, feather: defaultFeather)
    }

    /// W9.8: a person matte (Vision) as the mask. The path is the whole frame, so a build without subject masks cuts nothing;
    /// feather, expansion and the path are not used while the source is `.subject`.
    public static func makeSubject(name: String) -> ClipMask {
        var m = ClipMask(name: name, kind: .rectangle, path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.source = .subject
        return m
    }

    /// A Magic mask: the objects under `points` (empty = nothing picked yet), followed by Track. The path is the whole
    /// frame so a build without Magic masks cuts nothing; Feather, Expansion and Opacity act on the matte edge.
    public static func makeMagic(name: String, points: [MagicPoint]) -> ClipMask {
        var m = ClipMask(name: name, kind: .rectangle, path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.source = .magic
        m.magic = MagicSelection(points: points)
        return m
    }

    /// C6: another track's picture as the mask (`track`: a video track of the same timeline, not the clip's own; see
    /// `Timeline.pictureMaskTracks`). The path is the whole frame so a build without Picture masks cuts nothing; Feather and
    /// Expansion are not used in v1.
    public static func makePicture(name: String = "Picture", track: Track.ID?) -> ClipMask {
        var m = ClipMask(name: name, kind: .rectangle, path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.source = .picture
        m.pictureTrack = track
        return m
    }

    /// v87: the picture's own color as the mask (`key`). The path is the whole frame so a build without Color range masks
    /// cuts nothing; Feather and Expansion are not used (Softness is the edge).
    public static func makeColorRange(name: String = "Color Range", key: ColorRangeKey = .default) -> ClipMask {
        var m = ClipMask(name: name, kind: .rectangle, path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.source = .colorRange
        m.colorRange = key
        return m
    }

    /// Values at clip-local `t`, clamped, path flattened (no polygon for Magic and Picture mattes).
    public func shape(atLocal t: Time) -> MaskShape {
        let picture = source == .picture
        var s = MaskShape(polygon: source == .magic || picture ? [] : path.value(atLocal: t).polygon(),
                          feather: picture ? 0 : max(0, feather.value(atLocal: t)),
                          expansion: picture ? 0 : expansion.value(atLocal: t), opacity: min(max(opacity.value(atLocal: t) / 100, 0), 1),
                          inverted: inverted, mode: mode, source: source, matteKey: source == .magic ? id : nil)
        if picture { s.pictureTrack = pictureTrack; s.pictureChannel = pictureChannel }
        if source == .colorRange { s.colorRange = colorRange; s.feather = 0; s.expansion = 0 }
        return s
    }

    /// Decodes like the synthesized form, but an unknown or explicit `.path` source is stored as nil, so the mask re-encodes
    /// without the key and equals a plain path mask.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(MaskShapeKind.self, forKey: .kind)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        mode = try c.decode(MaskMode.self, forKey: .mode)
        inverted = try c.decode(Bool.self, forKey: .inverted)
        path = try c.decode(AnimatedProperty<MaskPath>.self, forKey: .path)
        feather = try c.decode(AnimatedProperty<Double>.self, forKey: .feather)
        opacity = try c.decode(AnimatedProperty<Double>.self, forKey: .opacity)
        expansion = try c.decode(AnimatedProperty<Double>.self, forKey: .expansion)
        let src = try c.decodeIfPresent(MaskSource.self, forKey: .sourceStore)
        sourceStore = src == .path ? nil : src
        magic = try c.decodeIfPresent(MagicSelection.self, forKey: .magic)
        opacityOffStore = try c.decodeIfPresent(Bool.self, forKey: .opacityOffStore) == true ? true : nil
        pictureTrack = try c.decodeIfPresent(Track.ID.self, forKey: .pictureTrack)
        let ch = try c.decodeIfPresent(MatteChannel.self, forKey: .pictureChannelStore)
        pictureChannelStore = ch == .shape || sourceStore != .picture ? nil : ch
        colorRangeStore = sourceStore == .colorRange ? try c.decodeIfPresent(ColorRangeKey.self, forKey: .colorRangeStore) : nil
    }

    /// Times of the mask's keys.
    public var keyTimes: [Time] {
        path.track.keys.map(\.time) + feather.track.keys.map(\.time) + opacity.track.keys.map(\.time)
            + expansion.track.keys.map(\.time)
    }

    func remapped(_ f: (Time) -> Time) -> ClipMask {
        var m = self
        m.path = path.remapped(f); m.feather = feather.remapped(f); m.opacity = opacity.remapped(f); m.expansion = expansion.remapped(f)
        return m
    }

    func shifted(by d: Time) -> ClipMask {
        var m = self
        m.path = path.shifted(by: d); m.feather = feather.shifted(by: d)
        m.opacity = opacity.shifted(by: d); m.expansion = expansion.shifted(by: d)
        return m
    }

    func frozen(atLocal t: Time) -> ClipMask {
        var m = self
        m.path = AnimatedProperty(path.value(atLocal: t)); m.feather = AnimatedProperty(feather.value(atLocal: t))
        m.opacity = AnimatedProperty(opacity.value(atLocal: t)); m.expansion = AnimatedProperty(expansion.value(atLocal: t))
        return m
    }
}

/// One mask at one instant, what the renderer draws. `polygon` in frame fractions; `feather` / `expansion` in px of the
/// clip's own frame; `opacity` 0...1.
public struct MaskShape: Sendable, Hashable {
    public var polygon: [Vec2]
    public var feather: Double
    public var expansion: Double
    public var opacity: Double
    public var inverted: Bool
    public var mode: MaskMode
    /// `.subject`: the coverage is the layer's subject matte (`SubjectMatte`), the polygon is ignored.
    public var source: MaskSource
    /// `.magic`: the key of its matte in `RenderLayer.mattes` (the mask's id).
    public var matteKey: UUID?
    /// `.magic`: where the tracked mattes it draws are cached (`MagicSelection.matteKey(media:)`); set by the clip.
    public var matteCacheKey: String?
    /// `.magic`, Anonymize Face / Skin: where the followed whole person is cached (what covers when the narrowed matte of
    /// a frame is missing).
    public var matteBaseKey: String?
    /// `.magic`, made by Anonymize: a frame without a matte is covered by estimate, never left open.
    public var matteMustCover = false
    /// `.picture`: the track whose layers (`LayerRequest.matteFor` == this id, same `groups`) make the matte; nil = covers
    /// nothing. `pictureChannel`: what of that picture is read.
    public var pictureTrack: Track.ID?
    public var pictureChannel: MatteChannel = .shape
    /// `.colorRange`: the key; the coverage is `ColorRangeKey.value` of the picture's own pixel.
    public var colorRange: ColorRangeKey = .default
    public init(polygon: [Vec2], feather: Double = 0, expansion: Double = 0, opacity: Double = 1, inverted: Bool = false,
                mode: MaskMode = .add, source: MaskSource = .path, matteKey: UUID? = nil) {
        self.polygon = polygon; self.feather = feather; self.expansion = expansion; self.opacity = opacity
        self.inverted = inverted; self.mode = mode; self.source = source; self.matteKey = matteKey
    }
}

/// CPU reference of the mask maths in the compositor's fragment shader (`maskCoverage`). Same steps, in Double.
public enum MaskCoverage {
    /// The Opacity masks a layer draws with: a Magic mask without a usable matte on this frame (not tracked here, picked on
    /// another frame, or a blank matte) is left out, so it never cuts the whole picture to black. Effect inputs keep it
    /// (there "no matte" only means the effect applies nowhere).
    public static func opacityMasks(_ masks: [MaskShape], mattes: [UUID: SubjectMatte]) -> [MaskShape] {
        guard masks.contains(where: { $0.source == .magic }) else { return masks }
        return masks.filter { m in
            guard m.source == .magic else { return true }
            guard let k = m.matteKey, let x = mattes[k] else { return false }
            return !x.isBlank
        }
    }

    /// Signed distance (px, negative inside, even-odd rule) of `p` to the polygon `poly` (already in px).
    public static func signedDistance(_ p: Vec2, polygon poly: [Vec2]) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var d2 = Double.infinity
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[j], b = poly[i]
            let e = b - a, w = p - a
            let ee = e.x * e.x + e.y * e.y
            let t = ee > 0 ? min(max((w.x * e.x + w.y * e.y) / ee, 0), 1) : 0
            let q = w - e * t
            d2 = min(d2, q.x * q.x + q.y * q.y)
            if (b.y > p.y) != (a.y > p.y), p.x < (a.x - b.x) * (p.y - b.y) / (a.y - b.y) + b.x { inside.toggle() }
            j = i
        }
        let d = d2.squareRoot()
        return inside ? -d : d
    }

    /// One mask's own value 0...1 at signed distance `d` (px): expansion, feather (smoothstep across the edge) or a one-pixel
    /// edge ramp when the feather is narrower than `pixel` (frame px per output px), then invert and opacity.
    public static func value(distance d0: Double, _ m: MaskShape, pixel: Double) -> Double {
        let d = d0 - m.expansion
        var c: Double
        if m.feather > pixel {
            let h = m.feather / 2
            let x = min(max((d + h) / (2 * h), 0), 1)
            c = 1 - x * x * (3 - 2 * x)
        } else {
            c = min(max(0.5 - d / max(pixel, 1e-9), 0), 1)
        }
        if m.inverted { c = 1 - c }
        return c * m.opacity
    }

    /// The running coverage starts at 1 (whole frame) when the first mask is of this mode, else at 0.
    public static func startsFromFullFrame(_ mode: MaskMode) -> Bool { mode == .subtract || mode == .intersect }

    /// Combines one mask into the running coverage.
    public static func combine(_ acc: Double, _ v: Double, _ mode: MaskMode) -> Double {
        switch mode {
        case .add: min(acc + v, 1)
        case .subtract: max(acc - v, 0)
        case .intersect: acc * v
        case .difference: abs(acc - v)
        }
    }

    /// Coverage at `p` (px of the clip's frame, origin top left) of `masks` on a frame of `frame` px. The running value starts
    /// at 0, or at 1 (the whole frame) when the first mask subtracts or intersects, as in After Effects: a first Intersect
    /// shows its own area. A first Difference starts from 0, so it shows its own area like Add. No masks = 1 (nothing cut).
    /// W9.8: a subject mask reads `matte` (`subjectSample`); no matte (segmentation late or failed) = no person anywhere, so
    /// the clip never flashes in full.
    /// Magic masks read `mattes[matteKey]` the same way (no matte = not tracked there: nothing picked).
    /// C6 Picture masks read `picture(mask, p)`: the matte value (already through `pictureChannel`) at clip px `p`; nil = no
    /// matte there (missing track, empty spot): covers nothing.
    /// v87 Color range masks read `color(p)`: the picture's display-encoded straight color at clip px `p`; nil = no picture
    /// there: covers nothing.
    public static func coverage(at p: Vec2, masks: [MaskShape], frame: Vec2, pixel: Double,
                                matte: SubjectMatte? = nil, mattes: [UUID: SubjectMatte] = [:],
                                picture: (MaskShape, Vec2) -> Double? = { _, _ in nil },
                                color: (Vec2) -> (r: Double, g: Double, b: Double)? = { _ in nil }) -> Double {
        guard let first = masks.first else { return 1 }
        var acc: Double = Self.startsFromFullFrame(first.mode) ? 1 : 0
        for m in masks {
            let v: Double
            if m.source == .picture {
                v = subjectValue(m.pictureTrack == nil ? 0 : picture(m, p) ?? 0, m)
            } else if m.source == .colorRange {
                v = subjectValue(color(p).map { m.colorRange.value(red: $0.r, green: $0.g, blue: $0.b) } ?? 0, m)
            } else if m.source.usesMatte {
                let mt = m.source == .magic ? m.matteKey.flatMap { mattes[$0] } : matte
                v = subjectValue(mt.map { subjectSample($0, u: p.x / frame.x, v: p.y / frame.y) } ?? 0, m)
            } else {
                let poly = m.polygon.map { Vec2($0.x * frame.x, $0.y * frame.y) }
                v = value(distance: signedDistance(p, polygon: poly), m, pixel: pixel)
            }
            acc = combine(acc, v, m.mode)
        }
        return acc
    }

    /// The matte at frame fractions `(u, v)`: bilinear inside the clip's frame, 0 outside it (a blur-padded layer reaches past
    /// the frame; a person cut by the frame edge does not continue there).
    public static func subjectSample(_ matte: SubjectMatte, u: Double, v: Double) -> Double {
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return 0 }
        return matte.sample(u: u, v: v)
    }

    /// A subject mask's own value from the matte sample: invert, then opacity.
    public static func subjectValue(_ sample: Double, _ m: MaskShape) -> Double {
        var c = min(max(sample, 0), 1)
        if m.inverted { c = 1 - c }
        return c * m.opacity
    }
}

extension Clip {
    /// Masks on the picture, top first (v32). Setting an empty list stores nothing.
    public var masks: [ClipMask] {
        get { maskStore ?? [] }
        set { maskStore = newValue.isEmpty ? nil : newValue }
    }

    /// Enabled masks at clip-local `t`; none while the Opacity section is switched off.
    public func maskShapes(atLocal t: Time) -> [MaskShape] {
        guard opacityEnabled, let m = maskStore else { return [] }
        return m.filter { $0.enabled && $0.usedByOpacity }.map { maskShape($0, atLocal: t) }
            .filter { $0.polygon.count >= 2 || $0.source.usesMatte }
    }

    /// One mask's shape at `t`, a Magic mask with its matte cache key (needs the clip's media).
    func maskShape(_ m: ClipMask, atLocal t: Time) -> MaskShape {
        var s = m.shape(atLocal: t)
        if m.source == .magic {
            let sel = m.magic ?? MagicSelection()
            s.matteCacheKey = sel.matteKey(media: media)
            if sel.partKey(media: media) != nil { s.matteBaseKey = sel.cacheKey(media: media) }
            s.matteMustCover = sel.mustCover          // a pick that lost its points too: then the whole frame
        }
        return s
    }

    mutating func remapMaskKeys(_ f: (Time) -> Time) {
        guard let m = maskStore else { return }
        maskStore = m.map { $0.remapped(f) }
    }

    mutating func freezeMasks(atLocal t: Time) {
        guard let m = maskStore else { return }
        maskStore = m.map { $0.frozen(atLocal: t) }
    }

    // MARK: Editing

    public func mask(_ id: ClipMask.ID) -> ClipMask? { masks.first { $0.id == id } }

    public mutating func updateMask(_ id: ClipMask.ID, _ body: (inout ClipMask) -> Void) {
        guard var list = maskStore, let i = list.firstIndex(where: { $0.id == id }) else { return }
        let keep = list[i].id
        body(&list[i])
        list[i].id = keep
        maskStore = list
    }

    /// The masks as Paste Attributes copies them (Opacity group): fresh ids, keys clip-local like the opacity keys.
    public var pastedMasks: [ClipMask] {
        masks.map { var m = $0; m.id = UUID(); return m }
    }

    /// Name for a new mask: "Mask (n)" with the next free number.
    public var nextMaskName: String {
        var n = masks.count + 1
        while masks.contains(where: { $0.name == "Mask (\(n))" }) { n += 1 }
        return "Mask (\(n))"
    }

    /// Writes the path at clip-local `t`: a key there when the path is animated, else the static value.
    public mutating func setMaskPath(_ id: ClipMask.ID, _ path: MaskPath, atLocal t: Time) {
        updateMask(id) { m in
            if m.path.isAnimated {
                if let k = m.path.track.keys.first(where: { $0.time == t }) { m.path.track.set(k.id, value: path) }
                else { m.path.track.insert(Keyframe(time: t, value: path)) }
            } else {
                m.path.value = path
            }
        }
    }

    /// Key button of an animated mask path: removes the key at `t`, or adds one with the shape shown there. Removing
    /// the last key keeps that shape as the static value. Does nothing while the path is not animated.
    public mutating func toggleMaskPathKey(_ id: ClipMask.ID, atLocal t: Time) {
        updateMask(id) { m in
            guard m.path.isAnimated else { return }
            if let k = m.path.track.keys.first(where: { $0.time == t }) {
                let shown = m.path.value(atLocal: t)
                m.path.track.remove(k.id)
                if m.path.track.isEmpty { m.path.value = shown }
            } else {
                m.path.track.insert(Keyframe(time: t, value: m.path.value(atLocal: t)))
            }
        }
    }

    /// Stopwatch of the mask path: on adds a key with the current shape at `t`; off keeps the shape at `t` as the static value.
    public mutating func setMaskPathAnimated(_ id: ClipMask.ID, _ on: Bool, atLocal t: Time) {
        updateMask(id) { m in
            let v = m.path.value(atLocal: t)
            if on {
                guard !m.path.isAnimated else { return }
                m.path.track.insert(Keyframe(time: t, value: v))
            } else {
                m.path = AnimatedProperty(v)
            }
        }
    }
}
