import AppKit
import Observation
import SSText

/// State and edit logic of the text properties inspector (docs/UX.md: styling lives in Properties).
/// Every edit goes through `edit`, which brackets it in begin/end for undo coalescing unless the
/// caller already opened a session (`beginEditing` ... `endEditing`, e.g. for a color-well drag).
@MainActor @Observable
public final class TextInspectorModel {
    public private(set) var style: TextStyle
    public private(set) var animations: AnimationSet
    public private(set) var library: CaptionPresetLibrary
    /// Installed font families (plus the current font name when it is not one of them).
    public private(set) var fontFamilies: [String]

    /// Undo coalescing: begin, any number of changes, end.
    @ObservationIgnored public var onBeginEditing: (() -> Void)?
    @ObservationIgnored public var onChange: ((TextStyle, AnimationSet) -> Void)?
    @ObservationIgnored public var onEndEditing: (() -> Void)?
    /// Called after `saveCurrentAsPreset` so the host can persist the library.
    @ObservationIgnored public var onPresetsChanged: ((CaptionPresetLibrary) -> Void)?

    @ObservationIgnored private var sessionDepth = 0
    @ObservationIgnored private let familyProvider: () -> [String]
    @ObservationIgnored private var lastStroke = TextStroke(color: .black, width: 4)
    @ObservationIgnored private var lastBackground = TextBackground(
        color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.75),
        padding: BoxPadding(horizontal: 16, vertical: 8), cornerRadius: 8)
    @ObservationIgnored private var lastShadow = TextShadow(
        color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), offsetX: 0, offsetY: 2, blur: 6)

    public init(style: TextStyle = TextStyle(),
                animations: AnimationSet = AnimationSet(in: nil, out: nil),
                library: CaptionPresetLibrary = .builtIn,
                fontFamilies: @escaping () -> [String] = { NSFontManager.shared.availableFontFamilies }) {
        self.style = style; self.animations = animations; self.library = library
        self.familyProvider = fontFamilies
        self.fontFamilies = []
        remember(style)
        refreshFamilies()
    }

    /// Replaces the edited values from outside (selection changed). Fires no callbacks.
    public func load(style: TextStyle, animations: AnimationSet) {
        self.style = style; self.animations = animations
        remember(style)
        refreshFamilies()
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

    private func edit(_ body: (inout TextStyle) -> Void) {
        var s = style
        body(&s)
        guard s != style else { return }
        beginEditing()
        style = s
        remember(s)
        onChange?(style, animations)
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

    private func remember(_ s: TextStyle) {
        if let v = s.stroke { lastStroke = v }
        if let v = s.background { lastBackground = v }
        if let v = s.shadow { lastShadow = v }
    }

    private func refreshFamilies() {
        var f = familyProvider()
        if !style.fontName.isEmpty, !f.contains(style.fontName) { f.insert(style.fontName, at: 0) }
        fontFamilies = f
    }

    // MARK: Basic

    public func setFontFamily(_ name: String) { edit { $0.fontName = name } ; refreshFamilies() }
    public func setWeight(_ w: FontWeight) { edit { $0.weight = w } }
    public func setSize(_ v: Double) { edit { $0.size = max(1, v) } }
    public func setColor(_ c: RGBAColor) { edit { $0.color = c } }
    public func setAlignment(_ a: TextAlignment) { edit { $0.alignment = a } }
    public func setLineSpacing(_ v: Double) { edit { $0.lineSpacing = v } }

    // MARK: Stroke

    public var strokeEnabled: Bool { style.stroke != nil }
    public func setStrokeEnabled(_ on: Bool) { edit { $0.stroke = on ? lastStroke : nil } }
    public func setStrokeColor(_ c: RGBAColor) { edit { $0.stroke?.color = c } }
    public func setStrokeWidth(_ w: Double) { edit { $0.stroke?.width = max(0, w) } }

    // MARK: Background box

    public var backgroundEnabled: Bool { style.background != nil }
    public func setBackgroundEnabled(_ on: Bool) { edit { $0.background = on ? lastBackground : nil } }
    public func setBackgroundColor(_ c: RGBAColor) { edit { $0.background?.color = c } }
    public func setBackgroundPadding(horizontal: Double, vertical: Double) {
        edit { $0.background?.padding = BoxPadding(horizontal: horizontal, vertical: vertical) }
    }
    public func setBackgroundRadius(_ r: Double) { edit { $0.background?.cornerRadius = max(0, r) } }

    // MARK: Shadow

    public var shadowEnabled: Bool { style.shadow != nil }
    public func setShadowEnabled(_ on: Bool) { edit { $0.shadow = on ? lastShadow : nil } }
    public func setShadowColor(_ c: RGBAColor) { edit { $0.shadow?.color = c } }
    public func setShadowOffset(x: Double, y: Double) { edit { $0.shadow?.offsetX = x; $0.shadow?.offsetY = y } }
    public func setShadowBlur(_ b: Double) { edit { $0.shadow?.blur = max(0, b) } }

    // MARK: Caption style presets

    public var presetIDs: [String] { library.styleIDs }

    /// The preset whose style equals the current style, if any ("default" only when nothing else matches).
    public var selectedPresetID: String? {
        let ids = library.styleIDs
        return ids.first { $0 != library.defaultStyleID && library.style(for: $0) == style }
            ?? ids.first { library.style(for: $0) == style }
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

    // MARK: Animations (anchored: in = start, out = end)

    public var inAnimationIDs: [String] {
        library.animationIDs.filter { library.animation(for: $0).anchor == .start }
    }
    public var outAnimationIDs: [String] {
        library.animationIDs.filter { id in
            let a = library.animation(for: id)
            return a.anchor == .end || a == .none
        }
    }
    public var selectedInID: String? { animationID(animations.animationIn, among: inAnimationIDs) }
    public var selectedOutID: String? { animationID(animations.animationOut, among: outAnimationIDs) }

    private func animationID(_ t: KeyframeTemplate?, among ids: [String]) -> String? {
        let t = t ?? .none
        return ids.first { library.animation(for: $0) == t }
    }

    public func setInAnimation(_ id: String) {
        guard library.hasAnimation(id) else { return }
        let t = library.animation(for: id)
        editAnimations { $0.animationIn = t == .none ? nil : t }
    }

    public func setOutAnimation(_ id: String) {
        guard library.hasAnimation(id) else { return }
        let t = library.animation(for: id)
        editAnimations { $0.animationOut = t == .none ? nil : t }
    }
}
