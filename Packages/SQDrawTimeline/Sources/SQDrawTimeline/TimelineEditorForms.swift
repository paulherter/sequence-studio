import Foundation
import SQCore

/// Values the host's form dialogs for timeline editors read back (portable, so the Windows shell forms share them).
public enum TimelineEditorForms {
    /// The Mac Color Matte sheet's duration range in seconds (`ColorMatteDialog.durationSeconds`).
    public static let matteSeconds: ClosedRange<Double> = 0.1...3600

    /// "#RRGGBB", "RRGGBB" or "#RGB" (case-insensitive, spaces ignored); nil for anything else.
    public static func matteColor(hex: String) -> ColorMatteColor? {
        var s = hex.filter { !$0.isWhitespace }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return ColorMatteColor(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    /// "#RRGGBB" in upper case.
    public static func hex(_ c: ColorMatteColor) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }

    /// Seconds typed in the duration field, clamped to `matteSeconds`, as whole milliseconds (the session snaps to a
    /// frame, like the Mac sheet).
    public static func matteDuration(seconds: Double) -> Time {
        let s = min(max(seconds.isFinite ? seconds : 5, matteSeconds.lowerBound), matteSeconds.upperBound)
        return Time(Int64((s * 1000).rounded()), 1000)
    }
}
