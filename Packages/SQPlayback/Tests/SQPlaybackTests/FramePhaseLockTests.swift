import Foundation
import Testing
import SQCore
@testable import SQPlayback

/// Playing frame changes are kept midway between display ticks, so tick jitter never shows a frame for 3 ticks and the
/// next for 1 (a 50 ms hitch at 30 fps on 60 Hz).
@Suite struct FramePhaseLockTests {
    let fd = Time(1, 30)
    let us = Time(1, 1_000_000)

    /// Simulates ticks at `hz` with a constant phase `start` (seconds), deterministic jitter of +-`jitterUs`, and returns
    /// the frame shown at each tick.
    private func run(_ lock: inout FramePhaseLock, hz: Int64, ticks: Int, start: Time, jitterUs: Int64, reverse: Bool = false) -> [Int64] {
        var out: [Int64] = []
        let period = Time(1, hz)
        for k in 0..<ticks {
            let j = jitterUs == 0 ? Int64(0) : Int64((k * 7919) % Int(2 * jitterUs + 1)) - jitterUs
            var now = start + period * Int64(k) + us * j
            if reverse { now = Time(100, 1) - (start + period * Int64(k)) + us * j }
            let t = lock.sample(now, frameDuration: fd, reverse: reverse)
            out.append(t.frameIndex(frameDuration: fd))
        }
        return out
    }

    /// Longest run of ticks one frame stayed on screen (after the first `settle` ticks).
    private func longestHold(_ frames: [Int64], settle: Int) -> Int {
        var best = 0, cur = 0
        var last: Int64?
        for f in frames.dropFirst(settle) {
            if f == last { cur += 1 } else { cur = 1; last = f }
            best = max(best, cur)
        }
        return best
    }

    @Test func frameBoundaryOnTheTickWithJitterNeverHoldsThreeTicks() {
        // Frame boundaries exactly on the 60 Hz ticks, 2 ms jitter: without the lock 3-tick holds (50 ms) appear.
        var plain = FramePhaseLock(); plain.enabled = false
        let unlocked = run(&plain, hz: 60, ticks: 600, start: .zero, jitterUs: 2000)
        #expect(longestHold(unlocked, settle: 0) >= 3)
        var lock = FramePhaseLock()
        let locked = run(&lock, hz: 60, ticks: 600, start: .zero, jitterUs: 2000)
        #expect(longestHold(locked, settle: 30) == 2)
        // Offset ends near a quarter frame (boundaries midway between 60 Hz ticks), well inside half a frame.
        let off = lock.offset < .zero ? -lock.offset : lock.offset
        #expect(off <= fd.halved)
        #expect(off >= Time(5, 1000))
    }

    @Test func thirtyHzTicksSitMidFrame() {
        var lock = FramePhaseLock()
        let frames = run(&lock, hz: 30, ticks: 300, start: Time(1, 1000), jitterUs: 3000)
        // After settling every tick shows the next frame (no repeat, no skip).
        let tail = Array(frames.dropFirst(30))
        for i in 1..<tail.count { #expect(tail[i] - tail[i - 1] == 1) }
    }

    @Test func reversePlayLocksToo() {
        var lock = FramePhaseLock()
        let frames = run(&lock, hz: 60, ticks: 600, start: .zero, jitterUs: 2000, reverse: true)
        #expect(longestHold(frames, settle: 30) == 2)
    }

    @Test func alreadyCenteredStaysPut() {
        var lock = FramePhaseLock()
        // Boundaries a quarter frame away from 60 Hz ticks: nothing to correct.
        _ = run(&lock, hz: 60, ticks: 120, start: Time(1, 120), jitterUs: 0)
        let off = lock.offset < .zero ? -lock.offset : lock.offset
        #expect(off <= Time(1, 1000))
    }

    @Test func offsetIsBoundedAndResetClearsIt() {
        var lock = FramePhaseLock()
        // A clock that drifts against the ticks for a long time: the offset never exceeds half a frame.
        var now = Time.zero
        for _ in 0..<20_000 {
            now = now + Time(1, 60) + Time(40, 1_000_000)
            _ = lock.sample(now, frameDuration: fd, reverse: false)
            let off = lock.offset < .zero ? -lock.offset : lock.offset
            #expect(off <= fd.halved)
        }
        lock.reset()
        #expect(lock.offset == .zero)
    }

    @Test func jumpsDoNotTeach() {
        var lock = FramePhaseLock()
        // A seek between ticks (more than one frame) is not a boundary crossing: no correction.
        _ = lock.sample(Time(1, 1000), frameDuration: fd, reverse: false)
        _ = lock.sample(Time(5, 1), frameDuration: fd, reverse: false)
        #expect(lock.offset == .zero)
    }
}
