import Foundation
import SQUIKit
import SQDrawKit

/// Keeps one `SQMascotPlayer` per slot (a row, the dialog footer) and advances it by the wall-clock time between
/// draws, so Pip blinks and breathes at any redraw rate (the same player the Mac view runs). A slot restarts when its
/// animation changes. `animating` tells a host whether a redraw is still worth asking for.
public final class ShellMascotStage {
    private struct Slot { var anim: SQMascotAnim; var player: SQMascotPlayer; var last: Double }
    private var slots: [Int: Slot] = [:]

    public init() {}

    /// The pose of `slot` at `now` (seconds, any steady clock).
    func pose(_ anim: SQMascotAnim, slot: Int, now: Double) -> SQMascotPose {
        let lib = SQMascotLibrary.shared
        if var s = slots[slot], s.anim == anim {
            let dt = min(max(0, now - s.last) * 1000, 250)
            s.last = now
            let p = s.player.advance(dt)
            slots[slot] = s
            return p
        }
        var player = SQMascotPlayer(animation: lib.animation(anim), idle: lib.idle, seed: UInt64(slot) &+ 1)
        player.start()
        let p = player.advance(0)
        slots[slot] = Slot(anim: anim, player: player, last: now)
        return p
    }

    public func forget(slot: Int) { slots[slot] = nil }
    public var animating: Bool { !slots.isEmpty }

    /// Draws `anim` for `slot` aspect-fitted in `rect`.
    public func draw(_ anim: SQMascotAnim, slot: Int, now: Double = ProcessInfo.processInfo.systemUptime,
                     in rect: CGRect, into c: inout Canvas) {
        let a = SQMascotLibrary.shared.animation(anim)
        var tight = a.tight
        var vb = a.viewBox
        if Double(min(rect.width, rect.height)) <= 24 { tight = true; vb = CGRect(x: 125, y: 268, width: 774, height: 774) }
        ShellMascot.draw(pose: pose(anim, slot: slot, now: now), tight: tight, viewBox: vb, in: rect, into: &c)
    }
}
