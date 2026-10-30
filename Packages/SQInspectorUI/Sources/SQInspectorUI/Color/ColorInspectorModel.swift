import SQUIKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Observation
import SQCore
import SQLibrary
import SQRender

/// One slider of the color panel: title, range, neutral value and where it lives in a Color effect.
/// Ranges and neutrals follow Lumetri (the design notes 2026-10-01).
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
        case .fadedFilm: "Fade"
        case .tintBalance: "Tint Mix"
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

    /// The two-color track behind the slider (Temperature blue -> orange, Tint green -> magenta).
    public enum Track: Sendable { case plain, temperature, tint, saturation }
    public var track: Track {
        switch self {
        case .temperature: .temperature
        case .tint: .tint
        case .saturation, .vibrance, .creativeVibrance: .saturation
        default: .plain
        }
    }

    /// Rows of each section in display order (version 9: Basic is Temperature, Tint, Exposure, Contrast, Highlights,
    /// Shadows; Creative is Vibrance, Saturation, Fade). The rows version 9 does not have follow at the end of their
    /// section. The LUT pills, intensities, the White Balance picker and the wheels are added by the view around these.
    public static func layout(for kind: ColorSectionKind) -> [(group: String?, params: [ColorParam])] {
        switch kind {
        case .basicCorrection:
            [("Color", [.temperature, .tint]),
             ("Light", [.exposure, .contrast, .highlights, .shadows, .whites, .blacks, .saturation, .vibrance])]
        case .creative: [("Adjustments", [.creativeVibrance, .creativeSaturation, .fadedFilm, .tintBalance])]
        case .wheels: [(nil, [.wheelsSaturation])]
        case .vignette: [(nil, [.vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather])]
        case .curves, .hslSecondary, .zoneBoard: []
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
    /// One line on what the curve reads and changes (shown as the tooltip of the curve plot and its popup).
    public var explanation: String {
        switch self {
        case .hueVsSat: "Hue vs Sat: raise or lower the saturation of one hue. The x axis is the hue, the middle line is no change."
        case .hueVsHue: "Hue vs Hue: shift one hue towards its neighbors. The x axis is the hue, the middle line is no change."
        case .hueVsLuma: "Hue vs Luma: brighten or darken one hue. The x axis is the hue, the middle line is no change."
        case .lumaVsSat: "Luma vs Sat: change the saturation of shadows, midtones or highlights. The x axis is brightness."
        case .satVsSat: "Sat vs Sat: change colors by how saturated they already are. The x axis is saturation."
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
    /// Hue-keyed curves wrap around the color wheel, so their first and last point are the same place: when one of
    /// them moved vertically the other follows (an edit of the last point wins when both changed).
    public func wrapped(_ pts: [CurvePoint], previous old: [CurvePoint]) -> [CurvePoint] {
        var new = pts
        guard isHueKeyed, new.count >= 2 else { return new }
        if let lo = old.first, let hi = old.last, old.count >= 2 {
            if new[new.count - 1].y != hi.y { new[0].y = new[new.count - 1].y }
            else if new[0].y != lo.y { new[new.count - 1].y = new[0].y }
        } else { new[new.count - 1].y = new[0].y }
        return new
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

/// A color wheel in the panel: the three wheels of Color Wheels, or the tints of Creative.
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

extension ColorParam {
    /// The Color effect parameter this slider writes (`ClipEffect.color…Key`).
    public var parameterKey: String {
        typealias K = ClipEffect
        switch self {
        case .temperature: return K.colorTemperatureKey
        case .tint: return K.colorTintKey
        case .exposure: return K.colorExposureKey
        case .contrast: return K.colorContrastKey
        case .highlights: return K.colorHighlightsKey
        case .shadows: return K.colorShadowsKey
        case .whites: return K.colorWhitesKey
        case .blacks: return K.colorBlacksKey
        case .saturation: return K.colorSaturationKey
        case .vibrance: return K.colorVibranceKey
        case .inputLUTIntensity: return K.colorInputLUTIntensityKey
        case .lookIntensity: return K.colorLookIntensityKey
        case .fadedFilm: return K.colorFadedFilmKey
        case .creativeVibrance: return K.colorCreativeVibranceKey
        case .creativeSaturation: return K.colorCreativeSaturationKey
        case .tintBalance: return K.colorTintBalanceKey
        case .wheelsSaturation: return K.colorWheelSaturationKey
        case .vignetteAmount: return K.colorVignetteAmountKey
        case .vignetteMidpoint: return K.colorVignetteMidpointKey
        case .vignetteRoundness: return K.colorVignetteRoundnessKey
        case .vignetteFeather: return K.colorVignetteFeatherKey
        }
    }

    /// Unambiguous name for tooltips and undo ("Animate Look Intensity"): the row titles repeat across sections.
    public var keyframeName: String {
        switch self {
        case .inputLUTIntensity: "Source LUT Intensity"
        case .lookIntensity: "Look Intensity"
        case .creativeVibrance: "Creative Vibrance"
        case .creativeSaturation: "Creative Saturation"
        case .wheelsSaturation: "Wheels Saturation"
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather: "Vignette \(title)"
        default: title
        }
    }
}

extension ColorWheelSlot {
    /// The parameters the wheel's keyframe control animates together: hue, amount and (three-way wheels) luma.
    public var parameterKeys: [String] {
        typealias K = ClipEffect
        switch self {
        case .shadows: return [K.colorWheelShadowsHueKey, K.colorWheelShadowsAmountKey, K.colorWheelShadowsLumaKey]
        case .midtones: return [K.colorWheelMidtonesHueKey, K.colorWheelMidtonesAmountKey, K.colorWheelMidtonesLumaKey]
        case .highlights: return [K.colorWheelHighlightsHueKey, K.colorWheelHighlightsAmountKey, K.colorWheelHighlightsLumaKey]
        case .shadowTint: return [K.colorShadowTintHueKey, K.colorShadowTintAmountKey]
        case .highlightTint: return [K.colorHighlightTintHueKey, K.colorHighlightTintAmountKey]
        }
    }
}

/// What one keyframe control of the Color panel animates (INTERACTION-AUDIT §2): a slider, or a wheel whose
/// parameters key together.
public enum ColorKeyTarget: Hashable, Sendable {
    case param(ColorParam)
    case wheel(ColorWheelSlot)

    public var parameterKeys: [String] {
        switch self {
        case .param(let p): [p.parameterKey]
        case .wheel(let w): w.parameterKeys
        }
    }

    public var name: String {
        switch self {
        case .param(let p): p.keyframeName
        case .wheel(let w): w.hasLuma ? "\(w.title) Wheel" : w.title
        }
    }

    public static let all: [ColorKeyTarget] =
        ColorParam.allCases.map { .param($0) } + ColorWheelSlot.allCases.map { .wheel($0) }

    /// States of every animated control of `clip` (the rest are `.off`). `local` = the clip-local playhead time.
    /// `local` is the playhead minus the clip start (not clamped onto the clip).
    public static func states(of clip: Clip?, local: Time, playheadInRange: Bool) -> [ColorKeyID: KeyframeControlState] {
        guard let clip else { return [:] }
        var out: [ColorKeyID: KeyframeControlState] = [:]
        for n in 1...max(clip.colorGradeEffects.count, 1) {
            for t in all {
                guard clip.isColorAnimated(effect: n, keys: t.parameterKeys) else { continue }
                let times = navigableTimes(clip, effect: n, target: t)
                out[ColorKeyID(effect: n, target: t)] = .resolve(
                    animated: true, onKey: times.contains(local), hasPrevious: times.contains { $0 < local },
                    hasNext: times.contains { $0 > local }, playheadInRange: playheadInRange)
            }
        }
        return out
    }

    /// The key times Previous/Next can go to: those on the clip's frames (keys past a trim are skipped).
    public static func navigableTimes(_ clip: Clip, effect n: Int, target t: ColorKeyTarget) -> [Time] {
        clip.colorKeyTimes(effect: n, keys: t.parameterKeys).filter { $0 >= .zero && $0 < clip.duration }
    }
}

/// One keyframe control: Color effect `effect` (inspector id, 1-based) and what it animates.
public struct ColorKeyID: Hashable, Sendable {
    public var effect: Int
    public var target: ColorKeyTarget
    public init(effect: Int, target: ColorKeyTarget) { self.effect = effect; self.target = target }
}

/// A click on a keyframe control: the ring, the diamond, or previous / next key.
public enum ColorKeyAction: Sendable, Equatable { case toggleAnimation, toggleKey, previous, next }

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

        /// A choice is its id: the embedded entry's name follows the media info, which may be absent for a moment while the
        /// panel refreshes, and must not make the same LUT look like a different one (the popup flipped to "Automatic").
        public static func == (a: LUTChoice, b: LUTChoice) -> Bool { a.id == b.id }
        public func hash(into h: inout Hasher) { h.combine(id) }

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
    /// The clip's media info as loaded (for the effective source under the project input default).
    public private(set) var mediaInfo: MediaInfo?
    /// Why the eyedropper and Auto are unavailable (they would measure more than this clip); nil = available.
    public var samplingBlock: String?
    /// The clip's frame at the playhead (with its current look) for the Creative preview; nil = use the synthetic picture.
    #if canImport(CoreGraphics)
    public var frameThumbnail: CGImage?
    #endif

    public private(set) var color = ClipColor.default
    /// Sections and sub-groups that are collapsed (UI state, not stored in the clip).
    public private(set) var collapsed: Set<ColorPanelKey> = []
    private var knownEffects: Set<Int> = []

    /// LUT files the host offers in the popups (Library); `recent` are this user's last chosen files.
    public var availableLUTs: [LUTChoice] = []
    /// The user's LUT library (copies in App Support, favorites first); nil = none (tests, no host).
    public var lutStore: LUTLibraryStore?
    public var recents = RecentLUTs.shared
    public var recentLUTs: [String] = RecentLUTs.shared.paths

    public var onChange: ((ClipColor) -> Void)?
    /// One undo step per gesture: begin -> change* -> end.
    public var onGestureBegan: (() -> Void)?
    public var onGestureEnded: (() -> Void)?
    /// A drag was canceled (Esc): ends the gesture and withdraws everything it wrote.
    public var onGestureCancelled: (() -> Void)?

    /// Color Pro mode (ColorInspectorModel+Graph.swift): the target's Color Graph (nil: none yet), the Step the inspector
    /// shows, and the edit the host writes to `Clip.colorGraph`.
    public internal(set) var graph: ColorGraph?
    public var selectedStep: UUID? {
        didSet {
            if let s = selectedStep, !selectedSteps.contains(s) { selectedSteps = [s] } else if selectedStep == nil { selectedSteps = [] }
            if oldValue != selectedStep { onViewerAidChange?() }
        }
    }
    /// Every Step selected on the Steps canvas (Shift or Command click, rectangle); `selectedStep` is the one the inspector shows.
    public var selectedSteps: Set<UUID> = []
    public var onGraphChange: ((ColorGraph) -> Void)?
    /// View state: the Step whose name is being edited in the Steps graph (set by the Step menu's Rename).
    public var renamingStep: UUID?
    /// The mixer box selected on the Steps canvas (named by the head of its stack); nil = none.
    public var selectedMixer: UUID?
    /// View state, never saved: the Pro page shows though the clip has no Color Graph yet (its empty state offers
    /// "Start empty" and "Start from Simple grade"). Nothing is written to the clip until one of them is pressed.
    public var showsEmptyPro = false {
        didSet { if oldValue != showsEmptyPro { onGradeViewChange?() } }
    }
    public var onGradeViewChange: (() -> Void)?
    /// Viewing aid, never saved: the monitor shows where the selected Step works (its qualifier and window) as a white
    /// overlay instead of the graded picture.
    public var showsMatte = false {
        didSet { if oldValue != showsMatte { onViewerAidChange?() } }
    }
    /// The matte toggle or the selected Step changed: the host updates the monitor's matte view and window handles.
    @ObservationIgnored public var onViewerAidChange: (() -> Void)?

    private var loading = false
    private var gestureDepth = 0

    public init() { syncKnownEffects() }

    public func clipColor() -> ClipColor { color }

    /// The Sharpen row of Basic (the target's Sharpen effect, 0 = none). Not part of `ClipColor`: the host reads and
    /// writes the clip's Sharpen effect (`Clip.sharpenAmount`).
    public private(set) var sharpen: Float = 0
    public var onSharpenSet: ((Float) -> Void)?
    public func loadSharpen(_ v: Float) { if sharpen != v { sharpen = v } }
    public func setSharpen(_ v: Float) {
        let c = min(max(v, Clip.sharpenRowRange.lowerBound), Clip.sharpenRowRange.upperBound)
        guard c != sharpen else { return }
        sharpen = c
        if !loading { onSharpenSet?(c) }
    }

    private func notify() { if !loading { onChange?(color) } }

    /// Applies an edit to the clip color and reports it when something changed.
    private func edit(_ body: (inout ClipColor) -> Void) {
        var c = color
        body(&c)
        guard c != color else { return }
        color = c
        syncKnownEffects()
        notify()
    }

    func editEffect(_ id: Int, _ body: (inout ColorEffect) -> Void) {
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

    // MARK: Keyframes

    /// Keyframe control states at the playhead, set by the host (missing = not animated).
    public var keyframeStates: [ColorKeyID: KeyframeControlState] = [:]
    /// False while no keyframe control can act (nothing to grade).
    public var keyframesEnabled = true
    /// A keyframe control was clicked; the host edits the target clip.
    public var onKeyframe: ((ColorKeyAction, ColorKeyID) -> Void)?

    public func keyframeState(_ effect: Int, _ target: ColorKeyTarget) -> KeyframeControlState {
        keyframeStates[ColorKeyID(effect: effect, target: target)] ?? .off
    }

    public func keyframe(_ action: ColorKeyAction, _ effect: Int, _ target: ColorKeyTarget) {
        onKeyframe?(action, ColorKeyID(effect: effect, target: target))
    }

    // MARK: Clip.color bridge

    /// Shows `color` (no callbacks fire). `info` = the clip's media, for the detected source and the embedded LUT.
    public func load(_ color: ClipColor, mediaID: UUID?, info: MediaInfo?) {
        loading = true
        defer { loading = false }
        if self.color != color { self.color = color }
        self.mediaID = mediaID
        detectedSource = info?.colorSpace ?? .rec709
        if mediaInfo != info { mediaInfo = info }
        embeddedLUTName = info?.embeddedLUTName
        syncKnownEffects()
    }

    /// Forgets UI state of effects that are gone; the first time an effect is shown Basic, Look and Curves are open
    /// and the rest closed (design board Color).
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

    public var logMode: LogMode { color.logMode }
    public var targetSpace: TargetSpace { color.targetSpace }
    public var hdrConform: Bool { color.hdrConform }
    public func setLogMode(_ m: LogMode) { gesture { edit { $0.logMode = m } } }
    public func setTargetSpace(_ t: TargetSpace) { gesture { edit { $0.targetSpace = t } } }
    public func setHDRConform(_ on: Bool) { gesture { edit { $0.hdrConform = on } } }

    // MARK: Effects and sections

    public var effects: [ColorEffect] { color.effects }

    /// Adds another Color effect (Premiere: add another Lumetri Color). One undo step.
    public func addEffect() {
        gesture { edit { _ = $0.addEffect() } }
    }

    public func removeEffect(_ id: Int) {
        gesture { edit { $0.removeEffect(id) } }
    }

    public func setEnabled(_ effect: Int, _ kind: ColorSectionKind, _ on: Bool) {
        gesture { editEffect(effect) { $0.setEnabled(kind, on) } }
    }

    public func isEnabled(_ effect: Int, _ kind: ColorSectionKind) -> Bool {
        color.effect(effect)?.isEnabled(kind) ?? false
    }

    public func resetSection(_ effect: Int, _ kind: ColorSectionKind) {
        gesture { edit { $0.resetSection(kind, in: effect) } }
    }

    /// Whether "Reset <section>" is offered enabled: always for the slider sections (as before); Color Range only when
    /// the effect holds a range (its reset removes it).
    public func canResetSection(_ effect: Int, _ kind: ColorSectionKind) -> Bool {
        if kind == .hslSecondary { return colorRange(effect) != nil }
        return true
    }

    /// The section resets of the effect's more-actions menu, in panel order (Basic … Vignette, Color Range included).
    public func sectionResets(_ effect: Int) -> [(kind: ColorSectionKind, title: String, enabled: Bool)] {
        ColorSectionKind.allCases.map { ($0, "Reset \($0.title)", canResetSection(effect, $0)) }
    }

    /// Premiere's per-effect Reset: every section of one Color effect back to its defaults (toggles stay). One undo step.
    public func resetEffect(_ effect: Int) {
        gesture { for k in ColorSectionKind.allCases { edit { $0.resetSection(k, in: effect) } } }
    }

    /// Sets Temperature and Tint together (white-balance eyedropper). One undo step.
    public func setWhiteBalance(_ effect: Int, temperature: Float, tint: Float) {
        gesture { set(effect, .temperature, temperature); set(effect, .tint, tint) }
    }

    /// Premiere's Tone Reset: Exposure, Contrast, Highlights, Shadows, Whites and Blacks of one effect back to neutral
    /// (Temperature, Tint and Saturation stay). One undo step. Like the section reset it moves a legacy effect to the
    /// current tone maths (the tone sliders are neutral, so nothing visible changes).
    public func resetTone(_ effect: Int) {
        gesture {
            for p in [ColorParam.exposure, .contrast, .highlights, .shadows, .whites, .blacks] { set(effect, p, p.neutral) }
            editEffect(effect) { $0.basic.model = .current }
        }
    }

    /// Writes the result of Auto Tone (Exposure, Contrast, Whites, Blacks, Temperature, Tint; Highlights, Shadows and
    /// Saturation stay). One undo step.
    public func setAutoTone(_ effect: Int, _ b: BasicCorrection) {
        gesture {
            set(effect, .exposure, b.exposure); set(effect, .contrast, b.contrast)
            set(effect, .whites, b.whites); set(effect, .blacks, b.blacks)
            set(effect, .temperature, b.temperature); set(effect, .tint, b.tint)
        }
    }

    /// Copy / Paste buttons of the panel (the host owns the clipboard and the selection).
    public var onCopyColor: (() -> Void)?
    public var onPasteColor: (() -> Void)?

    /// COLOR-GRADE-LINKS, set by the host: clip-local range text per range grade (effect id), and how many clips share
    /// this clip's grade (0 = not linked).
    public var effectRangeLabels: [Int: String] = [:]
    public var linkedClipCount = 0
    /// "Grade Whole Sequence" in the panel's menu.
    public var onGradeWholeSequence: (() -> Void)?
    /// Link, range and unlink actions of the panel menu; the host owns the selection and the session.
    public var onGradeAction: ((ColorGradeAction) -> Void)?

    /// The title of an effect's header row: "Color", "Color 2", plus its range or the link.
    public func effectTitle(_ effect: Int, number: Int) -> String {
        var t = number == 1 ? "Color" : "Color \(number)"
        if let r = effectRangeLabels[effect] { t += "  \u{00B7}  \(r)" }
        if number == 1, linkedClipCount > 1 { t += "  \u{00B7}  Linked (\(linkedClipCount))" }
        return t
    }

    /// Basic Correction's Auto was pressed for this effect; the host analyzes the Program frame.
    public var onAutoTone: ((Int) -> Void)?

    /// The white-balance eyedropper was pressed for this effect; the host starts the pick.
    public var onPickWhiteBalance: ((Int) -> Void)?

    /// The host's Reset (removes the clip's Color effects with their keys). When set, `resetAll` calls it instead of
    /// editing the shown values.
    public var onResetAll: (() -> Void)?

    /// W9.3: the project's camera input color space (`Project.inputColorSpace`), set by the host; nil = none.
    public var projectInput: ColorSpaceID?
    /// The host sets the project input (one undo step); the new value comes back through `projectInput`.
    public var onProjectInputChange: ((ColorSpaceID?) -> Void)?
    public func setProjectInput(_ space: ColorSpaceID?) { onProjectInputChange?(space) }

    /// The source color space the clip renders with: the clip's override, else the media's detection under the project
    /// input default, else Rec.709.
    public var effectiveSource: ColorSpaceID {
        color.source ?? mediaInfo?.applyingProjectInput(projectInput).colorSpace ?? .rec709
    }

    public static let autoToneHelp = "Set Exposure, Contrast, Whites, Blacks and a mild white balance from the Program monitor picture"

    /// Why Auto Tone is unavailable for this Color effect (nil = available): the measurement block, then what the tone
    /// model cannot invert (non-Rec.709 source, Input LUT, Basic Correction off, active later sections).
    public func autoToneBlock(_ effect: Int) -> String? {
        if let samplingBlock { return samplingBlock }
        guard let e = color.effect(effect) else { return SQL10n.string("No Color effect.") }
        return AutoToneSolver.blockReason(effect: e, source: effectiveSource).map(ColorBlockText.localized)
    }

    /// Back to one default effect (keeps "interpret as").
    public func resetAll() {
        if let onResetAll { onResetAll(); return }
        gesture {
            edit { c in
                let footage = ClipFootageColor(c)
                c = ClipColor.default
                c.source = footage.source
                c.logMode = footage.logMode; c.targetSpace = footage.targetSpace; c.hdrConform = footage.hdrConform
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

    /// Writes one hue curve. Hue-keyed curves wrap around the color wheel, so their first and last point are the same
    /// place: when one of them moved vertically the other follows (an edit of the last point wins when both changed).
    public func setHueCurve(_ effect: Int, _ kind: HueCurveKind, _ pts: [CurvePoint]) {
        editEffect(effect) { e in
            kind.set(kind.wrapped(pts, previous: kind.points(e.hueCurves)), in: &e.hueCurves)
        }
    }

    /// Resets one hue curve to the flat middle line. One undo step.
    public func resetHueCurve(_ effect: Int, _ kind: HueCurveKind) {
        gesture { setHueCurve(effect, kind, HueCurves.flat) }
    }

    /// Writes the "Hold Saturation Legal" Sat vs Sat curve. One undo step.
    public func holdSaturationLegal(_ effect: Int) {
        gesture { setHueCurve(effect, .satVsSat, HueCurves.saturationHoldLegal) }
    }

    // MARK: LUTs (Input LUT and Creative look)

    /// Amber-chip text when the picked LUT file's name says it expects another color space than the clip's (nil = fits).
    public func lutMismatch(_ effect: Int, _ slot: ColorLUTSlot) -> String? {
        guard let path = lutChoice(effect, slot)?.filePath else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        // The Look slot runs after conversion to Rec.709; only an Input LUT sees the clip's own space.
        return LUTSpaceHint.mismatch(lutFileName: name, source: slot == .input ? effectiveSource : .rec709)?.message
    }

    public func lutChoice(_ effect: Int, _ slot: ColorLUTSlot) -> LUTChoice? {
        guard let e = color.effect(effect) else { return nil }
        let ref: LUTRef? = slot == .input ? e.inputLUT : e.creative.look
        return ref.map(choice).map(knownChoice)
    }

    /// A stored file path that is the project's collected copy of a known LUT is that LUT's choice, so the popup marks it
    /// and the look arrows find their place. Order: same standardized path, then same name and size (a file stat only
    /// for candidates with the same name; `sizes` caches them for one pass).
    private struct KnownLUTs {
        var items: [(choice: LUTChoice, std: String, name: String)]
        var sizes: [String: NSNumber?] = [:]
    }
    private func knownLUTs() -> KnownLUTs {
        let known = (lutStore?.entries ?? []).map { LUTChoice.file($0.path) } + availableLUTs     // not the recents: they hold copies too
        return KnownLUTs(items: known.compactMap { k in
            k.filePath.map { (k, URL(fileURLWithPath: $0).standardizedFileURL.path, URL(fileURLWithPath: $0).lastPathComponent) }
        })
    }
    private func knownChoice(_ c: LUTChoice, in known: inout KnownLUTs) -> LUTChoice {
        guard let path = c.filePath else { return c }
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if let k = known.items.first(where: { $0.std == std }) { return k.choice }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let same = known.items.filter { $0.name == name }
        guard !same.isEmpty else { return c }
        func size(_ p: String) -> NSNumber? {
            if let hit = known.sizes[p] { return hit }
            let v = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber
            known.sizes[p] = .some(v)
            return v
        }
        guard let want = size(path) else { return c }
        return same.first { $0.choice.filePath.flatMap(size) == want }?.choice ?? c
    }
    private func knownChoice(_ c: LUTChoice) -> LUTChoice { var k = knownLUTs(); return knownChoice(c, in: &k) }

    /// Sets the Input LUT (nil = none: built-in conversion in the first effect) or the Creative look (nil = none).
    /// The path is stored as picked; copying into the project happens when the project is saved.
    public func setLUT(_ effect: Int, _ slot: ColorLUTSlot, _ c: LUTChoice?) {
        let r = c.flatMap(ref)
        if let path = c?.filePath {
            recents.add(path); recentLUTs = recents.paths
        }
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
        let library = (lutStore?.entries ?? []).map { LUTChoice.file($0.path) }
        var known = knownLUTs()
        let recent = recentLUTs.map { knownChoice(.file($0), in: &known) }
        for c in library + availableLUTs + recent where c.filePath != nil && seen.insert(c.id).inserted { out.append(c) }
        return out
    }

    /// Library LUTs in display order (favorites first).
    public var libraryLUTs: [LUTEntry] { lutStore?.entries ?? [] }

    public func isFavouriteLUT(_ choice: LUTChoice) -> Bool {
        guard let path = choice.filePath else { return false }
        return libraryLUTs.contains { $0.path == path && $0.isFavourite }
    }

    /// Stars or unstars a library LUT (no-op for files outside the library).
    public func toggleFavouriteLUT(_ choice: LUTChoice) {
        guard let path = choice.filePath, let e = libraryLUTs.first(where: { $0.path == path }) else { return }
        lutStore?.toggleFavourite(e.fileName)
    }

    /// Copies the given .cube files into the library; returns the added LUTs as choices.
    @discardableResult
    public func importLUTs(_ urls: [URL]) -> [LUTChoice] {
        (lutStore?.importLUTs(urls) ?? []).map { LUTChoice.file($0.path) }
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

    func choice(_ r: LUTRef) -> LUTChoice {
        switch r {
        case .automatic: .automatic
        case .embedded: .embedded(name: embeddedLUTName ?? "Camera LUT")
        case .file(let p): .file(p)
        }
    }

    func ref(_ c: LUTChoice) -> LUTRef? {
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
        case .vLogVGamut: self = .vLogVGamut
        case .appleLog: self = .appleLog
        case .pqBT2020: self = .pqBT2020
        case .dLogDGamut: self = .dLogDGamut
        case .canonLogCinemaGamut: self = .canonLogCinemaGamut
        case .canonLogBT2020: self = .canonLogBT2020
        case .canonLogBT709: self = .canonLogBT709
        case .canonLog2CinemaGamut: self = .canonLog2CinemaGamut
        case .canonLog2BT2020: self = .canonLog2BT2020
        case .canonLog2BT709: self = .canonLog2BT709
        case .canonLog3CinemaGamut: self = .canonLog3CinemaGamut
        case .canonLog3BT2020: self = .canonLog3BT2020
        case .canonLog3BT709: self = .canonLog3BT709
        case .logC3WideGamut3: self = .logC3WideGamut3
        case .logC4WideGamut4: self = .logC4WideGamut4
        case .log3G10RedWideGamut: self = .log3G10RedWideGamut
        case .bmdFilmGen5WideGamut: self = .bmdFilmGen5WideGamut
        case .nLogBT2020: self = .nLogBT2020
        case .fLog2FGamutC: self = .fLog2FGamutC
        case .acesCCTAP1: self = .acesCCTAP1
        }
    }
}

/// Observable holder of the shared `LUTLibrary` so every color inspector refreshes when a LUT is added or starred.
@MainActor @Observable
public final class LUTLibraryStore {
    public static let shared = LUTLibraryStore(library: LUTLibrary(directory: LUTLibrary.defaultDirectory()))

    private var library: LUTLibrary
    public private(set) var entries: [LUTEntry]
    /// Set when the last add/star could not be written; the UI may show it.
    public private(set) var lastError: String?

    public init(library: LUTLibrary) {
        var lib = library
        let loadError = lib.loadError
        try? lib.pruneMissingFavourites()
        self.library = lib
        entries = lib.entries()
        lastError = loadError
    }

    /// Drops the cached look thumbnail of `path` (the Mac look previews; Windows draws no LUT thumbnails yet).
    private static func invalidatePreview(_ path: String) {
        #if canImport(AppKit)
        ColorLookPreview.invalidate(path: path)
        #endif
    }

    @discardableResult
    public func importLUTs(_ urls: [URL]) -> [LUTEntry] {
        let r = library.importLUTs(from: urls)
        lastError = r.failures.first.map { "Could not add \($0.url.lastPathComponent): \($0.message)" }
        for e in r.added { Self.invalidatePreview(e.path) }
        entries = library.entries()
        return r.added
    }

    public func toggleFavourite(_ fileName: String) {
        do { lastError = nil; try library.toggleFavourite(fileName) } catch { lastError = "\(error)" }
        entries = library.entries()
    }

    public func remove(_ fileName: String) {
        let path = library.directory.appendingPathComponent(fileName).path
        do { lastError = nil; try library.remove(fileName) } catch { lastError = "\(error)" }
        Self.invalidatePreview(path)
        entries = library.entries()
    }

    /// Re-reads the folder and drops stars of files that vanished.
    public func refresh() {
        try? library.pruneMissingFavourites()
        entries = library.entries()
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

/// Grade link and range actions of the Color panel menu (COLOR-GRADE-LINKS).
public enum ColorGradeAction: Equatable, Sendable {
    /// Link the selected clips to this clip's grade.
    case linkSelected
    /// Link every clip of this clip's media to its grade.
    case linkSource
    case unlink
    /// Add a range grade over In/Out (or playhead to clip end).
    case addRange
    /// Move effect `id`'s range to In/Out (or playhead to clip end).
    case setRangeToInOut(Int)
    /// Effect `id` grades the whole clip again.
    case wholeClip(Int)
}
