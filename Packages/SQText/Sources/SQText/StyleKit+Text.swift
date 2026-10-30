import Foundation
import SQCore

// W8.3: the text side of the project style kit (SQCore StyleKit.swift). Captions resolve the kit through the caption library
// (`CaptionPresetLibrary.applying`, live per frame via `CaptionLookRegistry`); text clips carry `TextStyle.tokens` and are
// re-resolved into their payloads when the kit changes (`Project.resolveTextTokens`).

/// Names of the kit tokens a text style's fields follow; nil = that field is a literal.
public struct TextStyleTokens: Sendable, Hashable, Codable {
    public var font: String?
    public var color: String?
    public var strokeColor: String?
    public var backgroundColor: String?

    public init(font: String? = nil, color: String? = nil, strokeColor: String? = nil, backgroundColor: String? = nil) {
        self.font = font; self.color = color; self.strokeColor = strokeColor; self.backgroundColor = backgroundColor
    }

    public var isEmpty: Bool { font == nil && color == nil && strokeColor == nil && backgroundColor == nil }
}

extension RGBAColor {
    public init(_ c: EffectColor) { self.init(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }
}

extension TextStyle {
    /// A manual choice for a field ends its token binding (a later kit change must not overwrite it).
    public mutating func unbind(_ field: WritableKeyPath<TextStyleTokens, String?>) {
        guard var t = tokens, t[keyPath: field] != nil else { return }
        t[keyPath: field] = nil
        tokens = t.isEmpty ? nil : t
    }

    /// The style with every token-bound field set from `kit`. A token the kit does not define keeps the stored literal;
    /// stroke/background colors only change when the style has a stroke/background.
    public func resolved(in kit: StyleKit?) -> TextStyle {
        guard let kit, let t = tokens else { return self }
        var s = self
        if let n = t.font, let f = kit.font(n) { s.fontName = f }
        if let n = t.color, let c = kit.color(n) { s.color = RGBAColor(c) }
        if let n = t.strokeColor, let c = kit.color(n), let st = s.stroke { s.stroke = TextStroke(color: RGBAColor(c), width: st.width, position: st.position) }
        if let n = t.backgroundColor, let c = kit.color(n), var b = s.background { b.color = RGBAColor(c); s.background = b }
        return s
    }
}

extension StyleKit {
    public static let brandFontToken = "brand", textColorToken = "text", pillColorToken = "pill"

    /// The kit a project without one exports (and a starting point to edit): the short-video pill caption with its font,
    /// text color and pill color as tokens, motion effects at their built-in 0.5 s / Premiere Default.
    public static var starter: StyleKit { starter(legacyFont: false) }

    /// `legacyFont`: the starter kit of a project that predates the Inter built-ins (Helvetica as its brand font).
    public static func starter(legacyFont: Bool) -> StyleKit {
        StyleKit(fonts: [brandFontToken: legacyFont ? CaptionPresetLibrary.legacyFontName : TextStyle.defaultFontName],
                 colors: [textColorToken: .white,
                          pillColorToken: EffectColor(red: 0, green: 0, blue: 0, alpha: CaptionPill.color.alpha)],
                 pill: StylePill(color: .token(pillColorToken), horizontalEm: CaptionPill.horizontalEm, verticalEm: CaptionPill.verticalEm),
                 caption: CaptionStyleSpec(baseStyle: CaptionPill.styleID, font: .token(brandFontToken),
                                           textColor: .token(textColorToken), usesPill: true),
                 motion: MotionDefaults(duration: Time(1, 2), curve: MotionCurve.premiereDefault.rawValue))
    }

    /// Kit-owned looks are registered under this id (`CaptionLook.styleID(for:)` adds the "look-" prefix).
    public static func lookID(_ id: String) -> String { "kit-\(id)" }

    /// The kit caption style built on `library`'s base style; nil without a caption spec.
    public func captionStyle(base library: CaptionPresetLibrary) -> TextStyle? {
        guard let spec = caption else { return nil }
        var s = library.style(for: spec.baseStyle)
        var t = s.tokens ?? TextStyleTokens()
        if let f = spec.font {
            if let v = f.resolve({ font($0) }) { s.fontName = v }
            t.font = f.tokenName
        }
        if let size = spec.size { s.size = max(1, size) }
        if let caps = spec.allCaps { s.allCaps = caps }
        if let c = spec.textColor {
            if let v = c.resolve({ color($0) }) { s.color = RGBAColor(v) }
            t.color = c.tokenName
        }
        if let c = spec.strokeColor {
            if let v = c.resolve({ color($0) }) {
                s.stroke = TextStroke(color: RGBAColor(v), width: s.stroke?.width ?? max(2, (s.size * 0.1).rounded()),
                                      position: s.stroke?.position ?? .outside)
            }
            t.strokeColor = c.tokenName
        }
        if let w = spec.tweaks {
            if let v = w.weight.flatMap(FontWeight.init(rawValue:)) { s.weight = v }
            if let v = w.italic { s.italic = v }
            if let v = w.alignment.flatMap(TextAlignment.init(rawValue:)) { s.alignment = v }
            if let v = w.tracking, v.isFinite { s.tracking = v }
            if let v = w.lineSpacing, v.isFinite { s.lineSpacing = v }
            if s.stroke != nil {
                if let v = w.strokeWidth, v.isFinite { s.stroke?.width = max(0, v) }
                if let v = w.strokePosition.flatMap(StrokePosition.init(rawValue:)) { s.stroke?.position = v }
            }
            if w.hidesShadow == true {
                s.shadow = nil
            } else if let sh = w.shadow {
                var v = TextShadow(color: RGBAColor(sh.color), offsetX: sh.offsetX, offsetY: sh.offsetY, blur: sh.blur)
                v.restingAngle = sh.restingAngle
                s.shadow = v
            }
        }
        if spec.usesPill {
            let p = pill ?? StylePill(color: .literal(EffectColor(red: 0, green: 0, blue: 0, alpha: CaptionPill.color.alpha)))
            let c = p.color.resolve({ color($0) }).map(RGBAColor.init) ?? CaptionPill.color
            s.background = TextBackground(color: c, padding: BoxPadding(horizontal: (s.size * p.horizontalEm).rounded(),
                                                                         vertical: (s.size * p.verticalEm).rounded()),
                                          cornerRadius: p.cornerRadius ?? 10_000)
            t.backgroundColor = p.color.tokenName
        } else if spec.hidesBackground == true {
            s.background = nil   // FB-Y: Pill off on a look with a box of its own keeps the look, drops the box
            t.backgroundColor = nil
        }
        s.tokens = t.isEmpty ? nil : t
        return s
    }

    /// Adds (or replaces) a caption look carried by the kit.
    public mutating func addLook(_ look: CaptionLook, id: String, name: String) throws {
        looks[id] = StyleKitLook(name: name, payload: try look.payload(), payloadVersion: CaptionLook.payloadVersion)
    }

    /// The kit's Looks that this build can read, as captions render them, by id (one reader: `StyleKit.look`).
    public func captionLooks() -> [(id: String, name: String, look: CaptionLook)] {
        looks.keys.sorted().compactMap { id in look(id).map { (id, $0.name, $0.captionLook) } }
    }
}

extension CaptionPresetLibrary {
    /// A copy with `kit` applied: every token-bound style resolved, the kit caption style under `StyleKit.captionStyleRef`
    /// (animation `StyleKit.captionAnimationRef`: the spec's animation, else the caption pop) and the kit's looks under
    /// `StyleKit.lookID`. Nil = unchanged.
    public func applying(_ kit: StyleKit?) -> CaptionPresetLibrary {
        guard let kit else { return self }
        var lib = CaptionPresetLibrary(styles: styles.mapValues { $0.resolved(in: kit) }, animations: animations,
                                       defaultStyleID: defaultStyleID, defaultAnimationID: defaultAnimationID)
        for (id, _, look) in kit.captionLooks() {
            var l = look
            l.style = l.style.resolved(in: kit)
            lib = lib.adding(l, id: StyleKit.lookID(id))
        }
        if let style = kit.captionStyle(base: self) {
            var s = lib.styles, a = lib.animations
            s[StyleKit.captionStyleRef] = style
            a[StyleKit.captionAnimationRef] = kit.caption?.animation.flatMap { animations[$0] } ?? .captionPop
            lib = CaptionPresetLibrary(styles: s, animations: a, defaultStyleID: defaultStyleID, defaultAnimationID: defaultAnimationID)
        }
        lib.position = kit.captionPosition ?? .default
        return lib
    }
}

extension Project {
    /// True for a project written before the built-in caption and text styles moved to Inter: its `styleRef`s keep
    /// resolving to the Helvetica built-ins.
    public var usesLegacyBuiltInFont: Bool { (builtInStyles ?? 0) < Project.currentBuiltInStyles }

    /// Writes the current kit values into every text clip whose style follows a token (one pass over all sequences).
    /// Returns how many clips changed. Clips whose payload this build cannot read stay as they are.
    @discardableResult
    public mutating func resolveTextTokens() -> Int {
        let kit = styleKit
        guard kit != nil else { return 0 }
        let marker = Data(#""tokens""#.utf8)                 // cheap pre-check: only payloads with bound fields are decoded
        return rewriteGenerators { g in
            guard g.kind == GeneratorRef.text, g.payload.range(of: marker) != nil, let (template, anim) = try? TextGenerator.decode(g),
                  template.style.tokens != nil else { return nil }
            let style = template.style.resolved(in: kit)
            guard style != template.style else { return nil }
            var tp = template
            tp.style = style
            return try? TextGenerator.makeRef(template: tp, animations: anim)
        }
    }
}
