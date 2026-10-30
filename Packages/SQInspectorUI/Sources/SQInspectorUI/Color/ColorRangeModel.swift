import Foundation
import SQCore

/// One slider of the Color Range (HSL secondary) section. Not keyframable: the range lives in the effect's grade data
/// (`ColorEffect.hslSecondary`), like the curves.
public enum ColorRangeParam: Int, CaseIterable, Sendable {
    // Qualifier ("Range" group).
    case hueCenter, hueWidth, satMin, satMax, lumMin, lumMax, softness
    // Correction inside the range ("Correction" group).
    case hueShift, saturation, exposure, temperature, tint
    // Color-volume mask (v94): the ball's saturation, luma and radius (its hue is `hueCenter`).
    case volumeSat, volumeLum, volumeRadius

    public var title: String {
        switch self {
        case .hueCenter: "Hue"
        case .hueWidth: "Hue Width"
        case .satMin: "Sat Min"
        case .satMax: "Sat Max"
        case .lumMin: "Luma Min"
        case .lumMax: "Luma Max"
        case .softness: "Softness"
        case .hueShift: "Hue Shift"
        case .saturation: "Saturation"
        case .exposure: "Exposure"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .volumeSat: "Saturation"
        case .volumeLum: "Luma"
        case .volumeRadius: "Radius"
        }
    }

    /// A row of the Range group: the qualifier sliders (ranges mode) or the color-volume sliders.
    public var isQualifier: Bool { rawValue <= ColorRangeParam.softness.rawValue }
    public var isVolume: Bool { self == .volumeSat || self == .volumeLum || self == .volumeRadius }
    /// A row of the Correction group.
    public var isCorrection: Bool { !isQualifier && !isVolume }
    /// Whether the row shows in this mask mode (Hue and Softness serve both).
    public func isShown(in mode: HSLSecondary.MaskMode) -> Bool {
        if isCorrection { return true }
        if self == .hueCenter || self == .softness { return true }
        return isVolume == (mode == .volume)
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .hueCenter, .hueWidth: 0...360
        case .satMin, .satMax, .lumMin, .lumMax, .softness, .volumeSat, .volumeLum, .volumeRadius: 0...100
        case .hueShift: -180...180
        case .saturation: 0...200
        case .exposure: HSLSecondary.exposureRange
        case .temperature, .tint: -100...100
        }
    }

    /// The value of a new range (double-click / reset goes back here).
    public var neutral: Float { read(HSLSecondary()) }
    public var decimals: Int { self == .exposure ? 2 : 1 }
    public var track: ColorParam.Track { self == .temperature ? .temperature : self == .tint ? .tint : .plain }

    public func read(_ r: HSLSecondary) -> Float {
        switch self {
        case .hueCenter: r.hueCenter
        case .hueWidth: r.hueWidth
        case .satMin: r.satMin
        case .satMax: r.satMax
        case .lumMin: r.lumMin
        case .lumMax: r.lumMax
        case .softness: r.softness
        case .hueShift: r.hueShift
        case .saturation: r.saturation
        case .exposure: r.exposure
        case .temperature: r.temperature
        case .tint: r.tint
        case .volumeSat: r.volumeSat
        case .volumeLum: r.volumeLum
        case .volumeRadius: r.volumeRadius
        }
    }

    /// Clamps to `range` and writes; a min / max pair never crosses (the other end is pushed along).
    public func write(_ value: Float, into r: inout HSLSecondary) {
        let v = min(max(value, range.lowerBound), range.upperBound)
        switch self {
        case .hueCenter: r.hueCenter = v
        case .hueWidth: r.hueWidth = v
        case .satMin: r.satMin = v; r.satMax = max(r.satMax, v)
        case .satMax: r.satMax = v; r.satMin = min(r.satMin, v)
        case .lumMin: r.lumMin = v; r.lumMax = max(r.lumMax, v)
        case .lumMax: r.lumMax = v; r.lumMin = min(r.lumMin, v)
        case .softness: r.softness = v
        case .hueShift: r.hueShift = v
        case .saturation: r.saturation = v
        case .exposure: r.exposure = v
        case .temperature: r.temperature = v
        case .tint: r.tint = v
        case .volumeSat: r.volumeSat = v
        case .volumeLum: r.volumeLum = v
        case .volumeRadius: r.volumeRadius = v
        }
    }
}

extension ColorInspectorModel {
    /// The effect's Color Range; nil = none yet (the panel shows the defaults of a new one).
    public func colorRange(_ effect: Int) -> HSLSecondary? { color.effect(effect)?.hslSecondary }

    public func rangeValue(_ effect: Int, _ p: ColorRangeParam) -> Float {
        p.read(colorRange(effect) ?? HSLSecondary())
    }

    /// Writes one value; the first edit creates the range (skin tones, nothing corrected) and applies the value.
    public func setRange(_ effect: Int, _ p: ColorRangeParam, _ v: Float) {
        editEffect(effect) { e in
            var r = e.hslSecondary ?? HSLSecondary()
            p.write(v, into: &r)
            e.hslSecondary = r
        }
    }

    /// No range yet: every value already shows its default, so nothing is created (no undo step, no v48 file).
    public func resetRangeParameter(_ effect: Int, _ p: ColorRangeParam) {
        guard colorRange(effect) != nil else { return }
        gesture { setRange(effect, p, p.neutral) }
    }

    /// How the mask is picked: three ranges, or a ball in the 3D color volume. One undo step.
    public func setRangeMaskMode(_ effect: Int, _ mode: HSLSecondary.MaskMode) {
        gesture {
            editEffect(effect) { e in
                var r = e.hslSecondary ?? HSLSecondary()
                r.maskMode = mode
                e.hslSecondary = r
            }
        }
    }

    public func rangeMaskMode(_ effect: Int) -> HSLSecondary.MaskMode { colorRange(effect)?.maskMode ?? .ranges }

    /// Invert: correct everything outside the range. One undo step.
    public func setRangeInvert(_ effect: Int, _ on: Bool) {
        gesture {
            editEffect(effect) { e in
                var r = e.hslSecondary ?? HSLSecondary()
                r.invert = on
                e.hslSecondary = r
            }
        }
    }
}
