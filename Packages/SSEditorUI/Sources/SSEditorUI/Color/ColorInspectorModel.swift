import CoreGraphics
import Foundation
import Observation
import SSCore
import SSRender

/// One slider of the colour panel: title, range, neutral value and where it lives in a Colour effect.
/// Ranges and neutrals follow Lumetri (docs/DECISIONS.md 2026-10-01).
public enum ColorParam: Int, CaseIterable, Sendable {
    // Basic Correction
    case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance
    case inputLUTIntensity
    // Creative
    case lookIntensity, fadedFilm, creativeVibrance, creativeSaturation, tintBalance
    // Color Wheels (master saturation)
    case wheelsSaturation
    // Vignette
    case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather

    public var title: String {
        switch self {
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .saturation, .creativeSaturation, .wheelsSaturation: "Saturation"
        case .vibrance, .creativeVibrance: "Vibrance"
        case .lookIntensity, .inputLUTIntensity: "Intensity"
        case .fadedFilm: "Faded Film"
        case .tintBalance: "Tint Balance"
        case .vignetteAmount: "Amount"
        case .vignetteMidpoint: "Midpoint"
        case .vignetteRoundness: "Roundness"
        case .vignetteFeather: "Feather"
        }
    }

    public var section: ColorSectionKind {
        switch self {
        case .temperature, .tint, .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .saturation, .vibrance,
             .inputLUTIntensity: .basicCorrection
        case .lookIntensity, .fadedFilm, .creativeVibrance, .creativeSaturation, .tintBalance: .creative
        case .wheelsSaturation: .wheels
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather: .vignette
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .exposure, .vignetteAmount: -5...5
        case .saturation, .creativeSaturation, .wheelsSaturation: 0...200
        case .lookIntensity, .inputLUTIntensity, .fadedFilm, .vignetteMidpoint, .vignetteFeather: 0...100
        default: -100...100
        }
    }

    public var neutral: Float {
        switch self {
        case .saturation, .creativeSaturation, .wheelsSaturation, .lookIntensity, .inputLUTIntensity: 100
        case .vignetteMidpoint, .vignetteFeather: 50
        default: 0
        }
    }

    /// Decimals shown (Premiere shows one).
    public var decimals: Int { self == .exposure || self == .vignetteAmount ? 2 : 1 }

    /// The two-colour track behind the slider (Temperature blue -> orange, Tint green -> magenta).
    public enum Track: Sendable { case plain, temperature, tint }
    public var track: Track { self == .temperature ? .temperature : self == .tint ? .tint : .plain }

    /// Rows of each section in display order (Premiere's Lumetri sub-groups). The Input LUT / Look popups and the
    /// wheels are added by the view around these.
    public static func layout(for kind: ColorSectionKind) -> [(group: String?, params: [ColorParam])] {
        switch kind {
        case .basicCorrection:
            [("Color", [.temperature, .tint, .saturation]),
             ("Light", [.exposure, .contrast, .highlights, .shadows, .whites, .blacks])]
        case .creative: [("Adjustments", [.fadedFilm, .creativeVibrance, .creativeSaturation])]
        case .wheels: [(nil, [.wheelsSaturation])]
        case .vignette: [(nil, [.vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather])]
        case .curves, .hslSecondary: []
        }
    }

    public func read(_ e: ColorEffect) -> Float {
        switch self {
        case .temperature: e.basic.temperature
        case .tint: e.basic.tint
        case .exposure: e.basic.exposure
        case .contrast: e.basic.contrast
        case .highlights: e.basic.highlights
        case .shadows: e.basic.shadows
        case .whites: e.basic.whites
        case .blacks: e.basic.blacks
        case .saturation: e.basic.saturation
        case .vibrance: e.basic.vibrance
        case .inputLUTIntensity: e.inputLUTIntensity
        case .lookIntensity: e.creative.intensity
        case .fadedFilm: e.creative.fadedFilm
        case .creativeVibrance: e.creative.vibrance
        case .creativeSaturation: e.creative.saturation
        case .tintBalance: e.creative.tintBalance
        case .wheelsSaturation: e.wheels.saturation
        case .vignetteAmount: e.vignette.amount
        case .vignetteMidpoint: e.vignette.midpoint
        case .vignetteRoundness: e.vignette.roundness
        case .vignetteFeather: e.vignette.feather
        }
    }

    /// Clamps to `range` and writes.
    public func write(_ value: Float, into e: inout ColorEffect) {
        let v = min(max(value, range.lowerBound), range.upperBound)
        switch self {
        case .temperature: e.basic.temperature = v
        case .tint: e.basic.tint = v
        case .exposure: e.basic.exposure = v
        case .contrast: e.basic.contrast = v
        case .highlights: e.basic.highlights = v
        case .shadows: e.basic.shadows = v
        case .whites: e.basic.whites = v
        case .blacks: e.basic.blacks = v
        case .saturation: e.basic.saturation = v
        case .vibrance: e.basic.vibrance = v
        case .inputLUTIntensity: e.inputLUTIntensity = v
        case .lookIntensity: e.creative.intensity = v
        case .fadedFilm: e.creative.fadedFilm = v
        case .creativeVibrance: e.creative.vibrance = v
        case .creativeSaturation: e.creative.saturation = v
        case .tintBalance: e.creative.tintBalance = v
        case .wheelsSaturation: e.wheels.saturation = v
        case .vignetteAmount: e.vignette.amount = v
        case .vignetteMidpoint: e.vignette.midpoint = v
        case .vignetteRoundness: e.vignette.roundness = v
        case .vignetteFeather: e.vignette.feather = v
        }
    }
}

/// The five Hue Saturation Curves of the Curves section (Premiere's tabs).
public enum HueCurveKind: Int, CaseIterable, Sendable {
    case hueVsSat, hueVsHue, hueVsLuma, lumaVsSat, satVsSat

    public var title: String {
        switch self {
        case .hueVsSat: "Hue vs Sat"
        case .hueVsHue: "Hue vs Hue"
        case .hueVsLuma: "Hue vs Luma"
        case .lumaVsSat: "Luma vs Sat"
        case .satVsSat: "Sat vs Sat"
        }
    }
    /// The hue-keyed curves wrap around and show a hue strip under the plot.
    public var isHueKeyed: Bool { rawValue <= HueCurveKind.hueVsLuma.rawValue }

    public func points(_ h: HueCurves) -> [CurvePoint] {
        switch self {
        case .hueVsSat: h.hueVsSat
        case .hueVsHue: h.hueVsHue
        case .hueVsLuma: h.hueVsLuma
        case .lumaVsSat: h.lumaVsSat
        case .satVsSat: h.satVsSat
        }
    }
    public func set(_ pts: [CurvePoint], in h: inout HueCurves) {
        switch self {
        case .hueVsSat: h.hueVsSat = pts
        case .hueVsHue: h.hueVsHue = pts
        case .hueVsLuma: h.hueVsLuma = pts
        case .lumaVsSat: h.lumaVsSat = pts
        case .satVsSat: h.satVsSat = pts
        }
    }
}

/// A colour wheel in the panel: the three wheels of Color Wheels, or the tints of Creative.
public enum ColorWheelSlot: Int, CaseIterable, Sendable {
    case shadows, midtones, highlights      // Color Wheels
    case shadowTint, highlightTint          // Creative

    public var title: String {
        switch self {
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        case .shadowTint: "Shadow Tint"
        case .highlightTint: "Highlight Tint"
        }
    }
    /// Only the three-way wheels carry a luminance slider.
    public var hasLuma: Bool { rawValue <= ColorWheelSlot.highlights.rawValue }
}

/// Which LUT of an effect a popup edits: the Input LUT (in Basic Correction) or the Creative look.
public enum ColorLUTSlot: Sendable { case input, look }

/// UI identity of a collapsible part of the panel: a section of an effect, or one of its sub-groups.
public struct ColorPanelKey: Hashable, Sendable {
    public var effect: Int
    public var kind: ColorSectionKind
    public var group: String?
    public init(_ effect: Int, _ kind: ColorSectionKind, group: String? = nil) {
        self.effect = effect; self.kind = kind; self.group = group
    }
}

/// State of the Color inspector for one clip: the clip's `ClipColor` plus UI-only state (which sections are open).
/// All edits go through here and are reported through `onChange`; gestures (`onGestureBegan`/`Ended`) make one undo step.
@MainActor @Observable
public final class ColorInspectorModel {
    public struct LUTChoice: Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }

        /// Input LUT: the camera's embedded look when the clip is S-Log3 and has one, else the built-in conversion.
        public static let automatic = LUTChoice(id: "automatic", name: "Automatic")
        /// The LUT embedded in the clip's media.
        public static func embedded(name: String) -> LUTChoice { LUTChoice(id: "embedded", name: "Embedded: \(name)") }
        public static func file(_ path: String) -> LUTChoice {
            LUTChoice(id: "file:" + path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        public var filePath: String? { id.hasPrefix("file:") ? String(id.dropFirst(5)) : nil }
    }

    /// Explicit "Interpret footage as" override; nil = Automatic (what the media says).
    public var sourceOverride: ColorSpaceID? { color.source }
    public private(set) var detectedSource: ColorSpaceID = .rec709
    public var source: SourceColorSpace { SourceColorSpace(color.source ?? detectedSource) }
    /// Name of the camera look LUT embedded in the clip's media, if any.
    public private(set) var embeddedLUTName: String?
    public private(set) var mediaID: UUID?
    /// The clip's frame at the playhead (with its current look) for the Creative preview; nil = use the synthetic picture.
    public var frameThumbnail: CGImage?

    public private(set) var color = ClipColor.default
    /// Sections and sub-groups that are collapsed (UI state, not stored in the clip).
    public private(set) var collapsed: Set<ColorPanelKey> = []
    private var knownEffects: Set<Int> = []

    /// LUT files the host offers in the popups (Library); `recent` are this user's last chosen files.
    public var availableLUTs: [LUTChoice] = []
    public var recents = RecentLUTs.shared
    public var recentLUTs: [String] = RecentLUTs.shared.paths

    public var onChange: ((ClipColor) -> Void)?
    /// One undo step per gesture: begin -> change* -> end.
    public var onGestureBegan: (() -> Void)?
    public var onGestureEnded: (() -> Void)?

    private var loading = false
    private var gestureDepth = 0

    public init() { syncKnownEffects() }

    public func clipColor() -> ClipColor { color }

    private func notify() { if !loading { onChange?(color) } }

    /// Applies an edit to the clip colour and reports it when something changed.
    private func edit(_ body: (inout ClipColor) -> Void) {
        var c = color
        body(&c)
        guard c != color else { return }
        color = c
        syncKnownEffects()
        notify()
    }

    private func editEffect(_ id: Int, _ body: (inout ColorEffect) -> Void) {
        edit { c in
            guard let i = c.effects.firstIndex(where: { $0.id == id }) else { return }
            body(&c.effects[i])
        }
    }

    /// Wraps a discrete edit (reset, popup choice, add/remove) as one undo step; nested calls collapse.
    public func gesture(_ body: () -> Void) {
        if gestureDepth == 0 { onGestureBegan?() }
        gestureDepth += 1
        body()
        gestureDepth -= 1
        if gestureDepth == 0 { onGestureEnded?() }
    }

    // MARK: Clip.color bridge

    /// Shows `color` (no callbacks fire). `info` = the clip's media, for the detected source and the embedded LUT.
    public func load(_ color: ClipColor, mediaID: UUID?, info: MediaInfo?) {
        loading = true
        defer { loading = false }
        if self.color != color { self.color = color }
        self.mediaID = mediaID
        detectedSource = info?.colorSpace ?? .rec709
        embeddedLUTName = info?.embeddedLUTName
        syncKnownEffects()
    }

    /// Forgets UI state of effects that are gone; the first time an effect is shown Basic Correction and Creative are
    /// open and the rest closed (Premiere).
    private func syncKnownEffects() {
        let ids = Set(color.effects.map(\.id))
        if !collapsed.isEmpty { collapsed = collapsed.filter { ids.contains($0.effect) } }
        knownEffects.formIntersection(ids)
        for id in ids.subtracting(knownEffects) {
            for k in ColorSectionKind.allCases where k != .basicCorrection && k != .creative { collapsed.insert(ColorPanelKey(id, k)) }
            knownEffects.insert(id)
        }
    }

    // MARK: Source

    public func setSourceOverride(_ id: ColorSpaceID?) { edit { $0.source = id } }

    // MARK: Effects and sections

    public var effects: [ColorEffect] { color.effects }

    /// Adds another Colour effect (Premiere: add another Lumetri Color). One undo step.
    public func addEffect() {
        gesture { edit { _ = $0.addEffect() } }
    }

    public func removeEffect(_ id: Int) {
        gesture { edit { $0.removeEffect(id) } }
    }

    public func setEnabled(_ effect: Int, _ kind: ColorSectionKind, _ on: Bool) {
        guard kind.isImplemented else { return }
        gesture { editEffect(effect) { $0.setEnabled(kind, on) } }
    }

    public func isEnabled(_ effect: Int, _ kind: ColorSectionKind) -> Bool {
        color.effect(effect)?.isEnabled(kind) ?? false
    }

    public func resetSection(_ effect: Int, _ kind: ColorSectionKind) {
        gesture { edit { $0.resetSection(kind, in: effect) } }
    }

    /// Premiere's per-effect Reset: every section of one Colour effect back to its defaults (toggles stay). One undo step.
    public func resetEffect(_ effect: Int) {
        gesture { for k in ColorSectionKind.allCases { edit { $0.resetSection(k, in: effect) } } }
    }

    /// Sets Temperature and Tint together (white-balance eyedropper). One undo step.
    public func setWhiteBalance(_ effect: Int, temperature: Float, tint: Float) {
        gesture { set(effect, .temperature, temperature); set(effect, .tint, tint) }
    }

    /// Premiere's Tone Reset: Exposure, Contrast, Highlights, Shadows, Whites and Blacks of one effect back to neutral
    /// (Temperature, Tint and Saturation stay). One undo step.
    public func resetTone(_ effect: Int) {
        gesture { for p in [ColorParam.exposure, .contrast, .highlights, .shadows, .whites, .blacks] { set(effect, p, p.neutral) } }
    }

    /// Writes the result of Auto (Exposure and Blacks). One undo step.
    public func setAutoTone(_ effect: Int, _ b: BasicCorrection) {
        gesture { set(effect, .exposure, b.exposure); set(effect, .blacks, b.blacks) }
    }

    /// Basic Correction's Auto was pressed for this effect; the host analyses the Program frame.
    public var onAutoTone: ((Int) -> Void)?

    /// The white-balance eyedropper was pressed for this effect; the host starts the pick.
    public var onPickWhiteBalance: ((Int) -> Void)?

    /// Back to one default effect (keeps "interpret as").
    public func resetAll() {
        gesture {
            edit { c in
                let source = c.source
                c = ClipColor.default
                c.source = source
            }
        }
    }

    public func isCollapsed(_ key: ColorPanelKey) -> Bool { collapsed.contains(key) }

    public func setCollapsed(_ key: ColorPanelKey, _ on: Bool) {
        if on { collapsed.insert(key) } else { collapsed.remove(key) }
    }

    // MARK: Sliders

    public func value(_ effect: Int, _ p: ColorParam) -> Float {
        color.effect(effect).map { p.read($0) } ?? p.neutral
    }

    public func set(_ effect: Int, _ p: ColorParam, _ v: Float) {
        editEffect(effect) { p.write(v, into: &$0) }
    }

    public func resetParameter(_ effect: Int, _ p: ColorParam) { gesture { set(effect, p, p.neutral) } }

    // MARK: Wheels

    public func wheel(_ effect: Int, _ slot: ColorWheelSlot) -> (value: WheelValue, luma: Float) {
        guard let e = color.effect(effect) else { return (WheelValue(), 0) }
        switch slot {
        case .shadows: return (e.wheels.shadows, e.wheels.shadowsLuma)
        case .midtones: return (e.wheels.midtones, e.wheels.midtonesLuma)
        case .highlights: return (e.wheels.highlights, e.wheels.highlightsLuma)
        case .shadowTint: return (e.creative.shadowTint, 0)
        case .highlightTint: return (e.creative.highlightTint, 0)
        }
    }

    public func setWheel(_ effect: Int, _ slot: ColorWheelSlot, hue: Float, amount: Float) {
        let v = WheelValue(hue: hue, amount: min(max(amount, 0), 1))
        editEffect(effect) { e in
            switch slot {
            case .shadows: e.wheels.shadows = v
            case .midtones: e.wheels.midtones = v
            case .highlights: e.wheels.highlights = v
            case .shadowTint: e.creative.shadowTint = v
            case .highlightTint: e.creative.highlightTint = v
            }
        }
    }

    /// Luminance slider of a three-way wheel, -100…100.
    public func setWheelLuma(_ effect: Int, _ slot: ColorWheelSlot, _ luma: Float) {
        let l = min(max(luma, -100), 100)
        editEffect(effect) { e in
            switch slot {
            case .shadows: e.wheels.shadowsLuma = l
            case .midtones: e.wheels.midtonesLuma = l
            case .highlights: e.wheels.highlightsLuma = l
            default: break
            }
        }
    }

    public func resetWheel(_ effect: Int, _ slot: ColorWheelSlot) {
        gesture {
            setWheel(effect, slot, hue: 0, amount: 0)
            if slot.hasLuma { setWheelLuma(effect, slot, 0) }
        }
    }

    // MARK: Curves

    public func curves(_ effect: Int) -> RGBCurves { color.effect(effect)?.curves ?? RGBCurves() }

    public func setCurves(_ effect: Int, _ curves: RGBCurves) {
        editEffect(effect) { $0.curves = curves }
    }

    // MARK: Hue Saturation Curves

    public func hueCurve(_ effect: Int, _ kind: HueCurveKind) -> [CurvePoint] {
        kind.points(color.effect(effect)?.hueCurves ?? HueCurves())
    }

    public func setHueCurve(_ effect: Int, _ kind: HueCurveKind, _ pts: [CurvePoint]) {
        editEffect(effect) { kind.set(pts, in: &$0.hueCurves) }
    }

    /// Resets one hue curve to the flat middle line. One undo step.
    public func resetHueCurve(_ effect: Int, _ kind: HueCurveKind) {
        gesture { setHueCurve(effect, kind, HueCurves.flat) }
    }

    // MARK: LUTs (Input LUT and Creative look)

    public func lutChoice(_ effect: Int, _ slot: ColorLUTSlot) -> LUTChoice? {
        guard let e = color.effect(effect) else { return nil }
        let ref: LUTRef? = slot == .input ? e.inputLUT : e.creative.look
        return ref.map(choice)
    }

    /// Sets the Input LUT (nil = none: built-in conversion in the first effect) or the Creative look (nil = none).
    public func setLUT(_ effect: Int, _ slot: ColorLUTSlot, _ c: LUTChoice?) {
        let r = c.flatMap(ref)
        if let path = c?.filePath { recents.add(path); recentLUTs = recents.paths }
        gesture {
            editEffect(effect) { e in
                switch slot {
                case .input: e.inputLUT = r
                case .look: e.creative.look = r == .automatic ? nil : r
                }
            }
        }
    }

    /// The looks the Creative popup and its arrows cycle through (after "None"): the host's LUT files, then recents.
    public var lookChoices: [LUTChoice] {
        var seen = Set<String>(), out: [LUTChoice] = []
        for c in availableLUTs + recentLUTs.map(LUTChoice.file) where c.filePath != nil && seen.insert(c.id).inserted { out.append(c) }
        return out
    }

    /// Steps the Creative look to the previous/next entry of [None] + looks (wraps around). One undo step.
    public func cycleLook(_ effect: Int, by delta: Int) {
        var list: [LUTChoice?] = [nil] + lookChoices
        let current = lutChoice(effect, .look)
        if let current, !list.contains(where: { $0 == current }) { list.append(current) }
        let i = list.firstIndex { $0 == current } ?? 0
        let next = ((i + delta) % list.count + list.count) % list.count
        setLUT(effect, .look, list[next])
    }

    private func choice(_ r: LUTRef) -> LUTChoice {
        switch r {
        case .automatic: .automatic
        case .embedded: .embedded(name: embeddedLUTName ?? "Camera LUT")
        case .file(let p): .file(p)
        }
    }

    private func ref(_ c: LUTChoice) -> LUTRef? {
        if c.id == LUTChoice.automatic.id { return .automatic }
        if c.id == "embedded" { return mediaID.map { .embedded($0) } }
        return c.filePath.map { .file($0) }
    }
}

extension ColorSpaceID {
    init(_ s: SourceColorSpace) {
        switch s {
        case .rec709: self = .rec709
        case .sLog3SGamut3Cine: self = .sLog3SGamut3Cine
        case .hlgBT2020: self = .hlgBT2020
        }
    }
}

/// The LUT files this user picked last (most recent first), kept across launches.
public final class RecentLUTs: @unchecked Sendable {
    public static let shared = RecentLUTs(defaults: .standard)
    static let key = "colorRecentLUTs"
    static let limit = 8

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return defaults.stringArray(forKey: Self.key) ?? []
    }

    public func add(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        var p = defaults.stringArray(forKey: Self.key) ?? []
        p.removeAll { $0 == path }
        p.insert(path, at: 0)
        defaults.set(Array(p.prefix(Self.limit)), forKey: Self.key)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key)
    }
}
