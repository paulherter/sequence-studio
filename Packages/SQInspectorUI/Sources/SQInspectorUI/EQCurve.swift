import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQAudioFX
import SQCore

/// Pure mapping of the EQ curve plot: frequency on a log axis (20 Hz...20 kHz), gain linear (about +-18 dB).
public struct EQCurveGeometry: Equatable, Sendable {
    public static let minHz = 20.0, maxHz = 20_000.0
    public static let maxDB = 18.0
    public static let gridDB: [Double] = [-12, -6, 0, 6, 12]
    public static let gridHz: [Double] = [20, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900,
                                          1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000, 10_000, 20_000]
    /// Decade lines (drawn stronger and labeled).
    public static let decadeHz: [Double] = [100, 1_000, 10_000]
    public var plot: CGRect

    public init(plot: CGRect) { self.plot = plot }

    private static let logSpan = log10(maxHz / minHz)
    public func x(hz: Double) -> CGFloat {
        let t = log10(min(max(hz, Self.minHz), Self.maxHz) / Self.minHz) / Self.logSpan
        return plot.minX + CGFloat(t) * plot.width
    }
    public func hz(x: CGFloat) -> Double {
        let t = Double((x - plot.minX) / max(plot.width, 1))
        return Self.minHz * pow(10, min(max(t, 0), 1) * Self.logSpan)
    }
    /// Top of the plot is +maxDB (flipped view: y grows downward).
    public func y(db: Double) -> CGFloat {
        let t = (min(max(db, -Self.maxDB), Self.maxDB) + Self.maxDB) / (2 * Self.maxDB)
        return plot.maxY - CGFloat(t) * plot.height
    }
    public func db(y: CGFloat) -> Double {
        let t = Double((plot.maxY - y) / max(plot.height, 1))
        return min(max(t, 0), 1) * 2 * Self.maxDB - Self.maxDB
    }
    /// Frequencies the curve is sampled at: log spaced, one per `step` points of width (at least 8).
    public func sampleFrequencies(step: CGFloat = 2) -> [Double] {
        let n = max(8, Int(plot.width / step))
        return (0...n).map { Self.minHz * pow(10, Double($0) / Double(n) * Self.logSpan) }
    }
}

extension EQCurveGeometry {
    /// HP (0) and LP (8) only have a frequency; the shelves and bands also gain and Q.
    public static func hasGain(_ i: Int) -> Bool { i >= 1 && i <= 7 }
    /// Option-drag / scroll Q: up = narrower (higher Q), 2x per 40 points.
    public static func qFactor(start: Double, dy: CGFloat) -> Double {
        min(max(start * pow(2, Double(dy) / 40), 0.1), 10)
    }
    public static let filterNames = ["High-Pass", "Low Shelf", "Band 1", "Band 2", "Band 3", "Band 4", "Band 5", "High Shelf", "Low-Pass"]
}

/// EQ curve under the Parametric EQ's header: a "Curve" disclosure and, while open, the inline `EQCurveView`. Edits write
/// the same effect parameters the sliders use (`setValues`: static value, or a key at the playhead when animated), so the
/// sliders below stay in sync and a drag is one undo gesture.
extension EffectControlsModel {
    public func isEQCurveOpen(_ effect: ClipEffect.ID) -> Bool { openColorGroups.contains(Self.colorGroupID(effect, Self.eqCurveKey)) }
    public func toggleEQCurve(_ effect: ClipEffect.ID) { toggleColorGroup(effect, Self.eqCurveKey) }

    private func eqProperty(_ effect: ClipEffect.ID, _ filter: Int, _ field: String) -> EffectProperty {
        .fx(effect, kind: ClipEffect.audioParametricEQKind, key: ClipEffect.peqKey(ClipEffect.peqFilterIDs[filter], field))
    }

    /// The shown values at the playhead.
    public func eqValues(_ effect: ClipEffect.ID) -> AudioParametricEQValues? {
        guard clip?.effects.contains(where: { $0.id == effect && $0.kind == ClipEffect.audioParametricEQKind }) == true else { return nil }
        func band(_ i: Int) -> AudioPEQBand {
            func v(_ f: String) -> Double { scalarValue(eqProperty(effect, i, f)) }
            let cut = !EQCurveGeometry.hasGain(i)
            return AudioPEQBand(on: v("On") >= 0.5, hz: v("Freq"), gainDB: cut ? 0 : v("Gain"), q: cut ? 0.7071 : v("Q"))
        }
        return AudioParametricEQValues(hp: band(0), lowShelf: band(1), b1: band(2), b2: band(3), b3: band(4), b4: band(5),
                                       b5: band(6), highShelf: band(7), lp: band(8))
    }

    /// Frequency, gain and Q of one filter in one commit (inside a gesture: part of it). a nil `hz` / `gainDB` / `q` is not written (no key on an animated parameter).
    public func setEQBand(_ effect: ClipEffect.ID, filter: Int, hz: Double?, gainDB: Double?, q: Double?) {
        guard (0..<AudioParametricEQValues.bandCount).contains(filter) else { return }
        var pairs: [(EffectProperty, Double)] = []
        if let hz { pairs.append((eqProperty(effect, filter, "Freq"), hz)) }
        if let gainDB, EQCurveGeometry.hasGain(filter) { pairs.append((eqProperty(effect, filter, "Gain"), gainDB)) }
        if let q, EQCurveGeometry.hasGain(filter) { pairs.append((eqProperty(effect, filter, "Q"), q)) }
        guard !pairs.isEmpty else { return }
        setValues(pairs, name: "Change EQ \(EQCurveGeometry.filterNames[filter])")
    }

    /// Frequency, gain and Q back to the catalog defaults (one undo step).
    public func resetEQBand(_ effect: ClipEffect.ID, filter: Int) {
        guard (0..<AudioParametricEQValues.bandCount).contains(filter),
              let spec = EffectCatalog.spec(for: ClipEffect.audioParametricEQKind) else { return }
        let id = ClipEffect.peqFilterIDs[filter]
        let fields = EQCurveGeometry.hasGain(filter) ? ["Freq", "Gain", "Q"] : ["Freq"]
        let pairs = fields.compactMap { f in
            spec.params.first { $0.key == ClipEffect.peqKey(id, f) }.map { (eqProperty(effect, filter, f), $0.defaultValue) }
        }
        setValues(pairs, name: "Reset EQ \(EQCurveGeometry.filterNames[filter])")
    }
}
