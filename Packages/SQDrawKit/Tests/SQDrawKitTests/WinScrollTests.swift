import Testing
@testable import SQDrawKit

/// The Windows wheel route (`WinScroll`): mouse notches, precision touchpad scrolls and pinches with the Mac meaning.
@Suite struct WinScrollTests {
    @Test func mouseNotchesAreLinesWithTheOldPixels() {
        var s = WinScroll()
        let up = s.wheel(delta: 120, horizontal: false, control: false, now: 0)
        #expect(up == ScrollGesture(deltaX: 0, deltaY: 1))
        #expect(WinScroll.pixels(up, scale: 1.5) == (dx: 0, dy: 40))           // what the host always sent
        #expect(up == ScrollGesture.wheel(pixelsX: 0, pixelsY: 40))
        let right = s.wheel(delta: 240, horizontal: true, control: false, now: 0.01)
        #expect(right.deltaX == -2 && right.deltaY == 0 && !right.precise)       // tilt right: later content
        #expect(!s.isActive && s.idle(now: 5) == nil)
        // Ctrl + a notch stays a scroll (the panels zoom on it as Command + wheel on the Mac).
        #expect(s.wheel(delta: -120, horizontal: false, control: true, now: 1).isScroll)
    }

    @Test func touchpadScrollIsPreciseWithMadeUpPhases() {
        var s = WinScroll()
        let a = s.wheel(delta: 30, horizontal: false, control: false, now: 0)
        #expect(a.precise && a.phase == .began && a.deltaY == 10)
        #expect(WinScroll.pixels(a, scale: 2) == (dx: 0, dy: 20))
        // A whole notch inside a running gesture stays precise.
        let b = s.wheel(delta: 120, horizontal: false, control: false, now: 0.05)
        #expect(b.precise && b.phase == .changed && b.deltaY == 40)
        let c = s.wheel(delta: -15, horizontal: true, control: false, now: 0.1)
        #expect(c.phase == .changed && c.deltaX == 5 && c.deltaY == 0)
        #expect(s.idle(now: 0.15) == nil)
        let end = s.idle(now: 0.3)
        #expect(end == ScrollGesture(precise: true, phase: .ended))
        #expect(!s.isActive && s.idle(now: 1) == nil)
        // After the end a notch is a mouse again.
        #expect(!s.wheel(delta: 120, horizontal: false, control: false, now: 2).precise)
    }

    @Test func ctrlTouchpadIsAPinch() {
        var s = WinScroll()
        let a = s.wheel(delta: 60, horizontal: false, control: true, now: 0)
        #expect(a == ScrollGesture(kind: .magnify(0.05), precise: true, phase: .began))
        #expect(WinScroll.pixels(a, scale: 1) == (dx: 0, dy: 0))                  // a pinch moves no list
        let b = s.wheel(delta: -12, horizontal: false, control: true, now: 0.02)
        guard case .magnify(let m) = b.kind else { Issue.record("not a pinch"); return }
        #expect(abs(m + 0.01) < 1e-12 && b.phase == .changed)
        #expect(s.idle(now: 0.5) == ScrollGesture(kind: .magnify(0), precise: true, phase: .ended))
    }
}
