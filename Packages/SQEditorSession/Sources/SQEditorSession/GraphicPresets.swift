import Foundation
import SQCore
import SQText

/// CREATOR 7: the built-in stickers (arrow, circle, emoji pops, "swipe up", "link in bio") and six lower thirds. Each is a
/// Graphics clip built from shape and text layers only (like `CTAEndCard`), so no media file is needed, every part stays
/// editable in the Graphics panel, and the project file has nothing new to store.
public enum GraphicPresetCategory: String, Sendable, CaseIterable {
    case sticker, lowerThird, callout
    public var title: String {
        switch self { case .sticker: "Stickers"; case .lowerThird: "Lower Thirds"; case .callout: "Callouts" }
    }
    /// Singular name used in an entry's Library title ("Arrow Sticker").
    public var label: String {
        switch self { case .sticker: "Sticker"; case .lowerThird: "Lower Third"; case .callout: "Callout" }
    }
}

public enum GraphicPresetCatalog {
    public struct Entry: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var category: GraphicPresetCategory
        /// Length of the clip a new graphic gets.
        public var duration: Time
        public let build: @Sendable (_ width: Int, _ height: Int) throws -> [GraphicsLayer]

        /// The layers, bottom first, for a `canvasWidth` x `canvasHeight` graphic.
        public func layers(canvasWidth: Int, canvasHeight: Int) throws -> [GraphicsLayer] { try build(canvasWidth, canvasHeight) }
    }

    public static func entry(id: String) -> Entry? { all.first { $0.id == id } }

    /// Entries whose name contains every word of `query` (case-insensitive); an empty query returns all.
    public static func matching(_ query: String) -> [Entry] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { e in tokens.allSatisfy { e.name.lowercased().contains($0) } }
    }

    public static let stickerDuration = Time(3, 1), lowerThirdDuration = Time(5, 1), calloutDuration = Time(4, 1)

    public static let all: [Entry] = stickers + lowerThirds + callouts

    // MARK: Colors

    private static let yellow = EffectColor(red: 1, green: 0.84, blue: 0.04)
    private static let red = EffectColor(red: 1, green: 0.19, blue: 0.19)
    private static let white = EffectColor(red: 1, green: 1, blue: 1)
    private static let ink = EffectColor(red: 0.07, green: 0.07, blue: 0.09)
    private static let blue = EffectColor(red: 0.04, green: 0.52, blue: 1)

    // MARK: Building blocks

    /// Pixel unit: 1 at 1080 px on the short side.
    private static func unit(_ w: Int, _ h: Int) -> Double { Double(min(w, h)) / 1080 }
    private static func sec(_ s: Double) -> Time { Time(Int64((s * 1000).rounded()), 1000) }

    private static func shape(_ kind: ShapeKind, _ name: String, _ w: Int, _ h: Int, width: Double, height: Double,
                              fill: EffectColor?, stroke: EffectColor? = nil, strokeWidth: Double = 0, radius: Double = 0) -> GraphicsLayer {
        var l = GraphicsLayer.shape(kind, canvasWidth: w, canvasHeight: h)
        l.name = name
        l.setShapeSize(width: width, height: height)
        let i = 0
        l.effects[i].parameters[ClipEffect.shapeCornerRadiusKey] = AnimatedProperty(radius)
        l.effects[i].parameters[ClipEffect.shapeFillKey] = AnimatedProperty(fill == nil ? 0 : 1)
        if let fill { l.effects[i].colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(fill) }
        l.effects[i].parameters[ClipEffect.shapeStrokeKey] = AnimatedProperty(stroke == nil ? 0 : 1)
        if let stroke {
            l.effects[i].colors[ClipEffect.shapeStrokeColorKey] = AnimatedProperty(stroke)
            l.effects[i].parameters[ClipEffect.shapeStrokeWidthKey] = AnimatedProperty(strokeWidth)
        }
        return l
    }

    private static func text(_ name: String, _ string: String, style: TextStyle) throws -> GraphicsLayer {
        GraphicsLayer.text(try TextGenerator.makeRef(template: TextTemplate(name: name, text: string, style: style), animations: nil), name: name)
    }

    private static func style(size: Double, weight: FontWeight, color: RGBAColor = .white, alignment: TextAlignment = .center,
                              shadow: Bool = false, tracking: Double = 0, caps: Bool = false) -> TextStyle {
        TextStyle(fontName: TextStyle.defaultFontName, size: size, weight: weight, color: color,
                  shadow: shadow ? TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55), angle: 135, distance: 3, blur: 8) : nil,
                  alignment: alignment, tracking: tracking, allCaps: caps)
    }

    /// Estimated width of one line (the renderer lays out the real one); only used to place left-aligned text.
    private static func width(_ s: String, size: Double, factor: Double = 0.58) -> Double { Double(s.count) * size * factor }

    private static func keys<V>(_ pairs: [(Double, V)], default v: V) -> AnimatedProperty<V> {
        var p = AnimatedProperty(v)
        for (t, x) in pairs { p.track.insert(Keyframe(time: sec(t), value: x)) }
        return p
    }

    /// Pop in (overshoot), optional bob and wobble while it stays, pop out at the end.
    private static func pop(at p: Vec2, duration d: Time, bob: Double = 0, wobble: Double = 0) -> ClipAnimation {
        let end = Double(d.value) / Double(d.timescale)
        var a = ClipAnimation()
        a.position = AnimatedProperty(p)
        a.scale = keys([(0, Vec2(0, 0)), (0.18, Vec2(1.15, 1.15)), (0.32, Vec2(1, 1)), (end - 0.25, Vec2(1, 1)), (end, Vec2(0, 0))], default: Vec2(1, 1))
        if bob != 0 {
            var pairs: [(Double, Vec2)] = [(0, p)]
            var t = 0.32, up = true
            while t < end - 0.25 { pairs.append((t, Vec2(p.x, p.y + (up ? -bob : 0)))); up.toggle(); t += 0.5 }
            pairs.append((end - 0.25, p))
            a.position = keys(pairs, default: p)
        }
        if wobble != 0 {
            var pairs: [(Double, Double)] = [(0, 0)]
            var t = 0.32, sign = 1.0
            while t < end - 0.25 { pairs.append((t, wobble * sign)); sign = -sign; t += 0.45 }
            pairs.append((end - 0.25, 0))
            a.rotation = keys(pairs, default: 0)
        }
        return a
    }

    /// Slide in from the left with a fade, hold, fade out.
    private static func slide(to p: Vec2, from dx: Double, delay: Double = 0, duration d: Time) -> ClipAnimation {
        let end = Double(d.value) / Double(d.timescale)
        var a = ClipAnimation()
        a.position = keys([(0, Vec2(p.x + dx, p.y)), (delay, Vec2(p.x + dx, p.y)), (delay + 0.4, p), (end, p)], default: p)
        a.opacity = keys([(0, 0.0), (delay, 0.0), (delay + 0.3, 1.0), (end - 0.35, 1.0), (end, 0.0)], default: 1)
        return a
    }

    // MARK: Stickers

    private static func sticker(_ id: String, _ name: String, _ build: @escaping @Sendable (Int, Int) throws -> [GraphicsLayer]) -> Entry {
        Entry(id: id, name: name, category: .sticker, duration: stickerDuration, build: build)
    }

    private static func emoji(_ id: String, _ name: String, _ glyph: String) -> Entry {
        sticker(id, name) { w, h in
            let u = unit(w, h)
            var l = try text(name, glyph, style: style(size: 260 * u, weight: .regular))
            l.animation = pop(at: Vec2(0, 0), duration: stickerDuration, wobble: 9)
            return [l]
        }
    }

    static let stickers: [Entry] = [
        sticker("sticker-arrow", "Arrow") { w, h in
            let u = unit(w, h)
            var l = shape(.arrow, "Arrow", w, h, width: 300 * u, height: 190 * u, fill: yellow, stroke: ink, strokeWidth: 8 * u)
            l.animation = pop(at: Vec2(0, 0), duration: stickerDuration, bob: 28 * u)
            return [l]
        },
        sticker("sticker-circle", "Circle") { w, h in
            let u = unit(w, h)
            var l = shape(.ellipse, "Circle", w, h, width: 380 * u, height: 380 * u, fill: nil, stroke: red, strokeWidth: 16 * u)
            l.animation = pop(at: Vec2(0, 0), duration: stickerDuration)
            var s = l.animation.scale
            s.track.insert(Keyframe(time: sec(1.1), value: Vec2(1.06, 1.06)))     // slow pulse while it stays
            s.track.insert(Keyframe(time: sec(1.9), value: Vec2(1, 1)))
            l.animation.scale = s
            return [l]
        },
        emoji("sticker-pop-fire", "Pop Fire", "\u{1F525}"),
        emoji("sticker-pop-heart", "Pop Heart", "\u{2764}\u{FE0F}"),
        emoji("sticker-pop-laugh", "Pop Laugh", "\u{1F602}"),
        sticker("sticker-swipe-up", "Swipe Up") { w, h in
            let u = unit(w, h)
            let pillW = 520 * u, pillH = 120 * u
            let centre = Vec2(0, Double(h) * 0.30)
            var pill = shape(.rectangle, "Pill", w, h, width: pillW, height: pillH, fill: white, radius: pillH / 2)
            pill.animation = pop(at: centre, duration: stickerDuration)
            var label = try text("Label", "SWIPE UP", style: style(size: 52 * u, weight: .heavy, color: RGBAColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1), tracking: 3))
            label.animation = pop(at: Vec2(centre.x + 36 * u, centre.y), duration: stickerDuration)
            var arrow = try text("Arrow", "\u{2191}", style: style(size: 70 * u, weight: .heavy, color: RGBAColor(red: 1, green: 0.19, blue: 0.19, alpha: 1)))
            arrow.animation = pop(at: Vec2(centre.x - pillW / 2 + 70 * u, centre.y), duration: stickerDuration, bob: 16 * u)
            return [pill, label, arrow]
        },
        sticker("sticker-link-in-bio", "Link in Bio") { w, h in
            let u = unit(w, h)
            let pillW = 560 * u, pillH = 120 * u
            let centre = Vec2(0, Double(h) * 0.30)
            var pill = shape(.rectangle, "Pill", w, h, width: pillW, height: pillH, fill: blue, radius: pillH / 2)
            pill.animation = pop(at: centre, duration: stickerDuration)
            var icon = try text("Icon", "\u{1F517}", style: style(size: 64 * u, weight: .regular))
            icon.animation = pop(at: Vec2(centre.x - pillW / 2 + 72 * u, centre.y), duration: stickerDuration, wobble: 10)
            var label = try text("Label", "LINK IN BIO", style: style(size: 50 * u, weight: .heavy, tracking: 3))
            label.animation = pop(at: Vec2(centre.x + 34 * u, centre.y), duration: stickerDuration)
            return [pill, icon, label]
        },
    ]

    // MARK: Lower thirds

    private static func lowerThird(_ id: String, _ name: String, _ build: @escaping @Sendable (Int, Int) throws -> [GraphicsLayer]) -> Entry {
        Entry(id: id, name: name, category: .lowerThird, duration: lowerThirdDuration, build: build)
    }

    /// Geometry shared by the lower thirds: left edge, name row and role row (canvas px from the center, y down).
    private struct Frame {
        var left: Double, nameY: Double, roleY: Double, u: Double
        init(_ w: Int, _ h: Int) {
            u = unit(w, h)
            left = -Double(w) * 0.5 + max(Double(w) * 0.07, 60 * u)
            nameY = Double(h) * 0.5 - max(Double(h) * 0.2, 250 * u)
            roleY = nameY + 62 * u
        }
    }

    private static let nameText = "Your Name", roleText = "Role or Place"

    /// Name and role text layers, left-aligned at `x` (centers estimated from the text length).
    private static func nameAndRole(_ f: Frame, x: Double, nameSize: Double, roleSize: Double, nameColor: RGBAColor = .white,
                                    roleColor: RGBAColor = .white, shadow: Bool = true, nameCaps: Bool = false,
                                    delay: Double = 0) throws -> [GraphicsLayer] {
        let d = lowerThirdDuration
        var n = try text("Name", nameText, style: style(size: nameSize, weight: .heavy, color: nameColor, shadow: shadow, caps: nameCaps))
        n.animation = slide(to: Vec2(x + width(nameText, size: nameSize) / 2, f.nameY), from: -90 * f.u, delay: delay + 0.08, duration: d)
        var r = try text("Role", roleText, style: style(size: roleSize, weight: .medium, color: roleColor, shadow: shadow))
        r.animation = slide(to: Vec2(x + width(roleText, size: roleSize, factor: 0.52) / 2, f.roleY), from: -90 * f.u, delay: delay + 0.16, duration: d)
        return [n, r]
    }

    static let lowerThirds: [Entry] = [
        lowerThird("lower-third-bar", "Bar") { w, h in
            let f = Frame(w, h)
            var bar = shape(.rectangle, "Accent", w, h, width: 10 * f.u, height: 112 * f.u, fill: yellow, radius: 5 * f.u)
            bar.animation = slide(to: Vec2(f.left, (f.nameY + f.roleY) / 2), from: -40 * f.u, duration: lowerThirdDuration)
            return [bar] + (try nameAndRole(f, x: f.left + 28 * f.u, nameSize: 58 * f.u, roleSize: 34 * f.u))
        },
        lowerThird("lower-third-box", "Box") { w, h in
            let f = Frame(w, h)
            let bw = max(width(nameText, size: 58 * f.u), width(roleText, size: 34 * f.u, factor: 0.52)) + 80 * f.u
            let bh = 140 * f.u
            var box = shape(.rectangle, "Box", w, h, width: bw, height: bh, fill: EffectColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.88), radius: 10 * f.u)
            box.animation = slide(to: Vec2(f.left + bw / 2, (f.nameY + f.roleY) / 2), from: -90 * f.u, duration: lowerThirdDuration)
            var line = shape(.rectangle, "Accent", w, h, width: bw, height: 6 * f.u, fill: blue)
            line.animation = slide(to: Vec2(f.left + bw / 2, (f.nameY + f.roleY) / 2 + bh / 2 - 3 * f.u), from: -90 * f.u, delay: 0.1, duration: lowerThirdDuration)
            return [box, line] + (try nameAndRole(f, x: f.left + 40 * f.u, nameSize: 58 * f.u, roleSize: 34 * f.u, shadow: false, delay: 0.1))
        },
        lowerThird("lower-third-underline", "Underline") { w, h in
            let f = Frame(w, h)
            let lw = max(width(nameText, size: 62 * f.u), width(roleText, size: 34 * f.u, factor: 0.52)) + 20 * f.u
            var line = shape(.rectangle, "Accent", w, h, width: lw, height: 6 * f.u, fill: red, radius: 3 * f.u)
            let y = f.nameY + 38 * f.u
            line.animation = slide(to: Vec2(f.left + lw / 2, y), from: -60 * f.u, duration: lowerThirdDuration)
            var s = AnimatedProperty(Vec2(1, 1))
            s.track.insert(Keyframe(time: .zero, value: Vec2(0, 1)))
            s.track.insert(Keyframe(time: sec(0.5), value: Vec2(1, 1)))
            line.animation.scale = s
            var f2 = f; f2.roleY = y + 44 * f.u
            return [line] + (try nameAndRole(f2, x: f.left + 6 * f.u, nameSize: 62 * f.u, roleSize: 34 * f.u))
        },
        lowerThird("lower-third-pill", "Pill") { w, h in
            let f = Frame(w, h)
            let pw = width(nameText, size: 52 * f.u) + 90 * f.u, ph = 92 * f.u
            var pill = shape(.rectangle, "Pill", w, h, width: pw, height: ph, fill: white, radius: ph / 2)
            pill.animation = slide(to: Vec2(f.left + pw / 2, f.nameY), from: -90 * f.u, duration: lowerThirdDuration)
            var n = try text("Name", nameText, style: style(size: 52 * f.u, weight: .heavy, color: RGBAColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
            n.animation = slide(to: Vec2(f.left + pw / 2, f.nameY), from: -90 * f.u, delay: 0.08, duration: lowerThirdDuration)
            var r = try text("Role", roleText, style: style(size: 34 * f.u, weight: .semibold, shadow: true))
            r.animation = slide(to: Vec2(f.left + 20 * f.u + width(roleText, size: 34 * f.u, factor: 0.52) / 2, f.nameY + 76 * f.u), from: -90 * f.u, delay: 0.16, duration: lowerThirdDuration)
            return [pill, n, r]
        },
        lowerThird("lower-third-slab", "Slab") { w, h in
            let f = Frame(w, h)
            let nw = width(nameText, size: 56 * f.u) + 70 * f.u, rw = width(roleText, size: 32 * f.u, factor: 0.52) + 70 * f.u
            var top = shape(.rectangle, "Name Slab", w, h, width: nw, height: 84 * f.u, fill: blue)
            top.animation = slide(to: Vec2(f.left + nw / 2, f.nameY), from: -90 * f.u, duration: lowerThirdDuration)
            var bottom = shape(.rectangle, "Role Slab", w, h, width: rw, height: 54 * f.u, fill: EffectColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.9))
            bottom.animation = slide(to: Vec2(f.left + rw / 2, f.nameY + 69 * f.u), from: -90 * f.u, delay: 0.1, duration: lowerThirdDuration)
            var f2 = f; f2.roleY = f.nameY + 69 * f.u
            return [top, bottom] + (try nameAndRole(f2, x: f.left + 35 * f.u, nameSize: 56 * f.u, roleSize: 32 * f.u, shadow: false, delay: 0.1))
        },
        lowerThird("lower-third-minimal", "Minimal") { w, h in
            let f = Frame(w, h)
            let d = lowerThirdDuration, end = Double(d.value) / Double(d.timescale)
            var layers = try nameAndRole(f, x: f.left, nameSize: 54 * f.u, roleSize: 32 * f.u, nameCaps: true)
            // Rise and fade instead of a slide.
            for i in layers.indices {
                let p = layers[i].animation.position.value(atLocal: sec(1))
                var a = ClipAnimation()
                a.position = keys([(0, Vec2(p.x, p.y + 24 * f.u)), (0.45, p), (end, p)], default: p)
                a.opacity = keys([(0, 0.0), (0.4, 1.0), (end - 0.35, 1.0), (end, 0.0)], default: 1)
                layers[i].animation = a
            }
            return layers
        },
    ]

    // MARK: Callouts (tutorial overlays: point at, box in, ring, mark, number)

    private static func callout(_ id: String, _ name: String, _ build: @escaping @Sendable (Int, Int) throws -> [GraphicsLayer]) -> Entry {
        Entry(id: id, name: name, category: .callout, duration: calloutDuration, build: build)
    }

    /// In: grows (or wipes) from `from` while fading up and moving in by `offset`; out: the same backwards; `pulse` makes
    /// it breathe while it stays. Starts at opacity 0, so the first frame is never a hard cut.
    private static func reveal(at p: Vec2, duration d: Time, from: Vec2 = Vec2(0.6, 0.6), offset: Vec2 = Vec2(0, 0),
                               pulse: Double = 0, delay: Double = 0) -> ClipAnimation {
        let end = Double(d.value) / Double(d.timescale)
        let inEnd = delay + 0.3, outStart = end - 0.3
        var a = ClipAnimation()
        a.opacity = keys([(0, 0.0), (delay, 0.0), (delay + 0.22, 1.0), (outStart, 1.0), (end, 0.0)], default: 1)
        var scale: [(Double, Vec2)] = [(0, from), (delay, from), (inEnd, Vec2(1, 1))]
        if pulse != 0 {
            var t = inEnd + 0.5, up = true
            while t < outStart - 0.2 { scale.append((t, up ? Vec2(1 + pulse, 1 + pulse) : Vec2(1, 1))); up.toggle(); t += 0.5 }
        }
        scale += [(outStart, Vec2(1, 1)), (end, from)]
        a.scale = keys(scale, default: Vec2(1, 1))
        let away = Vec2(p.x + offset.x, p.y + offset.y)
        a.position = keys([(0, away), (delay, away), (inEnd, p), (outStart, p), (end, away)], default: p)
        return a
    }

    static let callouts: [Entry] = [
        callout("callout-pointer", "Pointer") { w, h in
            let u = unit(w, h)
            var l = shape(.arrow, "Pointer", w, h, width: 260 * u, height: 150 * u, fill: yellow, stroke: ink, strokeWidth: 8 * u)
            let p = Vec2(0, 0)
            var a = reveal(at: p, duration: calloutDuration, from: Vec2(0.8, 0.8), offset: Vec2(-160 * u, 0))
            // Nudges toward the target while it stays.
            let end = Double(calloutDuration.value) / Double(calloutDuration.timescale)
            var pairs: [(Double, Vec2)] = [(0, Vec2(p.x - 160 * u, p.y)), (0.3, p)]
            var t = 0.8, fwd = true
            while t < end - 0.4 { pairs.append((t, Vec2(p.x + (fwd ? 30 * u : 0), p.y))); fwd.toggle(); t += 0.45 }
            pairs += [(end - 0.3, p), (end, Vec2(p.x - 160 * u, p.y))]
            a.position = keys(pairs, default: p)
            l.animation = a
            return [l]
        },
        callout("callout-focus-ring", "Focus Ring") { w, h in
            let u = unit(w, h)
            var l = shape(.ellipse, "Ring", w, h, width: 420 * u, height: 420 * u, fill: nil, stroke: red, strokeWidth: 14 * u)
            l.animation = reveal(at: Vec2(0, 0), duration: calloutDuration, from: Vec2(1.7, 1.7), pulse: 0.07)
            return [l]
        },
        callout("callout-highlight-box", "Highlight Box") { w, h in
            let u = unit(w, h)
            var l = shape(.rectangle, "Box", w, h, width: 640 * u, height: 220 * u, fill: EffectColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.28),
                          stroke: yellow, strokeWidth: 8 * u, radius: 18 * u)
            l.animation = reveal(at: Vec2(0, 0), duration: calloutDuration, from: Vec2(0, 1))      // wipes open from the middle
            return [l]
        },
        callout("callout-marker-line", "Marker Line") { w, h in
            let u = unit(w, h)
            let p = Vec2(0, 0)
            var bar = shape(.rectangle, "Marker", w, h, width: 620 * u, height: 70 * u, fill: EffectColor(red: 1, green: 0.84, blue: 0.04, alpha: 0.85), radius: 12 * u)
            bar.animation = reveal(at: p, duration: calloutDuration, from: Vec2(0, 1))
            var label = try text("Label", "KEY POINT", style: style(size: 44 * u, weight: .heavy, color: RGBAColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1), tracking: 2))
            label.animation = reveal(at: p, duration: calloutDuration, from: Vec2(0.9, 0.9), delay: 0.15)
            return [bar, label]
        },
        callout("callout-label", "Label Tag") { w, h in
            let u = unit(w, h)
            let p = Vec2(0, -Double(h) * 0.12)
            var tag = shape(.rectangle, "Tag", w, h, width: 560 * u, height: 110 * u, fill: white, radius: 16 * u)
            tag.animation = reveal(at: p, duration: calloutDuration, offset: Vec2(0, 40 * u))
            var label = try text("Label", "Look here", style: style(size: 54 * u, weight: .heavy, color: RGBAColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
            label.animation = reveal(at: p, duration: calloutDuration, offset: Vec2(0, 40 * u), delay: 0.1)
            let tip = Vec2(0, p.y + 80 * u)
            var pointer = shape(.arrow, "Tip", w, h, width: 70 * u, height: 50 * u, fill: white)
            pointer.animation = reveal(at: tip, duration: calloutDuration, offset: Vec2(0, 40 * u), delay: 0.05)
            pointer.animation.rotation = AnimatedProperty(90)
            return [tag, pointer, label]
        },
        callout("callout-step-badge", "Step Badge") { w, h in
            let u = unit(w, h)
            let p = Vec2(0, 0)
            var disc = shape(.ellipse, "Badge", w, h, width: 190 * u, height: 190 * u, fill: blue, stroke: white, strokeWidth: 10 * u)
            disc.animation = pop(at: p, duration: calloutDuration)
            var n = try text("Number", "1", style: style(size: 120 * u, weight: .black, shadow: false))
            n.animation = pop(at: p, duration: calloutDuration)
            return [disc, n]
        },
    ]
}
