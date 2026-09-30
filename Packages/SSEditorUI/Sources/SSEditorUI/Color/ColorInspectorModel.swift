import Foundation
import Observation
import SSRender

/// State of the Properties/Color inspector. Sections follow the processing order (DECISIONS: Correction → Conversion LUT →
/// Creative LUT). Builds the `ColorCorrection` value and reports changes; bypass keeps the values but neutralises the section.
@MainActor @Observable
public final class ColorInspectorModel {
    public enum Section: Int, CaseIterable, Sendable {
        case source, correction, conversionLUT, creativeLUT
        public var title: String {
            switch self {
            case .source: "Source"
            case .correction: "Correction"
            case .conversionLUT: "Conversion LUT"
            case .creativeLUT: "Creative LUT"
            }
        }
        /// Source/Interpret is not an effect and cannot be bypassed.
        public var canBypass: Bool { self != .source }
    }

    public enum Parameter: Int, CaseIterable, Sendable {
        case temperature, tint, exposure, contrast, highlights, shadows, saturation
        public var title: String {
            switch self {
            case .temperature: "Temperature"
            case .tint: "Tint"
            case .exposure: "Exposure"
            case .contrast: "Contrast"
            case .highlights: "Highlights"
            case .shadows: "Shadows"
            case .saturation: "Saturation"
            }
        }
        /// Ranges from ColorCorrection / docs/PHASE3.md.
        public var range: ClosedRange<Float> {
            switch self {
            case .exposure: -4...4
            case .saturation: 0...200
            default: -100...100
            }
        }
        public var neutral: Float { self == .saturation ? 100 : 0 }
    }

    public enum WheelID: Int, CaseIterable, Sendable { case shadows, midtones, highlights }

    /// Hue/amount from `ColorWheelMath` plus the master (luma) slider, -1…1.
    public struct WheelState: Sendable, Equatable {
        public var hue: Double = 0
        public var amount: Double = 0
        public var master: Double = 0
        public init() {}
    }

    public struct LUTChoice: Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// What the renderer needs. Bypassed sections are already neutralised.
    public struct State: Sendable, Equatable {
        public var source: SourceColorSpace
        public var correction: ColorCorrection
        public var conversionLUT: LUTChoice?
        public var creativeLUT: LUTChoice?
        public var creativeIntensity: Float
    }

    public var source: SourceColorSpace = .rec709 { didSet { if source != oldValue { notify() } } }
    public private(set) var correction = ColorCorrection.neutral
    public var conversionLUT: LUTChoice? { didSet { if conversionLUT != oldValue { notify() } } }
    public var creativeLUT: LUTChoice? { didSet { if creativeLUT != oldValue { notify() } } }
    /// 0…1.
    public var creativeIntensity: Float = 1 {
        didSet {
            let c = min(max(creativeIntensity, 0), 1)
            if c != creativeIntensity { creativeIntensity = c } else if c != oldValue { notify() }
        }
    }
    public private(set) var bypassed: Set<Section> = []
    public private(set) var wheels: [WheelID: WheelState] = [:]

    /// Available LUTs for the popups (set by the host from the Library).
    public var availableLUTs: [LUTChoice] = []

    public var onChange: ((State) -> Void)?
    /// One undo step per gesture: begin → change* → end.
    public var onGestureBegan: (() -> Void)?
    public var onGestureEnded: (() -> Void)?

    public init() {}

    public var state: State {
        State(source: source,
              correction: isBypassed(.correction) ? .neutral : correction,
              conversionLUT: isBypassed(.conversionLUT) ? nil : conversionLUT,
              creativeLUT: isBypassed(.creativeLUT) ? nil : creativeLUT,
              creativeIntensity: creativeIntensity)
    }

    private func notify() { onChange?(state) }

    // MARK: Correction

    public func value(_ p: Parameter) -> Float {
        switch p {
        case .temperature: correction.temperature
        case .tint: correction.tint
        case .exposure: correction.exposure
        case .contrast: correction.contrast
        case .highlights: correction.highlights
        case .shadows: correction.shadows
        case .saturation: correction.saturation
        }
    }

    public func set(_ p: Parameter, _ v: Float) {
        let c = min(max(v, p.range.lowerBound), p.range.upperBound)
        guard c != value(p) else { return }
        switch p {
        case .temperature: correction.temperature = c
        case .tint: correction.tint = c
        case .exposure: correction.exposure = c
        case .contrast: correction.contrast = c
        case .highlights: correction.highlights = c
        case .shadows: correction.shadows = c
        case .saturation: correction.saturation = c
        }
        notify()
    }

    public func resetParameter(_ p: Parameter) { gesture { set(p, p.neutral) } }

    // MARK: Bypass / reset

    public func isBypassed(_ s: Section) -> Bool { bypassed.contains(s) }

    public func setBypassed(_ s: Section, _ on: Bool) {
        guard s.canBypass, on != bypassed.contains(s) else { return }
        if on { bypassed.insert(s) } else { bypassed.remove(s) }
        notify()
    }

    public func reset(_ s: Section) {
        gesture {
            switch s {
            case .source: source = .rec709
            case .correction:
                correction = .neutral
                wheels = [:]
                bypassed.remove(.correction)
                notify()
            case .conversionLUT:
                bypassed.remove(.conversionLUT)
                conversionLUT = nil
                notify()
            case .creativeLUT:
                bypassed.remove(.creativeLUT)
                creativeLUT = nil
                creativeIntensity = 1
                notify()
            }
        }
    }

    public func resetAll() {
        gesture { Section.allCases.forEach { s in reset(s) } }
    }

    private var gestureDepth = 0

    /// Wraps a discrete edit (reset, popup choice) as one undo step; nested calls collapse into the outermost.
    public func gesture(_ body: () -> Void) {
        if gestureDepth == 0 { onGestureBegan?() }
        gestureDepth += 1
        body()
        gestureDepth -= 1
        if gestureDepth == 0 { onGestureEnded?() }
    }

    // MARK: Wheels (UI state until ColorCorrection grows wheel parameters)

    public func wheel(_ id: WheelID) -> WheelState { wheels[id] ?? WheelState() }

    public func setWheel(_ id: WheelID, hue: Double, amount: Double) {
        var w = wheel(id)
        w.hue = hue
        w.amount = min(max(amount, 0), 1)
        wheels[id] = w
        notify()
    }

    public func setWheelMaster(_ id: WheelID, _ v: Double) {
        var w = wheel(id)
        w.master = min(max(v, -1), 1)
        wheels[id] = w
        notify()
    }

    public func resetWheel(_ id: WheelID) { gesture { wheels[id] = WheelState(); notify() } }
}
