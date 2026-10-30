import Foundation

/// The program loudness readout on the monitor picture: short-term and integrated LUFS as one short line. Momentary alone is
/// not shown (it flickers; the meter panel has it).
public enum LoudnessReadout {
    public static func text(_ r: LoudnessReading) -> String? {
        var parts: [String] = []
        if let s = r.shortTermLUFS, s.isFinite, s > -100 { parts.append("S " + LoudnessScale.text(lufs: s)) }
        if let i = r.integratedLUFS, i.isFinite, i > -100 { parts.append("I " + LoudnessScale.text(lufs: i)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ") + " LUFS"
    }

    /// Short-term or integrated above the target by more than 1 LU, or the true peak above the ceiling.
    public static func isOver(_ r: LoudnessReading, target: LoudnessTarget) -> Bool {
        target.isOverTarget(r.shortTermLUFS) || target.isOverTarget(r.integratedLUFS) || target.isOverCeiling(r.truePeakDB)
    }
}
