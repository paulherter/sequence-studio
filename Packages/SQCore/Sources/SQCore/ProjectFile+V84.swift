import Foundation
import Synchronization

// v84: perspective tilt (`ClipAnimation.tiltX` / `tiltY`, PerspectiveTilt.swift), written only when set away from 0 or keyed. A v83
// build would drop the tilt on the next save; at v84 it refuses the file with `ProjectFileError.newerVersion` instead. Projects
// without a tilt keep the lowest version that holds their content. Identity migration step.
//
// Clips and graphics layers both own a `ClipAnimation`, so the animation marks `TiltSeen` in the encoder's `userInfo` while
// it writes a tilt and the envelope then writes v84 (the same walk-free gate Hold Ahead uses).

final class TiltSeen: Sendable {
    static let key = CodingUserInfoKey(rawValue: "sq.tiltSeen")!
    private let seen = Mutex(false)
    func mark() { seen.withLock { $0 = true } }
    var value: Bool { seen.withLock { $0 } }
}
