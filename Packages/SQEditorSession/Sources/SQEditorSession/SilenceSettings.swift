import Foundation
import SQCore

/// Settings of "Remove Silences…": what counts as a pause and how much of it stays.
public struct SilenceSettings: Sendable, Equatable {
    /// Audio quieter than this (peak, dB) is silence.
    public var thresholdDB: Double
    /// A pause must last at least this many milliseconds.
    public var minimumMs: Int
    /// Milliseconds of every pause that stay at both ends (so cuts do not sound clipped).
    public var paddingMs: Int

    public static let standard = SilenceSettings(thresholdDB: -35, minimumMs: 350, paddingMs: 70)

    public init(thresholdDB: Double, minimumMs: Int, paddingMs: Int) {
        self.thresholdDB = thresholdDB; self.minimumMs = minimumMs; self.paddingMs = paddingMs
    }

    /// Slider ranges: threshold in dB, minimum length and padding in ms.
    public static let thresholdRange: ClosedRange<Double> = -60 ... -10
    public static let minimumRange: ClosedRange<Double> = 100 ... 2000
    public static let paddingRange: ClosedRange<Double> = 0 ... 500

    /// The values a slider position applies, rounded to 1 dB, 50 ms and 10 ms (the fields show these, never more).
    public static func snapped(thresholdDB: Double, minimumMs: Double, paddingMs: Double) -> SilenceSettings {
        SilenceSettings(thresholdDB: thresholdDB.rounded(), minimumMs: Int((minimumMs / 50).rounded() * 50),
                        paddingMs: Int((paddingMs / 10).rounded() * 10))
    }

    public var minimum: Time { Time(Int64(max(minimumMs, 0)), 1000) }
    public var padding: Time { Time(Int64(max(paddingMs, 0)), 1000) }

    private enum Key { static let db = "sq.silence.thresholdDB", min = "sq.silence.minMs", pad = "sq.silence.padMs" }

    /// Last values used, or the defaults.
    public static func remembered(_ d: UserDefaults = .standard) -> SilenceSettings {
        guard d.object(forKey: Key.db) != nil else { return .standard }
        return SilenceSettings(thresholdDB: d.double(forKey: Key.db), minimumMs: d.integer(forKey: Key.min), paddingMs: d.integer(forKey: Key.pad))
    }

    public func remember(_ d: UserDefaults = .standard) {
        d.set(thresholdDB, forKey: Key.db); d.set(minimumMs, forKey: Key.min); d.set(paddingMs, forKey: Key.pad)
    }

    /// "12 silences, 8.4 s will be removed" for the dialog's preview line.
    public static func previewText(count: Int, removed: Time) -> String {
        guard count > 0 else { return "No silences found." }
        let sec = Double(removed.value) / Double(removed.timescale)
        return "\(count) \(count == 1 ? "silence" : "silences"), \(String(format: "%.1f", sec)) s will be removed."
    }
}
