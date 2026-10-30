import Foundation

/// One-click live duck settings: an amount plus a timing. Ours (unsourced values, tuned by ear for TikTok-style speech).
public struct DuckPreset: Sendable, Hashable {
    public var title: String
    public var amountDB: Double
    public var timing: DuckTiming

    /// Voice-over under a steady bed: shallow duck, slow recovery so the music swells back gently.
    public static let soft = DuckPreset(title: "Soft (voice-over)", amountDB: 9,
        timing: DuckTiming(lookaheadMs: 30, attackMs: 250, holdMs: 300, recoveryMs: 1200, minPauseMs: 500))
    /// Fast speech: deep duck, quick ramps, short breaths bridged so the music does not pump.
    public static let hard = DuckPreset(title: "Hard (fast speech)", amountDB: 18,
        timing: DuckTiming(lookaheadMs: 15, attackMs: 40, holdMs: 200, recoveryMs: 500, minPauseMs: 350))

    public static let all: [DuckPreset] = [.soft, .hard]

    /// The preset matching `amountDB` and `timing`, if any.
    public static func matching(amountDB: Double, timing: DuckTiming) -> DuckPreset? {
        all.first { $0.amountDB == amountDB && $0.timing == timing.clamped }
    }

    /// Any amount the user types: finite, above 0 (0 = off), at most 40 dB, rounded to 0.5 dB.
    public static func clampedAmount(_ db: Double) -> Double {
        guard db.isFinite else { return Ducking.defaultAmountDB }
        return (min(max(db, 0.5), 40) * 2).rounded() / 2
    }
}
