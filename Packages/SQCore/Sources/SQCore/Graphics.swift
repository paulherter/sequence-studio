import Foundation

// GFX: Graphics clip (design layer). One generator clip holding an ordered list of layers (shapes, freeform paths, text),
// each with its own Motion, opacity, blend mode, effects and keys. Concept: the design notes "GFX: Graphics clip".

/// What a graphics layer draws. Stored in the project file: never rename cases or labels.
public enum GraphicsContent: Sendable, Hashable, Codable {
    /// A built-in outline; size, fill and stroke live in the layer's Shape effect.
    case shape(kind: ShapeKind)
    /// A freeform path (pen / free drawing): points in 0...1 of the Shape effect's Width x Height box. Filled only when closed.
    case path(points: [Vec2], closed: Bool)
    /// A text layer: a SQText template payload (`GeneratorRef.text`).
    case text(ref: GeneratorRef)
}

/// A flat group tag: members reorder, move and align together. It draws nothing and has no transform of its own.
public struct GraphicsGroup: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// One layer of a graphics clip. Keys are in the clip's local time (like the clip's own keys).
public struct GraphicsLayer: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var content: GraphicsContent
    /// Motion and Opacity of the layer in the graphic's canvas (position = offset from the canvas center, like a clip).
    public var animation: ClipAnimation
    /// The layer's own effects, in order. Shape and path layers carry their generator-owned Shape effect here.
    public var effects: [ClipEffect]
    public var blendMode: BlendMode
    public var isVisible: Bool
    public var isLocked: Bool
    /// Member of this `GraphicsGroup`, nil = ungrouped.
    public var group: UUID?
    /// G11 Follow: the layer's edges stay at another layer's (or the frame's) edges (Graphics+Follow.swift). nil = none
    /// (the key is then absent from the file). Gates ProjectFile v63.
    public var follow: GraphicsFollow?
    /// Item lanes: the part of the clip the layer shows in, in the clip's local time; the end is exclusive. nil = the whole
    /// clip (the key is then absent from the file). Gates ProjectFile v74 (Graphics+ItemRange.swift).
    public var range: TimeRange?
    /// Organizing color tag of the layer list; nil = none (the key is then absent). Cosmetic: an older build ignores it,
    /// so no ProjectFile version gate.
    public var label: LabelColor?

    public init(id: UUID = UUID(), name: String, content: GraphicsContent, animation: ClipAnimation = ClipAnimation(),
                effects: [ClipEffect] = [], blendMode: BlendMode = .normal, isVisible: Bool = true, isLocked: Bool = false,
                group: UUID? = nil, follow: GraphicsFollow? = nil, range: TimeRange? = nil, label: LabelColor? = nil) {
        self.id = id; self.name = name; self.content = content; self.animation = animation; self.effects = effects
        self.blendMode = blendMode; self.isVisible = isVisible; self.isLocked = isLocked; self.group = group
        self.follow = follow; self.range = range; self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, content, animation, effects, blendMode, isVisible, isLocked, group, follow, range, label
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        content = try c.decode(GraphicsContent.self, forKey: .content)
        animation = try c.decodeIfPresent(ClipAnimation.self, forKey: .animation) ?? ClipAnimation()
        effects = try c.decodeIfPresent([ClipEffect].self, forKey: .effects) ?? []
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        group = try c.decodeIfPresent(UUID.self, forKey: .group)
        follow = try c.decodeIfPresent(GraphicsFollow.self, forKey: .follow)
        range = try c.decodeIfPresent(TimeRange.self, forKey: .range)
        label = try c.decodeIfPresent(LabelColor.self, forKey: .label)
    }

    // MARK: Factories

    /// A shape layer sized for a `canvasWidth` x `canvasHeight` graphic (same defaults as a shape clip).
    public static func shape(_ kind: ShapeKind, canvasWidth: Int, canvasHeight: Int) -> GraphicsLayer {
        GraphicsLayer(name: kind.title, content: .shape(kind: kind),
                      effects: [Project.defaultShapeEffect(kind, canvasWidth: canvasWidth, canvasHeight: canvasHeight)])
    }

    /// A text layer from a SQText payload (`TextGenerator.makeRef`).
    public static func text(_ ref: GeneratorRef, name: String = "Text") -> GraphicsLayer {
        GraphicsLayer(name: name, content: .text(ref: ref))
    }

    /// A freeform layer from points in canvas px (offset from the canvas center, y down), e.g. a free drawing stroke. The
    /// layer is placed at the points' bounding-box center; the box becomes the Shape effect's Width x Height. Open paths are
    /// stroked in `color`; closed ones are filled with it.
    public static func path(canvasPoints: [Vec2], closed: Bool, color: EffectColor, strokeWidth: Double) -> GraphicsLayer {
        let xs = canvasPoints.map(\.x), ys = canvasPoints.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let pts = canvasPoints.map { Vec2(($0.x - minX) / w, ($0.y - minY) / h) }
        var e = ClipEffect.make(kind: ClipEffect.shapeEffectKind)!
        e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(w)
        e.parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(h)
        e.parameters[ClipEffect.shapeFillKey] = AnimatedProperty(closed ? 1 : 0)
        e.colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(color)
        e.parameters[ClipEffect.shapeStrokeKey] = AnimatedProperty(closed ? 0 : 1)
        e.colors[ClipEffect.shapeStrokeColorKey] = AnimatedProperty(color)
        e.parameters[ClipEffect.shapeStrokeWidthKey] = AnimatedProperty(strokeWidth)
        var a = ClipAnimation()
        a.position = AnimatedProperty(Vec2((minX + maxX) / 2, (minY + maxY) / 2))
        return GraphicsLayer(name: closed ? "Shape" : "Drawing", content: .path(points: pts, closed: closed), animation: a,
                             effects: [e])
    }

    // MARK: Shape look

    public var isText: Bool { if case .text = content { true } else { false } }

    /// The Shape effect of a shape or path layer.
    public var shapeEffect: ClipEffect? { effects.first { $0.kind == ClipEffect.shapeEffectKind } }

    /// Sets a static Width x Height on the Shape effect (keys of those two are dropped).
    public mutating func setShapeSize(width: Double, height: Double) {
        guard let i = effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) else { return }
        effects[i].parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(width)
        effects[i].parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(height)
    }

    /// The shape this layer draws at clip-local `t`; nil for text or a switched-off Shape effect.
    public func shapeStyle(atLocal t: Time) -> ShapeStyle? {
        switch content {
        case .shape(let kind):
            return ShapeStyle.evaluate(kind, effect: shapeEffect, atLocal: t)
        case .path(let points, let closed):
            guard var s = ShapeStyle.evaluate(.rectangle, effect: shapeEffect, atLocal: t) else { return nil }
            s.cornerRadius = 0
            s.path = points
            s.pathClosed = closed
            if !closed { s.fill = nil }
            return s
        case .text:
            return nil
        }
    }

    /// The generator a request of this layer carries (what the renderers dispatch on).
    var generatorRef: GeneratorRef {
        switch content {
        case .shape(let kind): GraphicsLayer.shapeRefs[kind] ?? GeneratorRef.shape(kind)
        case .path: GraphicsLayer.shapeRefs[.rectangle] ?? GeneratorRef.shape(.rectangle)
        case .text(let ref): ref
        }
    }

    /// Encoded once: evaluation runs every frame.
    private static let shapeRefs: [ShapeKind: GeneratorRef] =
        Dictionary(uniqueKeysWithValues: ShapeKind.allCases.map { ($0, GeneratorRef.shape($0)) })
}

/// The layers of a graphics clip, bottom first, and its groups.
public struct GraphicsDocument: Sendable, Hashable, Codable {
    public var layers: [GraphicsLayer]
    public var groups: [GraphicsGroup]

    public init(layers: [GraphicsLayer] = [], groups: [GraphicsGroup] = []) { self.layers = layers; self.groups = groups }

    private enum CodingKeys: String, CodingKey { case layers, groups }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        layers = try c.decodeIfPresent([GraphicsLayer].self, forKey: .layers) ?? []
        groups = try c.decodeIfPresent([GraphicsGroup].self, forKey: .groups) ?? []
    }

    public func layer(_ id: UUID) -> GraphicsLayer? { layers.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { layers.firstIndex { $0.id == id } }
    public func group(_ id: UUID) -> GraphicsGroup? { groups.first { $0.id == id } }
}

extension GeneratorRef {
    /// GFX graphics clip: the layers live in `Clip.graphics`; the payload is empty.
    public static let graphics = "graphics"
    public static var graphicsClip: GeneratorRef { GeneratorRef(kind: graphics, payload: Data()) }
}

extension Clip {
    /// The layers of a graphics clip (nil for any other clip). Setting it on a non-graphics clip stores it but draws nothing.
    public var graphics: GraphicsDocument? {
        get { graphicsStore }
        set { graphicsStore = newValue }
    }

    public var isGraphics: Bool { generator?.kind == GeneratorRef.graphics }

    /// Layer `l` as a clip with this clip's timing, so clip evaluation (Motion, effects, Shape) applies to it unchanged.
    func graphicsLayerClip(_ l: GraphicsLayer) -> Clip {
        var c = Clip(id: l.id, name: l.name, media: l.id, kind: .video, source: source, start: start,
                     animation: l.animation, generator: l.generatorRef, effects: l.effects)
        c.blendMode = l.blendMode
        return c
    }
}

extension LayerRequest {
    /// A layer of a graphics clip (its enclosing group is the graphics clip).
    public var isGraphicsLayer: Bool { clipDuration != nil }
}

extension Project {
    /// Places an empty Graphics clip (overwrite, like any generator drop). Throws like `addGeneratorClip`.
    @discardableResult
    public mutating func addGraphicsClip(in timeline: Timeline.ID, at start: Time, track: Track.ID, duration: Time,
                                         layers: [GraphicsLayer] = []) throws -> Clip.ID {
        let id = try addGeneratorClip(kind: GeneratorRef.graphics, payload: Data(), name: "Graphic",
                                      in: timeline, at: start, track: track, duration: duration)
        try edit(timeline) { t in
            guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { throw EditError.clipNotFound }
            c.graphics = GraphicsDocument(layers: layers)
            try t.replaceClip(c)
        }
        return id
    }

    /// The graphics clip `id`, nil when unknown or not a graphics clip.
    public func graphicsClip(_ id: Clip.ID) -> Clip? {
        for t in timelines { for tr in t.tracks { if let c = tr.clips.first(where: { $0.id == id }), c.isGraphics { return c } } }
        return nil
    }

    /// Edits the layers of graphics clip `clipID` in one mutation (one undo step). Throws `.clipNotFound` for an unknown clip
    /// or one that is not a graphics clip, `.trackLocked` on a locked track.
    @discardableResult
    public mutating func editGraphics<R>(clipID: Clip.ID, _ body: (inout GraphicsDocument) throws -> R) throws -> R {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                guard var c = timelines[ti].tracks[tr].clips.first(where: { $0.id == clipID }) else { continue }
                guard c.isGraphics else { throw EditError.clipNotFound }
                if timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
                var doc = c.graphics ?? GraphicsDocument()
                let r = try body(&doc)
                c.graphics = doc
                timelines[ti].tracks[tr].replace(c)
                return r
            }
        }
        throw EditError.clipNotFound
    }

    /// Adds `layer` on top of graphics clip `clipID`. Returns its ID.
    @discardableResult
    public mutating func addGraphicsLayer(_ layer: GraphicsLayer, to clipID: Clip.ID) throws -> UUID {
        try editGraphics(clipID: clipID) { $0.add(layer) }
    }

    /// Any graphics clip in any sequence (gates ProjectFile v42).
    public var containsGraphicsClips: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.isGraphics) } }
    }
}

// MARK: - Keyframing helpers (Graphics panel)

extension AnimatedProperty {
    /// The property shows `v` at clip-local `t`: a key at `t` (added, or the one there replaced keeping its id and easing)
    /// when the property is keyed, else the static value.
    public mutating func set(_ v: V, atLocal t: Time) {
        guard isAnimated else { value = v; return }
        if let k = track.keys.first(where: { $0.time == t }) { track.set(k.id, value: v) }
        else { track.insert(Keyframe(time: t, value: v)) }
    }

    /// Stopwatch: off -> one key at `t` with the current value; on -> every key removed, the value at `t` stays static.
    public mutating func toggleKeyframing(atLocal t: Time) {
        let v = value(atLocal: t)
        if isAnimated { track = KeyframeTrack(); value = v } else { track.insert(Keyframe(time: t, value: v)) }
    }
}
