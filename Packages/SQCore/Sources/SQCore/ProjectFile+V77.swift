import Foundation
import Synchronization

// v77: `Interpolation.holdAhead` (Hold Ahead: the key shows the next key's value right after its own time). A v76 build
// cannot read the case; at v77 it refuses the file with `ProjectFileError.newerVersion`. Projects without one keep the
// lowest version that holds their content.
//
// Before v77 a reverse wrote a Hold Ahead as two keys: a Hold key (the leader) and a second Hold key one microsecond
// later on the next key's value (the helper), hidden from every key list and told by its looks alone. Such a pair is
// folded into one Hold Ahead key wherever a track is decoded (`KeyframeTrack.init(from:)`): project files of any
// version (a file is written at the lowest version that holds its content, so a v36 file can carry the pair), effect
// presets, templates. This is the only place that still knows the two-key form.

/// Set in the encoder's `userInfo` by `ProjectFile.encode`: a key that writes a Hold Ahead marks it, and the envelope
/// then writes v77. (A typed walk would have to know every place of the model that owns a track.)
final class HoldAheadSeen: Sendable {
    static let key = CodingUserInfoKey(rawValue: "sq.holdAheadSeen")!
    private let seen = Mutex(false)
    func mark() { seen.withLock { $0 = true } }
    var value: Bool { seen.withLock { $0 } }
}

extension KeyframeTrack {
    /// How far the helper key of the two-key form sat behind its leader.
    static var legacyHoldStep: Time { Time(1, 1_000_000) }

    /// Folds every leader + helper pair of the two-key form into one Hold Ahead key: a Hold key at most one
    /// `legacyHoldStep` after a Hold key, on the value of the key after it, with untouched handles and tangents, was the
    /// helper; it goes and its leader becomes a Hold Ahead. Every time outside the microsecond between the two evaluates
    /// as before (inside it the old form still showed the leader's value; no frame time falls there).
    mutating func foldLegacyHoldHelpers() {
        guard keys.count >= 3 else { return }
        let step = Self.legacyHoldStep
        var j = 1
        while j + 1 < keys.count {
            let k = keys[j], leader = keys[j - 1]
            if k.interpolation == .hold, leader.interpolation == .hold, k.time - leader.time <= step,
               k.value == keys[j + 1].value, k.inHandle == .linear, k.outHandle == .linear,
               k.inTangent == .zero, k.outTangent == .zero {
                keys[j - 1].interpolation = .holdAhead
                keys.remove(at: j)
            }
            j += 1
        }
    }
}
