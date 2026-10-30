import SQCore

/// Preview speed of the monitor's Play (0.5x to 10x). Preview only: export and the project never see it.
///
/// Audio policy: the audio path already runs every non-1x rate through `AVAudioUnitTimePitch` with pitch 0 cents
/// (`AudioEngine.setRate`, rate range 1/32...32), so pitch stays correct at every preset and nothing is muted. Above
/// about 4x speech is not intelligible, which is expected of a preview speed. If that annoys, mute above a limit here.
public struct PreviewRate: Sendable, Hashable, Identifiable {
    public let rate: PlaybackRate
    public var id: PlaybackRate { rate }

    public static let normal = PreviewRate(.forward)
    public static let presets: [PreviewRate] = [
        PlaybackRate(1, 2), PlaybackRate(3, 4), .forward, PlaybackRate(5, 4), PlaybackRate(3, 2), PlaybackRate(2),
        PlaybackRate(3), PlaybackRate(4), PlaybackRate(6), PlaybackRate(8), PlaybackRate(10),
    ].map(PreviewRate.init)

    /// Clamped into 0.5x...10x, forward only (reverse is the shuttle's job).
    public init(_ rate: PlaybackRate) {
        let m = rate.magnitude
        if Int64(m.num) * 2 < Int64(m.den) { self.rate = PlaybackRate(1, 2) }
        else if m.num > 10 * m.den { self.rate = PlaybackRate(10) }
        else { self.rate = m }
    }

    public var isNormal: Bool { rate == .forward }

    /// Menu title: "0.5x", "1.25x", "10x"; 1x reads "Normal (1x)".
    public var title: String {
        if isNormal { return "Normal (1x)" }
        let v = Double(rate.num) / Double(rate.den)
        return (v == v.rounded() ? String(Int(v)) : String(format: "%g", v)) + "x"
    }
}
