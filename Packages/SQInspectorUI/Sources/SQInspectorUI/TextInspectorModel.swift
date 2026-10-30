import Foundation
import Observation
import SQCore
import SQText
import SQUIKit

/// State and edit logic of the text properties inspector (docs/UX.md: styling lives in Properties).
/// Every edit goes through `edit`, which brackets it in begin/end for undo coalescing unless the
/// caller already opened a session (`beginEditing` ... `endEditing`, e.g. for a color-well drag).
@MainActor @Observable
public final class TextInspectorModel {
    public private(set) var style: TextStyle
    public private(set) var animations: AnimationSet
    public private(set) var library: CaptionPresetLibrary
    /// Text styles (look only): the built-in set plus the user's saved ones.
    public private(set) var styles: TextStyleLibrary
    /// The style last applied or saved from this inspector; with `style` it tells whether the clip was edited away from it.
    public private(set) var appliedStyleID: String?
    /// Nil = the live caption library (`.builtIn`, which follows the project's style kit), re-read on every `load`.
    @ObservationIgnored private let fixedLibrary: CaptionPresetLibrary?
    /// Styles saved with `saveCurrentAsPreset` in this inspector (kept across library refreshes).
    @ObservationIgnored private var savedStyles: [String: TextStyle] = [:]
    /// Installed font families (plus the current font name when it is not one of them).
    public private(set) var fontFamilies: [String]

    /// Undo coalescing: begin, any number of changes, end.
    @ObservationIgnored public var onBeginEditing: (() -> Void)?
    @ObservationIgnored public var onChange: ((TextStyle, AnimationSet) -> Void)?
    @ObservationIgnored public var onEndEditing: (() -> Void)?
    /// Called after `saveCurrentAsPreset` so the host can persist the library.
    @ObservationIgnored public var onPresetsChanged: ((CaptionPresetLibrary) -> Void)?
    /// Called after the user's text styles changed (save, rename, duplicate, delete, update) so the host can persist them.
    @ObservationIgnored public var onStylesChanged: ((TextStyleLibrary) -> Void)?

    @ObservationIgnored private var sessionDepth = 0
    @ObservationIgnored private let familyProvider: () -> [String]
    @ObservationIgnored private var lastStroke = TextStroke(color: .black, width: 4)
    @ObservationIgnored private var lastGradient: TextGradient?
    @ObservationIgnored private var lastBackground = TextBackground(
        color: TextBoxDefaults.backgroundColor,
        padding: TextBoxDefaults.backgroundPadding, cornerRadius: TextBoxDefaults.backgroundRadius)
    @ObservationIgnored private var lastSecondLine: TextLineStyle?
    @ObservationIgnored private var lastShadow = TextShadow(
        color: TextBoxDefaults.shadowColor, offsetX: 0, offsetY: 2, blur: 6)

    public init(style: TextStyle = TextStyle(),
                animations: AnimationSet = AnimationSet(in: nil, out: nil),
                library: CaptionPresetLibrary? = nil,
                fontFamilies: @escaping () -> [String] = { TextBoxDefaults.installedFamilies() },
                styles: TextStyleLibrary = TextStyleLibrary()) {
        self.styles = styles
        self.style = style; self.animations = animations; self.library = library ?? .builtIn; self.fixedLibrary = library
        self.familyProvider = fontFamilies
        self.fontFamilies = []
        remember(style)
        refreshFamilies()
    }

    /// Replaces the edited values from outside (selection changed). Fires no callbacks.
    /// Multi-select: dotted paths of the template fields ("style.size", "style.shadow", "text") that differ between the
    /// selected text clips; the panel shows those fields empty. Set by the host, empty for one clip.
    public var mixedPaths: Set<String> = []

    /// True when the style field at `path` ("size", "shadow.blur") differs between the selected clips.
    public func isMixed(_ path: String) -> Bool { mixedPaths.contains("style." + path) }

    /// The color at `path` ("color", "shadow.color") differs in red, green or blue (opacity has its own field), or its
    /// layer is on in some clips and off in others: the well shows the mixed state.
    public func isMixedColor(_ path: String) -> Bool {
        if ["red", "green", "blue"].contains(where: { isMixed(path + "." + $0) }) || isMixed(path) { return true }
        // "stroke.color": the stroke layer itself switched differently.
        guard let dot = path.lastIndex(of: ".") else { return false }
        return isMixedPresence(String(path[..<dot]))
    }

    /// A layer group ("stroke", "background", "shadow", "secondLine") is on in some clips and off in others.
    public func isMixedPresence(_ group: String) -> Bool { mixedPaths.contains("style." + group) }

    /// Picture size of the sequence: a saved animation stores Position as a fraction of it.
    public var frameSize = Vec2(1080, 1920)
    /// The Library's keystones of this window: where the Intro / Outro popups read saved animations and save a Custom
    /// one. Set by the host; without it there are no saved animations and nothing can be saved.
    @ObservationIgnored public weak var keystones: (any AnimationKeystoneSource)?
    /// What the model edits now (the host sets the clip or layer id): an async save applies its result only to the
    /// target it started on, however alike another target's animations are.
    @ObservationIgnored public var target: AnyHashable?

    public func load(style: TextStyle, animations: AnimationSet) {
        if sessionDepth > 0 { sessionDepth = 0; onEndEditing?() }     // an open edit session belongs to the previous values
        self.style = style; self.animations = animations
        appliedStyleID = styles.match(style)
        remember(style)
        refreshFamilies()
        refreshLibrary()
    }

    /// Re-reads the caption library (the kit or saved looks may have changed since the last load).
    public func refreshLibrary() {
        let base = fixedLibrary ?? .builtIn
        guard !savedStyles.isEmpty else { if base.styles != library.styles || base.animations != library.animations { library = base }; return }
        var styles = base.styles
        for (k, v) in savedStyles { styles[k] = v }
        library = CaptionPresetLibrary(styles: styles, animations: base.animations,
                                       defaultStyleID: base.defaultStyleID, defaultAnimationID: base.defaultAnimationID)
    }

    // MARK: Sessions

    public func beginEditing() {
        if sessionDepth == 0 { onBeginEditing?() }
        sessionDepth += 1
    }

    public func endEditing() {
        guard sessionDepth > 0 else { return }
        sessionDepth -= 1
        if sessionDepth == 0 { onEndEditing?() }
    }

    /// Multi-select: the template paths ("style.italic") the current `onChange` must copy to every selected clip even
    /// where the shown clip did not change (a mixed field set to the shown value). Empty outside an edit.
    public private(set) var pendingForcedPaths: Set<String> = []

    /// `fields`: the style fields the edit sets ("italic", "shadow"); those that are mixed are forced to all clips.
    private func edit(_ fields: String..., body: (inout TextStyle) -> Void) {
        var s = style
        body(&s)
        let forced = Set(fields.map { "style." + $0 }.filter { f in mixedPaths.contains { $0 == f || $0.hasPrefix(f + ".") } })
        guard s != style || !forced.isEmpty else { return }
        beginEditing()
        style = s
        remember(s)
        pendingForcedPaths = forced
        onChange?(style, animations)
        pendingForcedPaths = []
        endEditing()
    }

    private func editAnimations(_ body: (inout AnimationSet) -> Void) {
        var a = animations
        body(&a)
        guard a != animations else { return }
        beginEditing()
        animations = a
        onChange?(style, animations)
        endEditing()
    }

    /// What a layer starts with when switched on while the style has none (a host with its own defaults, e.g. the caption
    /// pill). Fires no callbacks; a layer the style already has keeps its own values.
    public func seedLayerDefaults(background: TextBackground? = nil, stroke: TextStroke? = nil, shadow: TextShadow? = nil) {
        if style.background == nil, let background { lastBackground = background }
        if style.stroke == nil, let stroke { lastStroke = stroke }
        if style.shadow == nil, let shadow { lastShadow = shadow }
    }

    private func remember(_ s: TextStyle) {
        if let v = s.stroke { lastStroke = v }
        if let v = s.background { lastBackground = v }
        if let g = s.gradient { lastGradient = g }
        if let v = s.shadow { lastShadow = v }
        if let v = s.secondLine { lastSecondLine = v }
    }

    private func refreshFamilies() {
        var f = familyProvider()
        if !style.fontName.isEmpty, !f.contains(style.fontName) { f.insert(style.fontName, at: 0) }
        if let n = style.secondLine?.fontName, !n.isEmpty, !f.contains(n) { f.insert(n, at: 0) }
        fontFamilies = f
    }

    // MARK: Basic

    public func setFontFamily(_ name: String) { edit("fontName") { $0.fontName = name; $0.unbind(\.font) } ; refreshFamilies() }
    public func setWeight(_ w: FontWeight) { edit("weight") { $0.weight = w } }
    public func setSize(_ v: Double) { edit("size") { $0.size = max(1, v) } }
    public func setColor(_ c: RGBAColor) { edit("color.red", "color.green", "color.blue") { $0.color = c; $0.unbind(\.color) } }
    /// Fill opacity (0 = fill off); the fill color stays.
    public func setFillAlpha(_ a: Double) {
        edit("color.alpha") { $0.color = $0.color.withAlpha(a); $0.unbind(\.color) }
    }
    public func setAlignment(_ a: TextAlignment) { edit("alignment") { $0.alignment = a } }
    public func setLineSpacing(_ v: Double) { edit("lineSpacing") { $0.lineSpacing = v } }
    public func setTracking(_ v: Double) { edit("tracking") { $0.tracking = v } }
    public func setItalic(_ on: Bool) { edit("italic") { $0.italic = on } }
    public func setVerticalAlignment(_ a: TextVerticalAlignment) { edit("verticalAlignment") { $0.verticalAlignment = a } }
    public func setAllCaps(_ on: Bool) { edit("allCaps") { $0.allCaps = on } }
    /// Line styles (`TextDecorations`): a bar under, through or over every line, in the fill color.
    public func setUnderline(_ on: Bool) { edit("underline") { $0.underline = on } }
    public func setStrikethrough(_ on: Bool) { edit("strikethrough") { $0.strikethrough = on } }
    public func setOverline(_ on: Bool) { edit("overline") { $0.overline = on } }

    /// Paragraph direction: nil is automatic (the first strong character decides).
    public func setDirection(_ d: TextDirection?) { edit("direction") { $0.direction = d } }

    /// The variation axes of the style's font (empty for a static font), in the font's axis order.
    public var fontAxes: [FontResolver.Axis] { FontResolver.axes(forFontName: style.fontName) }

    /// The value an axis shows: the style's override, else the font's default.
    public func axisValue(_ axis: FontResolver.Axis) -> Double {
        min(max(style.fontAxes?[axis.tag] ?? axis.defaultValue, axis.minimum), axis.maximum)
    }

    /// Sets one axis; a value equal to the font's default removes the override (and the dictionary when it is empty), so
    /// an untouched style stays `fontAxes == nil`.
    public func setFontAxis(_ axis: FontResolver.Axis, _ value: Double) {
        edit("fontAxes") { s in
            var a = s.fontAxes ?? [:]
            let v = min(max(value, axis.minimum), axis.maximum)
            if v == axis.defaultValue { a[axis.tag] = nil } else { a[axis.tag] = v }
            s.fontAxes = a.isEmpty ? nil : a
        }
    }

    public func resetFontAxes() { edit("fontAxes") { $0.fontAxes = nil } }

    /// The six align buttons: the host moves the clip so its text block meets the frame (it owns the clip's transform).
    @ObservationIgnored public var onAlignToFrame: ((FrameAlignment) -> Void)?
    public func alignToFrame(_ a: FrameAlignment) { onAlignToFrame?(a) }

    // MARK: Footage fill

    /// nil = the Fill color fills the glyphs; `.stencil` shows the picture below through them; `.inverted` inverts it.
    public func setFootageFill(_ f: TextFootageFill?) { edit("footageFill") { $0.footageFill = f } }

    // MARK: Stroke

    public var strokeEnabled: Bool { style.stroke != nil }
    public func setStrokeEnabled(_ on: Bool) { edit("stroke") { $0.stroke = on ? lastStroke : nil } }
    public func setStrokeColor(_ c: RGBAColor) { edit("stroke.color.red", "stroke.color.green", "stroke.color.blue") { $0.stroke?.color = c; $0.unbind(\.strokeColor) } }
    public func setStrokeWidth(_ w: Double) { edit("stroke.width") { $0.stroke?.width = max(0, w) } }
    public func setStrokePosition(_ p: StrokePosition) { edit("stroke.position") { $0.stroke?.position = p } }

    // MARK: Second line style (N4: small top line over a big bottom line)

    /// Every paragraph after the first is drawn in the second-line look (font, weight, size, color, italic).
    public var secondLineEnabled: Bool { style.secondLine != nil }
    /// On: the last second-line look of this inspector, else the clip look at twice the size and bold.
    public func setSecondLineEnabled(_ on: Bool) {
        edit("secondLine") { s in
            guard on else { s.secondLine = nil; return }
            guard s.secondLine == nil else { return }
            if let last = lastSecondLine { s.secondLine = last; return }
            var l = TextLineStyle(from: s)
            l.size = s.size * 2
            l.weight = max(s.weight, .bold)
            s.secondLine = l
        }
    }
    public func setSecondLineFont(_ name: String) { edit("secondLine.fontName") { $0.secondLine?.fontName = name }; refreshFamilies() }
    public func setSecondLineWeight(_ w: FontWeight) { edit("secondLine.weight") { $0.secondLine?.weight = w } }
    public func setSecondLineSize(_ v: Double) { edit("secondLine.size") { $0.secondLine?.size = max(1, v) } }
    public func setSecondLineColor(_ c: RGBAColor) { edit("secondLine.color.red", "secondLine.color.green", "secondLine.color.blue") { $0.secondLine?.color = c } }
    public func setSecondLineItalic(_ on: Bool) { edit("secondLine.italic") { $0.secondLine?.italic = on } }

    // MARK: Layout: shrink to box, lists, gradient fill

    public var autoFitEnabled: Bool { style.autoFit == true }
    /// On: in an area text box the glyphs shrink until the block fits (never grow). Off: the size stays as set.
    public func setAutoFit(_ on: Bool) { edit("autoFit") { $0.autoFit = on ? true : nil } }

    public var listKind: TextListKind? { style.list }
    public func setList(_ kind: TextListKind?) { edit("list") { $0.list = kind } }

    public var gradientEnabled: Bool { style.gradient != nil }
    /// On: the last gradient of this inspector, else the fill color to its inverse, top to bottom.
    public func setGradientEnabled(_ on: Bool) {
        edit("gradient") { s in
            guard on else { s.gradient = nil; return }
            guard s.gradient == nil else { return }
            if let g = lastGradient { s.gradient = g; return }
            let c = s.color
            let inverse: RGBAColor = .init(red: 1 - c.red, green: 1 - c.green, blue: 1 - c.blue, alpha: c.alpha)
            s.gradient = TextGradient(start: c, end: inverse, angle: 90)
        }
    }
    public func setGradientStart(_ c: RGBAColor) {
        edit("gradient.start.red", "gradient.start.green", "gradient.start.blue") { $0.gradient?.start = c }
    }
    public func setGradientEnd(_ c: RGBAColor) {
        edit("gradient.end.red", "gradient.end.green", "gradient.end.blue") { $0.gradient?.end = c }
    }
    public func setGradientAngle(_ degrees: Double) { edit("gradient.angle") { $0.gradient?.angle = degrees } }

    // MARK: Background box

    public var backgroundEnabled: Bool { style.background != nil }
    public func setBackgroundEnabled(_ on: Bool) { edit("background") { $0.background = on ? lastBackground : nil } }
    public func setBackgroundColor(_ c: RGBAColor) { edit("background.color.red", "background.color.green", "background.color.blue") { $0.background?.color = c; $0.unbind(\.backgroundColor) } }
    public func setBackgroundPadding(horizontal: Double, vertical: Double) {
        edit("background.padding") { $0.background?.padding = BoxPadding(horizontal: horizontal, vertical: vertical) }
    }
    public func setBackgroundRadius(_ r: Double) { edit("background.cornerRadius") { $0.background?.cornerRadius = max(0, r) } }

    // MARK: Shadow

    public var shadowEnabled: Bool { style.shadow != nil }
    public func setShadowEnabled(_ on: Bool) { edit("shadow") { $0.shadow = on ? lastShadow : nil } }
    public func setShadowColor(_ c: RGBAColor) { edit("shadow.color.red", "shadow.color.green", "shadow.color.blue") { $0.shadow?.color = c } }
    public func setShadowOffset(x: Double, y: Double) { edit("shadow.offsetX", "shadow.offsetY") { $0.shadow?.offsetX = x; $0.shadow?.offsetY = y } }
    public func setShadowBlur(_ b: Double) { edit("shadow.blur") { $0.shadow?.blur = max(0, b) } }
    /// Premiere-style: light angle in degrees and distance in pixels (the stored offset follows).
    public func setShadowAngle(_ degrees: Double, distance: Double) {
        edit("shadow.offsetX", "shadow.offsetY") {
            guard let sh = $0.shadow else { return }
            var n = TextShadow(color: sh.color, angle: degrees, distance: max(0, distance), blur: sh.blur)
            n.spread = sh.spread
            $0.shadow = n
        }
    }
    /// Premiere's shadow "Size": the glyph shape grows by this many px before the blur.
    public func setShadowSpread(_ s: Double) { edit("shadow.spread") { $0.shadow?.spread = max(0, s) } }
    public func setShadowOpacity(_ o: Double) {
        edit("shadow.color.alpha") {
            guard var sh = $0.shadow else { return }
            sh.color = sh.color.withAlpha(o)
            $0.shadow = sh
        }
    }
    public func setBackgroundOpacity(_ o: Double) {
        edit("background.color.alpha") {
            guard var b = $0.background else { return }
            b.color = b.color.withAlpha(o)
            $0.background = b
            $0.unbind(\.backgroundColor)
        }
    }

    // MARK: Kit tokens (W8.3)

    /// The project's style kit (the host sets it on every load); nil = the project has no kit and the bind controls are off.
    public var kit: StyleKit?

    public enum TokenField: Sendable, CaseIterable {
        case font, color, strokeColor, backgroundColor
        var path: WritableKeyPath<TextStyleTokens, String?> {
            switch self {
            case .font: \.font
            case .color: \.color
            case .strokeColor: \.strokeColor
            case .backgroundColor: \.backgroundColor
            }
        }
        /// The field exists in `style` (stroke and background color only with a stroke / background).
        public func isAvailable(in s: TextStyle) -> Bool {
            switch self {
            case .font, .color: true
            case .strokeColor: s.stroke != nil
            case .backgroundColor: s.background != nil
            }
        }
    }

    /// Token names of the kit that fit `field` (font tokens for the font, color tokens otherwise), sorted.
    public func tokenNames(for field: TokenField) -> [String] {
        guard let kit else { return [] }
        return (field == .font ? Array(kit.fonts.keys) : Array(kit.colors.keys)).sorted()
    }

    /// The token `field` follows, nil = a literal.
    public func boundToken(_ field: TokenField) -> String? { style.tokens?[keyPath: field.path] }

    /// Binds `field` to the kit token `name` (the style takes the token's current value at once and follows later kit
    /// changes) or, with nil, releases it (the current value stays as a literal). One edit step; unknown tokens are ignored.
    public func bindToken(_ field: TokenField, to name: String?) {
        guard field.isAvailable(in: style) else { return }
        if let name {
            guard tokenNames(for: field).contains(name) else { return }
            edit {
                var t = $0.tokens ?? TextStyleTokens()
                t[keyPath: field.path] = name
                $0.tokens = t
                $0 = $0.resolved(in: kit)
            }
        } else {
            edit { $0.unbind(field.path) }
        }
    }

    // MARK: Caption style presets

    public var presetIDs: [String] { library.styleIDs }

    /// The preset whose style equals the current style, if any ("default" only when nothing else matches).
    public var selectedPresetID: String? {
        let ids = library.styleIDs
        return ids.first { $0 != library.defaultStyleID && library.style(for: $0) == style }
            ?? ids.first { library.style(for: $0) == style }
    }

    /// Applies a gallery look to the title: its style, and its animation in the slot of its anchor (the other slot stays).
    /// One edit gesture (one undo step); everything stays editable afterwards.
    public func applyLook(_ look: CaptionStyleLook) {
        guard library.hasStyle(look.styleRef), library.hasAnimation(look.animationRef) else { return }
        let s = library.style(for: look.styleRef)
        let a = look.animationSet(in: library, keeping: animations)
        guard s != style || a != animations else { return }
        beginEditing()
        style = s; animations = a
        remember(s)
        onChange?(style, animations)
        endEditing()
    }

    /// The gallery look the title shows now: same style and animation slot (nil once edited).
    public var currentLookID: String? {
        CaptionStyleLooks.all.first { look in
            guard library.style(for: look.styleRef) == style else { return false }
            let t = library.animation(for: look.animationRef)
            return t == .none ? false : (t.anchor == .start ? animations.animationIn == t : animations.animationOut == t)
        }?.id
    }

    public func applyPreset(_ id: String) {
        guard library.hasStyle(id) else { return }
        edit { $0 = library.style(for: id) }
    }

    /// Saves the current style under a slug of `name` (made unique). Nil for an empty name.
    @discardableResult
    public func saveCurrentAsPreset(named name: String) -> String? {
        let slug = Self.slug(name)
        guard !slug.isEmpty else { return nil }
        var id = slug, n = 2
        while library.hasStyle(id) { id = "\(slug)-\(n)"; n += 1 }
        var styles = library.styles
        styles[id] = style
        savedStyles[id] = style
        library = CaptionPresetLibrary(styles: styles, animations: library.animations,
                                       defaultStyleID: library.defaultStyleID,
                                       defaultAnimationID: library.defaultAnimationID)
        onPresetsChanged?(library)
        return id
    }

    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    // MARK: Text styles (look only, no animation)

    /// The style whose look equals the current one exactly, if any.
    public var selectedStyleID: String? { styles.match(style) }

    /// The clip was edited away from the style it started from.
    public var isStyleModified: Bool {
        guard let id = appliedStyleID, let e = styles.entry(id) else { return false }
        return e.style != style
    }

    /// Applies the look of `id` to the clip: one undo step. Animations stay as they are.
    public func applyStyle(_ id: String) {
        guard let e = styles.entry(id) else { return }
        edit { $0 = e.style }
        appliedStyleID = id
    }

    /// Saves the current look under `name`; the new style counts as the applied one. Nil for an empty name.
    @discardableResult
    public func saveCurrentAsStyle(named name: String) -> String? {
        var next = styles
        guard let id = next.add(name: name, style: style) else { return nil }
        commitStyles(next)
        appliedStyleID = id
        return id
    }

    /// Overwrites a user style with the current look ("Update style").
    public func updateStyleFromCurrent(_ id: String) {
        var next = styles
        guard next.update(id, style: style) else { return }
        commitStyles(next)
    }

    public func renameStyle(_ id: String, to name: String) {
        var next = styles
        guard next.rename(id, to: name) else { return }
        commitStyles(next)
    }

    public func deleteStyle(_ id: String) {
        var next = styles
        guard next.delete(id) else { return }
        if appliedStyleID == id { appliedStyleID = nil }
        commitStyles(next)
    }

    /// The Look store changed (here or elsewhere): show its Looks.
    public func reloadStyles(_ library: TextStyleLibrary) {
        if styles != library || styles.base != library.base { styles = library }
    }

    private func commitStyles(_ next: TextStyleLibrary) {
        styles = next
        onStylesChanged?(next)
    }

    // MARK: Animations (anchored: in = start, out = end)

    /// Off first, the neutral presets, the rest, then the saved ones (`AnimationChoices`).
    public var inAnimationIDs: [String] { AnimationChoices.presetIDs(.intro, library: library, store: keystones) }
    public var outAnimationIDs: [String] { AnimationChoices.presetIDs(.outro, library: library, store: keystones) }
    /// The preset a side plays; nil = Custom, or a saved animation that is no longer in the Library (`isCustom` tells
    /// them apart). The text animator is not part of it (an animator-only side is "none").
    public var selectedInID: String? { presetID(.intro) }
    public var selectedOutID: String? { presetID(.outro) }

    /// Saved animations (Library keystones) per side; read so the popups follow the Library.
    public var savedAnimations: [Keystone] {
        AnimationChoices.saved(.intro, in: keystones) + AnimationChoices.saved(.outro, in: keystones)
    }

    private func presetID(_ side: AnimationSide) -> String? {
        AnimationChoices.presetID(of: animations.template(side), side: side, library: library, frameSize: frameSize, store: keystones,
                                  preferred: picked[side])
    }

    /// The side is keyed by hand: Controls shows its Position, Scale, Rotation and Opacity rows.
    public func isCustom(_ side: AnimationSide) -> Bool { AnimationChoices.isCustom(animations.template(side)) }

    /// What the side's popup shows: a preset's name, "Custom", or "Saved" for a saved animation the Library lost.
    public func animationTitle(_ side: AnimationSide) -> String {
        if isCustom(side) { return AnimationChoices.title(for: AnimationChoices.customID, side: side, store: keystones) }
        return presetID(side).map { AnimationChoices.title(for: $0, side: side, store: keystones) } ?? AnimationChoices.unknownTitle
    }

    /// Takes the item's animations when only they changed (a Custom side keyed in Controls, undo): unlike `load` an
    /// open edit session of the block stays open.
    public func adopt(animations next: AnimationSet) {
        if next != animations { animations = next }
    }

    // MARK: Zone lengths (Intro / Outro): the first N and the last M seconds of the clip

    /// Length of the clip the animations play on; set by the host. Bounds Intro + Outro (zones never overlap). nil: unknown.
    @ObservationIgnored public var clipDuration: Time?

    /// Shortest zone the length fields accept.
    public static let minimumZoneMilliseconds = 50

    /// Length of a side's zone in milliseconds; nil for a side that is Off, only an animator or a loop (no zone).
    public func zoneMilliseconds(_ side: AnimationSide) -> Int? {
        guard let t = animations.template(side), !t.tracks.isEmpty, !t.loops, t.duration > .zero else { return nil }
        return animatorMilliseconds(t.duration)
    }

    /// Longest this side may be: the clip minus the other zone (never below the minimum).
    public func maximumZoneMilliseconds(_ side: AnimationSide) -> Int {
        let cap = Self.maxAnimatorMilliseconds
        guard let clipDuration, clipDuration > .zero else { return cap }
        let other = zoneMilliseconds(side == .intro ? .outro : .intro) ?? 0
        let room = animatorMilliseconds(clipDuration) - other
        return max(Self.minimumZoneMilliseconds, min(cap, room))
    }

    /// Sets a side's zone length: its keys are scaled to it (an authoring change; playback never scales). The clip's
    /// other zone and the clip length bound it.
    public func setZoneLength(milliseconds ms: Int, side: AnimationSide) {
        guard zoneMilliseconds(side) != nil else { return }
        let clamped = min(max(ms, Self.minimumZoneMilliseconds), maximumZoneMilliseconds(side))
        let d = Self.animatorTime(clamped)
        editAnimations { set in
            if side == .intro, let t = set.animationIn { set.animationIn = t.retimed(toDuration: d) }
            if side == .outro, let t = set.animationOut { set.animationOut = t.retimed(toDuration: d) }
        }
    }

    public func setInAnimation(_ id: String) { setAnimation(id, side: .intro) }
    public func setOutAnimation(_ id: String) { setAnimation(id, side: .outro) }

    /// A preset, a saved animation, or `AnimationChoices.customID` (see `makeCustom`).
    public func setAnimation(_ id: String, side: AnimationSide) {
        if id == AnimationChoices.customID { makeCustom(side); return }
        // Picking what the side already shows changes nothing (its template is the same animation).
        if id.hasPrefix(AnimationChoices.savedPrefix), presetID(side) == id { picked[side] = id; return }
        guard let t = AnimationChoices.template(for: id, side: side, library: library, frameSize: frameSize, store: keystones)
        else { return }
        picked[side] = id
        setTemplate(t, side: side)
    }

    /// What was picked or saved last per side: it names the side when several animations hold the same curves. Not
    /// stored with the item, so after a reopen such a side shows the first match again.
    @ObservationIgnored private var picked: [AnimationSide: String] = [:]

    /// Turns the side into a Custom animation: what it plays now with keys of its own, or a plain fade when it was Off.
    public func makeCustom(_ side: AnimationSide) {
        guard !isCustom(side) else { return }
        let now = animations.template(side).flatMap { $0.tracks.isEmpty ? nil : $0 }
        setTemplate(now?.withFreshKeyIDs() ?? .customStart(side), side: side)
    }

    /// True when a Custom side can be saved here: the host attached a Library that takes keystones.
    public var canSaveAnimations: Bool { keystones?.canSave == true }

    /// Saves the side's Custom animation in the Library (a keystone) under `name`. Only once the Library holds it does
    /// the side play that saved animation (the popup shows its name; "Custom" makes it editable again): until then the
    /// side stays Custom, there is no optimistic state. False when nothing is keyed, no Library is attached or it could
    /// not store the keystone: the caller tells the user. A side edited while the Library stored keeps its edit.
    @discardableResult
    public func saveCustomAnimation(_ side: AnimationSide, named name: String) async -> Bool {
        guard isCustom(side), let t = animations.template(side), let store = keystones,
              let k = Keystone(animation: t, side: side, name: name, frameSize: frameSize),
              var saved = k.animationTemplate(frameSize: frameSize) else { return false }
        // The keystone keeps the loop flag, so the saved animation loops again where it is picked later.
        saved.loops = t.loops
        let origin = target
        guard await store.save(k) else { return false }
        if target == origin, animations.template(side) == t {
            picked[side] = AnimationChoices.savedPrefix + k.id.uuidString
            setTemplate(saved, side: side)
        }
        return true
    }

    private func setTemplate(_ t: KeyframeTemplate, side: AnimationSide) {
        editAnimations { set in
            let next = Self.combine(preset: t, animator: set.template(side)?.textAnimator, anchor: side == .intro ? .start : .end)
            if side == .intro { set.animationIn = next } else { set.animationOut = next }
        }
    }

    /// A side's template: the preset's tracks (none for `.none`) plus the text animator; nil when both are empty.
    private static func combine(preset: KeyframeTemplate?, animator: TextAnimator?, anchor: AnimationAnchor) -> KeyframeTemplate? {
        var t = preset.flatMap { $0.tracks.isEmpty ? nil : $0 }
        if t == nil, animator != nil { t = KeyframeTemplate(tracks: [], duration: .zero, anchor: anchor) }
        t?.textAnimator = animator
        t?.anchor = anchor
        return t
    }

    // MARK: Text animators (per character / word / line, W3.5)

    public enum AnimatorSide: Sendable { case `in`, out }

    public func animator(_ side: AnimatorSide) -> TextAnimator? {
        side == .in ? animations.animationIn?.textAnimator : animations.animationOut?.textAnimator
    }

    private func editAnimator(_ side: AnimatorSide, _ body: (inout TextAnimator?) -> Void) {
        editAnimations { set in
            var a = side == .in ? set.animationIn?.textAnimator : set.animationOut?.textAnimator
            body(&a)
            if side == .in { set.animationIn = Self.combine(preset: set.animationIn, animator: a, anchor: .start) }
            else { set.animationOut = Self.combine(preset: set.animationOut, animator: a, anchor: .end) }
        }
    }

    /// Default stagger by unit: letters follow each other fast, lines slowly.
    static func defaultStagger(_ unit: TextAnimatorUnit) -> Time {
        switch unit {
        case .character: Time(3, 100)
        case .word: Time(2, 25)
        case .line: Time(3, 20)
        }
    }

    /// nil removes the animator. A new animator starts by word, 300 ms per unit, 80 ms stagger; pop gets the overshoot.
    public func setAnimatorEffect(_ effect: TextAnimatorEffect?, side: AnimatorSide) {
        editAnimator(side) { a in
            guard let effect else { a = nil; return }
            if a == nil {
                a = TextAnimator(effect: effect, unit: .word, duration: Time(3, 10), stagger: Self.defaultStagger(.word))
            }
            if effect == .pop { a?.easing = .overshoot } else if a?.easing == .overshoot { a?.easing = .easeOut }
            a?.effect = effect
        }
    }

    public func setAnimatorUnit(_ unit: TextAnimatorUnit, side: AnimatorSide) {
        editAnimator(side) { a in
            guard let old = a, old.unit != unit else { return }
            a?.unit = unit
            if old.stagger == Self.defaultStagger(old.unit) { a?.stagger = Self.defaultStagger(unit) }   // untouched: follow the unit
        }
    }
    public func setAnimatorOrder(_ order: TextAnimatorOrder, side: AnimatorSide) { editAnimator(side) { $0?.order = order } }
    public func setAnimatorEasing(_ easing: SegmentShape, side: AnimatorSide) { editAnimator(side) { $0?.easing = easing } }
    public func setAnimatorDirection(_ d: TextSlideDirection, side: AnimatorSide) { editAnimator(side) { $0?.direction = d } }
    /// Longest stagger / length the fields accept (= `TextAnimator.maxTime`).
    public static let maxAnimatorMilliseconds = 60_000

    /// A typed field value as whole milliseconds in 0...60 000 (non-finite input reads as 0, never traps).
    public static func milliseconds(from value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(Double(maxAnimatorMilliseconds), max(0, value)).rounded())
    }

    private static func animatorTime(_ ms: Int) -> Time { Time(Int64(min(maxAnimatorMilliseconds, max(0, ms))), 1000) }

    public func setAnimatorDuration(milliseconds ms: Int, side: AnimatorSide) {
        editAnimator(side) { $0?.duration = Self.animatorTime(ms) }
    }
    /// Slide distance in sequence pixels (0...2000; non-finite reads as the default 40).
    public static let defaultAnimatorDistance = 40.0, defaultAnimatorBlur = 12.0, maxAnimatorPixels = 2000.0
    public func setAnimatorDistance(_ px: Double, side: AnimatorSide) {
        let v = px.isFinite ? min(Self.maxAnimatorPixels, max(0, px)) : Self.defaultAnimatorDistance
        editAnimator(side) { $0?.distance = v }
    }
    /// Start blur of the Blur effect in sequence pixels (0...2000).
    public func setAnimatorBlurRadius(_ px: Double, side: AnimatorSide) {
        let v = px.isFinite ? min(Self.maxAnimatorPixels, max(0, px)) : Self.defaultAnimatorBlur
        editAnimator(side) { $0?.blurRadius = v }
    }
    /// Cycles of a loop effect (wave, pulse), 1...50.
    public func setAnimatorLoops(_ n: Int, side: AnimatorSide) {
        editAnimator(side) { $0?.loops = min(max(n, 1), 50) }
    }
    public func setAnimatorStagger(milliseconds ms: Int, side: AnimatorSide) {
        editAnimator(side) { $0?.stagger = Self.animatorTime(ms) }
    }

    /// Nearest whole millisecond of `t` (display only; integer arithmetic).
    public func animatorMilliseconds(_ t: Time) -> Int {
        let n = Int128(t.value) * 1000, d = Int128(t.timescale)
        return Int((n * 2 + d) / (d * 2))
    }
}

private extension RGBAColor {
    /// The same color at opacity `a` (clamped to 0...1 by the initializer).
    func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: a) }
}

/// Defaults the text inspector restores when a box background or shadow is switched on again, and the font families it
/// offers. Portable (`Theme` is Mac-only): the same values as `Theme.TextDefaults`; the Mac's installed fonts
/// (`FontFamilyList`), the bundled families (`BundledFonts.pickerNames`) elsewhere.
@MainActor
public enum TextBoxDefaults {
    public static let backgroundColor = RGBAColor.black.withAlpha(0.75)
    public static let backgroundPadding = BoxPadding(horizontal: 16, vertical: 8)
    public static let backgroundRadius: Double = 8
    public static let shadowColor = RGBAColor.black.withAlpha(0.6)

    public static func installedFamilies() -> [String] {
        #if canImport(AppKit)
        FontFamilyList.current
        #else
        // shortcut: bundled families only off the Mac; list the system fonts (DirectWrite) when the font backend has them.
        BundledFonts.pickerNames
        #endif
    }
}
