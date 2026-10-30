import Foundation
import SQCore

/// What the timeline draws during an Option-drag on a cut: a ghost of the old audio edge and the offset label.
public struct SplitRollGhost: Sendable, Hashable {
    public var cut: Time
    /// Applied move of the audio edit; negative = audio starts early (J cut), positive = audio runs on (L cut).
    public var offset: Time

    /// "J cut -0.50 s (-15 f)" / "L cut +0.50 s (+15 f)" / "0 s".
    public func label(frameDuration: Time) -> String {
        guard offset != .zero else { return "0 s" }
        let seconds = Double(offset.value) / Double(offset.timescale)
        let frames = Int((Double(offset.value) * Double(frameDuration.timescale)
                          / (Double(offset.timescale) * Double(frameDuration.value))).rounded())
        return "\(offset < .zero ? "J" : "L") cut \(String(format: "%+.2f", seconds)) s (\(frames > 0 ? "+" : "")\(frames) f)"
    }
}

/// Which cuts an Option-drag may split-roll.
enum SplitRoll {
    /// The cut under a pressed clip edge when that clip is linked and the cut exists on at least one audio track;
    /// nil otherwise (the press then behaves as a normal Option-trim).
    static func cut(for ref: EdgeRef, in t: Timeline) -> Time? {
        guard let c = t.tracks.flatMap(\.clips).first(where: { $0.id == ref.clip }), c.link != nil,
              let cut = t.cutTime(ofClip: ref.clip, edge: ref.edge) else { return nil }
        var probe = t
        return (try? probe.splitEdit(cut: cut, side: .audio, to: cut)) != nil ? cut : nil
    }
}
