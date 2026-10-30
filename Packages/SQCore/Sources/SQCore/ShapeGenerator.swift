import Foundation

/// Which outline a shape clip draws. Stored by raw value in the generator payload: never rename.
public enum ShapeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case rectangle, ellipse, line, arrow

    public var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }
}

/// Payload of a `GeneratorRef.shape` clip (payloadVersion 1). Only the outline lives here; every look value (size,
/// fill, stroke, corner radius) is a keyframable parameter of the clip's Shape effect (`ClipEffect.shapeEffectKind`).
struct ShapePayload: Codable, Hashable {
    var shape: ShapeKind
}

extension GeneratorRef {
    /// A vector shape layer (W5.2). `payload` = JSON `ShapePayload`.
    public static let shape = "shape"

    public static func shape(_ kind: ShapeKind) -> GeneratorRef {
        GeneratorRef(kind: shape, payload: (try? JSONEncoder().encode(ShapePayload(shape: kind))) ?? Data(), payloadVersion: 1)
    }

    /// The outline of a shape generator, nil for other generators. An unreadable payload falls back to a rectangle.
    public var shapeKind: ShapeKind? {
        guard kind == Self.shape else { return nil }
        return (try? JSONDecoder().decode(ShapePayload.self, from: payload))?.shape ?? .rectangle
    }
}

extension ClipEffect {
    // W5.2 Shape: kind and parameter keys (stored strings: never rename).
    public static let shapeEffectKind = "shape"
    public static let shapeWidthKey = "shapeWidth", shapeHeightKey = "shapeHeight", shapeCornerRadiusKey = "shapeCornerRadius"
    public static let shapeFillKey = "shapeFill", shapeFillColorKey = "shapeFillColor"
    public static let shapeStrokeKey = "shapeStroke", shapeStrokeColorKey = "shapeStrokeColor", shapeStrokeWidthKey = "shapeStrokeWidth"
    /// Gradient fill: the fill color is the start, `shapeGradientColor` the end, `shapeGradientAngle` the direction in
    /// degrees (0 = left to right, 90 = top to bottom). Optional keys: files without them draw the solid fill.
    public static let shapeGradientKey = "shapeGradient", shapeGradientColorKey = "shapeGradientColor"
    public static let shapeGradientAngleKey = "shapeGradientAngle"
}

extension EffectCatalog {
    /// Effects that belong to a generator clip and are created with it, never offered in the Effects panel. `spec(for:)`
    /// knows them, so Effect Controls shows their keyframable rows.
    public static let generatorSpecs: [EffectSpec] = [
        // Size in sequence px of the clip's own frame; a line is Width long and Outline Width thick (its fill is unused).
        // Titles say Outline (VOCABULARY.md), the stored keys stay "shapeStroke…". The outline is centered on the outline. Corner Radius only rounds rectangles (clamped to half the shorter side).
        EffectSpec(kind: ClipEffect.shapeEffectKind, title: "Shape", params: [
            EffectParamSpec(key: ClipEffect.shapeWidthKey, title: "Width", unit: "px", defaultValue: 400,
                            range: 0...16_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shapeHeightKey, title: "Height", unit: "px", defaultValue: 300,
                            range: 0...16_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shapeCornerRadiusKey, title: "Corner Radius", unit: "px", defaultValue: 0,
                            range: 0...8_000, step: 1, decimals: 0),
            .checkbox(ClipEffect.shapeFillKey, "Fill", on: true),
            .color(ClipEffect.shapeFillColorKey, "Fill Color", .white),
            .checkbox(ClipEffect.shapeGradientKey, "Gradient"),
            .color(ClipEffect.shapeGradientColorKey, "Gradient End Color", .black),
            EffectParamSpec(key: ClipEffect.shapeGradientAngleKey, title: "Gradient Angle", unit: "°", defaultValue: 90,
                            range: 0...360, step: 1, decimals: 0),
            .checkbox(ClipEffect.shapeStrokeKey, "Outline"),
            .color(ClipEffect.shapeStrokeColorKey, "Outline Color", .black),
            EffectParamSpec(key: ClipEffect.shapeStrokeWidthKey, title: "Outline Width", unit: "px", defaultValue: 8,
                            range: 0...2_000, step: 0.5, decimals: 1),
        ]),
    ]

    /// True for an effect created with its generator clip (one per clip): never added, duplicated, removed or pasted onto
    /// another clip by the generic effect commands. Reset to defaults is fine.
    public static func isGeneratorOwned(_ kind: String) -> Bool { owningGenerator(of: kind) != nil }

    /// The `GeneratorRef.kind` a generator-owned effect belongs to; nil for an ordinary effect.
    public static func owningGenerator(of kind: String) -> String? {
        kind == ClipEffect.shapeEffectKind ? GeneratorRef.shape : nil
    }
}

/// A shape at one instant, clamped, in sequence px of the clip's own frame. What `ShapeRenderer` (SQRender) draws.
public struct ShapeStyle: Sendable, Hashable {
    public var kind: ShapeKind
    /// Outline size. A line uses `width` as its length; `height` is ignored.
    public var width: Double, height: Double
    /// Rectangles only, at most half the shorter side.
    public var cornerRadius: Double
    /// Display-encoded (BT.709 OETF) 0...1 RGBA; nil = no fill. Never set for a line.
    public var fill: EffectColor?
    /// nil = no stroke. A line without a stroke draws nothing.
    public var stroke: EffectColor?
    public var strokeWidth: Double
    /// GFX freeform path: points in 0...1 of the `width` x `height` outline box (x right, y down), drawn instead of `kind`'s
    /// outline. Filled only when closed (the caller then sets `fill`). nil for the built-in outlines.
    public var path: [Vec2]?
    public var pathClosed: Bool
    /// Gradient fill: `fill` is the start color, this the end; nil = solid fill (every older project). Needs a `fill`.
    public var gradientEnd: EffectColor?
    /// Direction of the gradient in degrees, 0 = left to right, 90 = top to bottom.
    public var gradientAngle: Double

    public init(kind: ShapeKind, width: Double, height: Double, cornerRadius: Double = 0, fill: EffectColor? = nil,
                stroke: EffectColor? = nil, strokeWidth: Double = 0, path: [Vec2]? = nil, pathClosed: Bool = false,
                gradientEnd: EffectColor? = nil, gradientAngle: Double = 90) {
        self.gradientEnd = gradientEnd; self.gradientAngle = gradientAngle
        self.kind = kind; self.width = width; self.height = height; self.cornerRadius = cornerRadius
        self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth
        self.path = path; self.pathClosed = pathClosed
    }

    /// The style of `kind` drawn by Shape effect `e` (catalog defaults when nil) at effect-local `t`; nil when it is off.
    public static func evaluate(_ kind: ShapeKind, effect: ClipEffect?, atLocal t: Time) -> ShapeStyle? {
        let e = effect ?? ClipEffect(kind: ClipEffect.shapeEffectKind)
        guard e.enabled else { return nil }
        let w = e.scalar(ClipEffect.shapeWidthKey, atLocal: t), h = e.scalar(ClipEffect.shapeHeightKey, atLocal: t)
        let stroke = e.flag(ClipEffect.shapeStrokeKey, atLocal: t) ? e.color(ClipEffect.shapeStrokeColorKey, atLocal: t) : nil
        let fill = kind != .line && e.flag(ClipEffect.shapeFillKey, atLocal: t) ? e.color(ClipEffect.shapeFillColorKey, atLocal: t) : nil
        let radius = kind == .rectangle ? min(e.scalar(ClipEffect.shapeCornerRadiusKey, atLocal: t), min(w, h) / 2) : 0
        let gradient = fill != nil && e.flag(ClipEffect.shapeGradientKey, atLocal: t)
        return ShapeStyle(kind: kind, width: w, height: h, cornerRadius: max(radius, 0), fill: fill, stroke: stroke,
                          strokeWidth: e.scalar(ClipEffect.shapeStrokeWidthKey, atLocal: t),
                          gradientEnd: gradient ? e.color(ClipEffect.shapeGradientColorKey, atLocal: t) : nil,
                          gradientAngle: gradient ? e.scalar(ClipEffect.shapeGradientAngleKey, atLocal: t) : 90)
    }

    /// Size of the drawn picture: the outline plus the half of the stroke that lies outside it. A line is `width` x
    /// `strokeWidth`. The layer is centered on the clip position, so the outline's center is the clip's center.
    public var rasterSize: (width: Double, height: Double) {
        if kind == .line { return (width, stroke == nil ? 0 : strokeWidth) }
        let out = stroke == nil ? 0 : strokeWidth
        return (width + out, height + out)
    }

    /// The arrow outline (N3) as 7 points in box coordinates (x right, y down, origin top-left of the `width` x `height`
    /// outline box). It points right: a shaft 40 % of the height thick, a head as high as the box and 90 % of the
    /// height long (at most 60 % of the width). Rotate the clip to aim it; Bounce/Pulse/Wiggle loop effects animate it.
    public var arrowPoints: [Vec2] {
        let head = min(height * 0.9, width * 0.6), shaft = height * 0.4
        let y0 = (height - shaft) / 2, y1 = y0 + shaft, neck = width - head
        return [Vec2(0, y0), Vec2(neck, y0), Vec2(neck, 0), Vec2(width, height / 2), Vec2(neck, height), Vec2(neck, y1),
                Vec2(0, y1)]
    }

    /// Nothing visible: no fill and no stroke, or no area.
    public var isEmpty: Bool {
        let r = rasterSize
        return r.width <= 0 || r.height <= 0 || (fill == nil && stroke == nil)
    }
}

extension Clip {
    /// The shape this clip draws at clip-local `t`; nil when it is not a shape generator or its Shape effect is switched
    /// off (fx toggle). A shape clip whose Shape effect was removed draws the catalog defaults.
    public func shapeStyle(atLocal t: Time) -> ShapeStyle? {
        guard let kind = generator?.shapeKind else { return nil }
        return ShapeStyle.evaluate(kind, effect: effect(ofKind: ClipEffect.shapeEffectKind), atLocal: t)
    }
}

extension Project {
    /// The Shape effect a new `kind` starts with on a `width` x `height` canvas: a rectangle covering half of each side,
    /// a circle half the shorter side across, a line half the width long with its stroke on.
    public static func defaultShapeEffect(_ kind: ShapeKind, canvasWidth width: Int, canvasHeight height: Int) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.shapeEffectKind)!
        let w = Double(width) / 2, h = Double(height) / 2
        switch kind {
        case .rectangle:
            e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(w)
            e.parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(h)
        case .ellipse:
            e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(min(w, h))
            e.parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(min(w, h))
        case .arrow:
            e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(w / 2)
            e.parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(h / 3)
            e.colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(EffectColor(red: 1, green: 0.8, blue: 0))
        case .line:
            e.parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(w)
            e.parameters[ClipEffect.shapeStrokeKey] = AnimatedProperty(1)
            e.colors[ClipEffect.shapeStrokeColorKey] = AnimatedProperty(.white)
        }
        return e
    }

    /// Places a shape clip (rectangle, ellipse or line) like `addGeneratorClip`, sized to the sequence. One mutation, so
    /// one undo step. Throws what `addGeneratorClip` throws. Returns the new clip's ID.
    @discardableResult
    public mutating func addShapeClip(_ kind: ShapeKind, in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                      duration: Time) throws -> Clip.ID {
        guard let tl = self.timeline(timeline) else { throw EditError.timelineNotFound }
        let ref = GeneratorRef.shape(kind)
        let id = try addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: ref.payloadVersion, name: kind.title,
                                      in: timeline, at: start, track: track, duration: duration)
        let effect = Self.defaultShapeEffect(kind, canvasWidth: tl.format.displayWidth, canvasHeight: tl.format.height)
        try edit(timeline) { t in
            guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { throw EditError.clipNotFound }
            c.effects = [effect]
            try t.replaceClip(c)
        }
        return id
    }

    /// Switches a shape clip's outline; size, colors and keys stay. Throws `.clipNotFound` for an unknown clip or one
    /// that is not a shape, `.trackLocked` on a locked track.
    public mutating func setShapeKind(clipID: Clip.ID, to kind: ShapeKind) throws {
        guard timelines.contains(where: { $0.tracks.contains { $0.clips.contains { $0.id == clipID && $0.generator?.shapeKind != nil } } })
        else { throw EditError.clipNotFound }
        let ref = GeneratorRef.shape(kind)
        try updateGenerator(clipID: clipID, payload: ref.payload, payloadVersion: ref.payloadVersion)
    }
}
