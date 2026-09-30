import Foundation
import Observation
import SSCore
import SSRender

/// One slider of the colour panel: title, range, neutral value and where it lives in a section's parameters.
/// Ranges and neutrals follow Lumetri (docs/DECISIONS.md 2026-10-01).
public enum ColorParam: Int, CaseIterable, Sendable {
    // Basic Correction
    case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance
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
        case .lookIntensity: "Intensity"
        case .fadedFilm: "Faded Film"
        case .tintBalance: "Tint Balance"
        case .vignetteAmount: "Amount"
        case .vignetteMidpoint: "Midpoint"
        case .vignetteRoundness: "Roundness"
        case .vignetteFeather: "Feather"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .exposure, .vignetteAmount: -5...5
        case .saturation, .creativeSaturation, .wheelsSaturation: 0...200
        case .lookIntensity, .fadedFilm, .vignetteMidpoint, .vignetteFeather: 0...100
        default: -100...100
        }
    }

    public var neutral: Float {
        switch self {
        case .saturation, .creativeSaturation, .wheelsSaturation, .lookIntensity: 100
        case .vignetteMidpoint, .vignetteFeather: 50
        default: 0
        }
    }

    public var decimals: Int { self == .exposure || self == .vignetteAmount ? 2 : 0 }

    /// Sliders of each block in display order; `nil` separators are group gaps in the UI.
    public static func layout(for kind: ColorSectionKind) -> [(group: String?, params: [ColorParam])] {
        switch kind {
        case .basicCorrection:
            [("White Balance", [.temperature, .tint]),
             ("Tone", [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]),
             (nil, [.saturation, .vibrance])]
        case .creative: [(nil, [.lookIntensity]), ("Adjustments", [.fadedFilm, .creativeVibrance, .creativeSaturation])]
        case .wheels: [(nil, [.wheelsSaturation])]
        case .vignette: [(nil, [.vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather])]
        case .inputLUT, .curves: []
        }
    }

    public func read(_ p: ColorSectionParams) -> Float? {
        switch (self, p) {
        case (.temperature, .basic(let b)): b.temperature
        case (.tint, .basic(let b)): b.tint
        case (.exposure, .basic(let b)): b.exposure
        case (.contrast, .basic(let b)): b.contrast
        case (.highlights, .basic(let b)): b.highlights
        case (.shadows, .basic(let b)): b.shadows
        case (.whites, .basic(let b)): b.whites
        case (.blacks, .basic(let b)): b.blacks
        case (.saturation, .basic(let b)): b.saturation
        case (.vibrance, .basic(let b)): b.vibrance
        case (.lookIntensity, .creative(let c)): c.intensity
        case (.fadedFilm, .creative(let c)): c.fadedFilm
        case (.creativeVibrance, .creative(let c)): c.vibrance
        case (.creativeSaturation, .creative(let c)): c.saturation
        case (.tintBalance, .creative(let c)): c.tintBalance
        case (.wheelsSaturation, .wheels(let w)): w.saturation
        case (.vignetteAmount, .vignette(let v)): v.amount
        case (.vignetteMidpoint, .vignette(let v)): v.midpoint
        case (.vignetteRoundness, .vignette(let v)): v.roundness
        case (.vignetteFeather, .vignette(let v)): v.feather
        default: nil
        }
    }

    /// Clamps to `range` and writes; returns false when the parameter does not belong to `p`.
    @discardableResult
    public func write(_ value: Float, into p: inout ColorSectionParams) -> Bool {
        let v = min(max(value, range.lowerBound), range.upperBound)
        switch p {
        case .basic(var b):
            switch self {
            case .temperature: b.temperature = v
            case .tint: b.tint = v
            case .exposure: b.exposure = v
            case .contrast: b.contrast = v
            case .highlights: b.highlights = v
            case .shadows: b.shadows = v
            case .whites: b.whites = v
            case .blacks: b.blacks = v
            case .saturation: b.saturation = v
            case .vibrance: b.vibrance = v
            default: return false
            }
            p = .basic(b)
        case .creative(var c):
            switch self {
            case .lookIntensity: c.intensity = v
            case .fadedFilm: c.fadedFilm = v
            case .creativeVibrance: c.vibrance = v
            case .creativeSaturation: c.saturation = v
            case .tintBalance: c.tintBalance = v
            default: return false
            }
            p = .creative(c)
        case .wheels(var w):
            guard self == .wheelsSaturation else { return false }
            w.saturation = v
            p = .wheels(w)
        case .vignette(var g):
            switch self {
            case .vignetteAmount: g.amount = v
            case .vignetteMidpoint: g.midpoint = v
            case .vignetteRoundness: g.roundness = v
            case .vignetteFeather: g.feather = v
            default: return false
            }
            p = .vignette(g)
        case .inputLUT, .curves: return false
        }
        return true
    }
}

/// A colour wheel in the panel: the three wheels of a Color Wheels block, or the tints of a Creative block.
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

/// State of the Color inspector for one clip: the clip's `ClipColor` plus UI-only state (which blocks are open).
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

    public private(set) var color = ClipColor.default
    /// Blocks that are collapsed (UI state, not stored in the clip). Blocks start expanded.
    public private(set) var collapsed: Set<Int> = []

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

    public init() {}

    public func clipColor() -> ClipColor { color }

    private func notify() { if !loading { onChange?(color) } }

    /// Applies an edit to the clip colour and reports it when something changed.
    private func edit(_ body: (inout ClipColor) -> Void) {
        var c = color
        body(&c)
        guard c != color else { return }
        color = c
        notify()
    }

    private func editSection(_ id: Int, _ body: (inout ColorSection) -> Void) {
        edit { c in
            guard let i = c.sections.firstIndex(where: { $0.id == id }) else { return }
            body(&c.sections[i])
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
        let ids = Set(color.sections.map(\.id))
        if !collapsed.isSubset(of: ids) { collapsed = collapsed.intersection(ids) }
    }

    // MARK: Source

    public func setSourceOverride(_ id: ColorSpaceID?) { edit { $0.source = id } }

    // MARK: Structure (add, remove, reorder, enable, collapse)

    public var sections: [ColorSection] { color.sections }

    public func addSection(_ kind: ColorSectionKind) {
        gesture { edit { _ = $0.addSection(kind) } }
    }

    public func removeSection(_ id: Int) {
        gesture { edit { $0.removeSection(id) } }
    }

    /// Moves a block so it ends at list index `destination` (index after the block is taken out).
    public func moveSection(_ id: Int, to destination: Int) {
        gesture { edit { $0.moveSection(id, to: destination) } }
    }

    public func moveSection(_ id: Int, by delta: Int) {
        guard let i = color.sections.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard target >= 0, target < color.sections.count else { return }
        moveSection(id, to: target)
    }

    public func setEnabled(_ id: Int, _ on: Bool) {
        gesture { editSection(id) { $0.enabled = on } }
    }

    public func isEnabled(_ id: Int) -> Bool { color.section(id)?.enabled ?? false }

    public func resetSection(_ id: Int) {
        gesture { edit { $0.resetSection(id) } }
    }

    /// Back to the default stack (keeps "interpret as").
    public func resetAll() {
        gesture {
            edit { c in
                let source = c.source
                c = ClipColor.default
                c.source = source
            }
        }
    }

    public func isCollapsed(_ id: Int) -> Bool { collapsed.contains(id) }

    public func setCollapsed(_ id: Int, _ on: Bool) {
        if on { collapsed.insert(id) } else { collapsed.remove(id) }
    }

    // MARK: Sliders

    public func value(_ id: Int, _ p: ColorParam) -> Float {
        color.section(id).flatMap { p.read($0.params) } ?? p.neutral
    }

    public func set(_ id: Int, _ p: ColorParam, _ v: Float) {
        editSection(id) { _ = p.write(v, into: &$0.params) }
    }

    public func resetParameter(_ id: Int, _ p: ColorParam) { gesture { set(id, p, p.neutral) } }

    // MARK: Wheels

    public func wheel(_ id: Int, _ slot: ColorWheelSlot) -> (value: WheelValue, luma: Float) {
        switch color.section(id)?.params {
        case .wheels(let w)?:
            switch slot {
            case .shadows: return (w.shadows, w.shadowsLuma)
            case .midtones: return (w.midtones, w.midtonesLuma)
            case .highlights: return (w.highlights, w.highlightsLuma)
            default: return (WheelValue(), 0)
            }
        case .creative(let c)?:
            switch slot {
            case .shadowTint: return (c.shadowTint, 0)
            case .highlightTint: return (c.highlightTint, 0)
            default: return (WheelValue(), 0)
            }
        default: return (WheelValue(), 0)
        }
    }

    public func setWheel(_ id: Int, _ slot: ColorWheelSlot, hue: Float, amount: Float) {
        let v = WheelValue(hue: hue, amount: min(max(amount, 0), 1))
        editSection(id) { s in
            switch s.params {
            case .wheels(var w):
                switch slot {
                case .shadows: w.shadows = v
                case .midtones: w.midtones = v
                case .highlights: w.highlights = v
                default: return
                }
                s.params = .wheels(w)
            case .creative(var c):
                switch slot {
                case .shadowTint: c.shadowTint = v
                case .highlightTint: c.highlightTint = v
                default: return
                }
                s.params = .creative(c)
            default: break
            }
        }
    }

    /// Luminance slider of a three-way wheel, -100…100.
    public func setWheelLuma(_ id: Int, _ slot: ColorWheelSlot, _ luma: Float) {
        let l = min(max(luma, -100), 100)
        editSection(id) { s in
            guard case .wheels(var w) = s.params else { return }
            switch slot {
            case .shadows: w.shadowsLuma = l
            case .midtones: w.midtonesLuma = l
            case .highlights: w.highlightsLuma = l
            default: return
            }
            s.params = .wheels(w)
        }
    }

    public func resetWheel(_ id: Int, _ slot: ColorWheelSlot) {
        gesture {
            setWheel(id, slot, hue: 0, amount: 0)
            if slot.hasLuma { setWheelLuma(id, slot, 0) }
        }
    }

    // MARK: Curves

    public func curves(_ id: Int) -> RGBCurves {
        if case .curves(let c)? = color.section(id)?.params { return c }
        return RGBCurves()
    }

    public func setCurves(_ id: Int, _ curves: RGBCurves) {
        editSection(id) { if case .curves = $0.params { $0.params = .curves(curves) } }
    }

    // MARK: LUTs (Input LUT and Creative look)

    public func lutChoice(_ id: Int) -> LUTChoice? {
        let ref: LUTRef?
        switch color.section(id)?.params {
        case .inputLUT(let r)?: ref = r
        case .creative(let c)?: ref = c.look
        default: return nil
        }
        return ref.map(choice)
    }

    /// Sets the Input LUT (nil = none: built-in conversion) or the Creative look (nil = none).
    public func setLUT(_ id: Int, _ c: LUTChoice?) {
        let r = c.flatMap(ref)
        if let path = c?.filePath { recents.add(path); recentLUTs = recents.paths }
        gesture {
            editSection(id) { s in
                switch s.params {
                case .inputLUT: s.params = .inputLUT(r)
                case .creative(var k): k.look = r == .automatic ? nil : r; s.params = .creative(k)
                default: break
                }
            }
        }
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
