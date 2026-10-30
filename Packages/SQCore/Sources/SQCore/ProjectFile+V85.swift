import Foundation
import Synchronization

// v85: per-edge Follow padding (`GraphicsFollow.edgePadding`, Graphics+Follow.swift), written only when the four paddings
// differ. A v84 build would drop it and draw the follower with the single `padding`; at v85 it refuses the file with
// `ProjectFileError.newerVersion` instead. Other projects keep the lowest version that holds their content. Identity step.
//
// Follows are nested deep in clips, templates and format variants, so `GraphicsFollow.encode` marks `FollowEdgePaddingSeen`
// in the encoder's `userInfo` and the envelope then writes v85 (the walk-free gate Tilt uses).

final class FollowEdgePaddingSeen: Sendable {
    static let key = CodingUserInfoKey(rawValue: "sq.followEdgePaddingSeen")!
    private let seen = Mutex(false)
    func mark() { seen.withLock { $0 = true } }
    var value: Bool { seen.withLock { $0 } }
}
