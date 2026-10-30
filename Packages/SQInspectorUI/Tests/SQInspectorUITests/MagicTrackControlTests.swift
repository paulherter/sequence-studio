import Testing
@testable import SQInspectorUI

@Suite struct MagicTrackControlTests {
    let fd = 1.0 / 24

    @Test func aPickStartsNothing() {
        var c = MagicTrackControl()
        c.pickStored()
        #expect(c.phase == .idle)
        #expect(!c.isTracking)
    }

    @Test func stepGoesOneFrameEachWay() throws {
        var c = MagicTrackControl()
        let fLeg = c.begin(.step(forward: true), playhead: 1, edge: 5, frame: fd)
        let f = try #require(fLeg)
        #expect(f.from == 1 && abs(f.to - (1 + fd)) < 1e-9 && f.forward)
        c.finish()
        let bLeg = c.begin(.step(forward: false), playhead: 1, edge: 0, frame: fd)
        let b = try #require(bLeg)
        #expect(abs(b.to - (1 - fd)) < 1e-9 && !b.forward)
    }

    @Test func stepAtTheEdgeDoesNothing() {
        var c = MagicTrackControl()
        let a = c.begin(.step(forward: true), playhead: 5, edge: 5, frame: fd)
        let b = c.begin(.run(forward: false), playhead: 0, edge: 0, frame: fd)
        #expect(a == nil && b == nil)
        #expect(c.phase == .idle)
    }

    @Test func runGoesToTheEdgeAndRefusesASecondStart() throws {
        var c = MagicTrackControl()
        let rLeg = c.begin(.run(forward: true), playhead: 1, edge: 3, frame: fd)
        let r = try #require(rLeg)
        #expect(r.to == 3 && r.frames == 49)
        #expect(c.isTracking)
        let second = c.begin(.step(forward: false), playhead: 1, edge: 0, frame: fd)
        #expect(second == nil)
        c.progress(0.5)
        guard case .tracking(_, _, let frame, let done, let total) = c.phase else { Issue.record("not tracking"); return }
        #expect(abs(frame - 2) < 1e-9 && done == 24 && total == 49)
        c.finish()
        #expect(c.phase == .idle)
    }

    @Test func stopKeepsTheCount() {
        var c = MagicTrackControl()
        let nothing = c.stop()
        #expect(!nothing)
        _ = c.begin(.run(forward: false), playhead: 3, edge: 0, frame: fd)
        c.progress(0.25)
        let did = c.stop()
        #expect(did)
        #expect(c.phase == .stopped(done: 18))
        c.finish()
        #expect(c.phase == .stopped(done: 18))
        let again = c.begin(.step(forward: true), playhead: 1, edge: 5, frame: fd)
        #expect(again != nil)
    }
}
