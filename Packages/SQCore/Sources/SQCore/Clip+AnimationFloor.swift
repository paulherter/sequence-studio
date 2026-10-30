import Foundation
import Synchronization

// Intro / outro zones of a graphic or text clip (feedback 2026-10-13): the first N seconds are the in-animation, the last M
// seconds the out-animation. They keep their length when the clip is trimmed or lengthened (anchored playback, see
// AnchoredAnimation.swift: never scaled, never rewritten), and the clip cannot get shorter than N + M, so the zones
// never overlap. Every trim path asks `minimumDuration(frame:)` instead of a bare one frame.

extension Clip {
    /// Lengths of the intro and outro zones: a text clip's anchored in / out animations (a looping intro is not a zone),
    /// or the clip's own `zones`. nil when the clip has none.
    public var animationZoneLengths: (intro: Time, outro: Time)? {
        if let g = generator, g.kind == GeneratorRef.text, let l = TextZoneLengths.lengths(of: g) { return l }
        return zones.map { ($0.introEnd, $0.outroLength) }
    }

    /// The shortest this clip may be: its zones side by side, at least one `frame`.
    public func minimumDuration(frame: Time) -> Time {
        guard let z = animationZoneLengths else { return frame }
        return max(frame, z.intro + z.outro)
    }

    /// `g` (change of duration, negative = shorter) held back so the clip stays at least `minimumDuration`; a clip that is
    /// already shorter than its zones does not shrink further.
    func clampingShortening(_ g: Time, frame: Time) -> Time {
        guard g < .zero, animationZoneLengths != nil else { return g }
        return max(g, min(.zero, minimumDuration(frame: frame) - duration))
    }
}

/// Reads the in / out lengths straight from a text payload (`{"template": ..., "animations": AnimationSet}`, owned by
/// SQText) so SQCore needs no SQText types. Memoized: trims and timeline drawing ask per clip.
private enum TextZoneLengths {
    private struct Payload: Decodable { var animations: AnimationSet? }
    private static let memo = Mutex<[Data: (Time, Time)?]>([:])
    private static let limit = 512

    static func lengths(of ref: GeneratorRef) -> (intro: Time, outro: Time)? {
        if let hit = memo.withLock({ $0[ref.payload] }) { return hit.map { (intro: $0.0, outro: $0.1) } }
        var result: (Time, Time)?
        if let p = try? JSONDecoder().decode(Payload.self, from: ref.payload), let set = p.animations {
            func len(_ t: KeyframeTemplate?) -> Time {
                guard let t, !t.loops, !t.tracks.isEmpty else { return .zero }
                return max(t.duration, .zero)
            }
            let a = len(set.animationIn), b = len(set.animationOut)
            if a > .zero || b > .zero { result = (a, b) }
        }
        memo.withLock { m in
            if m.count >= limit { m.removeAll(keepingCapacity: true) }
            m[ref.payload] = .some(result)
        }
        return result.map { (intro: $0.0, outro: $0.1) }
    }
}
