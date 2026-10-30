import Testing
@testable import SQDrawKit

/// The Mac wheel route of the shared UI host (`MacScroll`) and the gesture side channel (`HostGesture`).
@Suite struct ScrollGestureTests {
    @Test func phaseBitsMapInTheTimelineViewOrder() {
        #expect(MacScroll.phase(raw: 0) == .none)
        #expect(MacScroll.phase(raw: 0x1) == .began)
        #expect(MacScroll.phase(raw: 0x2) == .stationary)
        #expect(MacScroll.phase(raw: 0x4) == .changed)
        #expect(MacScroll.phase(raw: 0x8) == .ended)
        #expect(MacScroll.phase(raw: 0x10) == .cancelled)
        #expect(MacScroll.phase(raw: 0x20) == .mayBegin)
        #expect(MacScroll.phase(raw: 0x1 | 0x20) == .began)       // began wins, as in TimelineView.scrollPhase
    }

    @Test func pixelsKeepTheAppKitSignAndScrollViewDistances() {
        // Trackpad: points 1:1 with the fingers, in device pixels.
        let pad = MacScroll.scroll(deltaX: -3, deltaY: 5, precise: true, phase: 0x4, momentumPhase: 0)
        #expect(MacScroll.pixels(pad, scale: 2) == (dx: -6, dy: 10))
        #expect(pad.phase == .changed && pad.momentumPhase == .none)
        // Wheel: one line is NSScrollView's 10 pt; the sign is scrollingDeltaY's (natural scrolling already applied).
        let wheel = MacScroll.scroll(deltaX: 0, deltaY: -1, precise: false, phase: 0, momentumPhase: 0)
        #expect(MacScroll.pixels(wheel, scale: 2) == (dx: 0, dy: -20))
        // A pinch moves no list.
        #expect(MacScroll.pixels(MacScroll.magnify(0.1, phase: 0x4), scale: 2) == (dx: 0, dy: 0))
    }

    @Test func withoutAHostGestureTheWheelComesFromThePixels() {
        let g = ScrollGesture.current(pixelsX: 0, pixelsY: 40)
        #expect(g == ScrollGesture(deltaY: 1))                  // one Windows notch = one Mac wheel line
        let h = HostGesture()
        let pad = ScrollGesture(deltaY: 3, precise: true, phase: .began)
        HostGesture.$current.withValue(h) {
            #expect(h.with(pad) { ScrollGesture.current(pixelsX: 0, pixelsY: 40) } == pad)
            #expect(ScrollGesture.published == nil)               // cleared after delivery
        }
    }

    @Test func aFieldStepsByTheRawWheelLinesOfTheHostGesture() {
        var f = ScrubFieldControl(value: 0)
        f.hovering = true
        let h = HostGesture()
        HostGesture.$current.withValue(h) {
            // The panel passes points (20 px at 2x for one line); the field counts the raw line, as the Mac ScrubField.
            let r = h.with(ScrollGesture(deltaY: 1)) { f.scroll(delta: 20, precise: true, modifiers: .option, focused: false, now: 0) }
            #expect(r.used && r.events == [.begin, .change(1)])
            // Shift turns a wheel sideways: deltaX counts (left-to-right increases).
            let s = h.with(ScrollGesture(deltaX: -1)) { f.scroll(delta: 0, precise: false, modifiers: .option, focused: false, now: 0.1) }
            #expect(s.events == [.change(2)])
            // A pinch steps nothing.
            #expect(h.with(ScrollGesture(kind: .magnify(0.2))) { f.scroll(delta: 0, precise: true, modifiers: .option, focused: false, now: 0.2) }.used == false)
        }
    }
}

@Suite struct ScrollCarryTests {
    @Test func slowDeltasAddUpToWholePixels() {
        var c = ScrollCarry()
        var total = 0.0
        for _ in 0..<10 { total += c.whole(0.3, scale: 1) }       // 3.0 px in 0.3 steps
        #expect(abs(total - 3) < 0.0001)
        #expect(abs(c.remainder) < 0.5)
    }

    @Test func aRetinaScreenCarriesHalfPixels() {
        var c = ScrollCarry()
        #expect(c.whole(0.2, scale: 2) == 0)
        #expect(c.whole(0.2, scale: 2) == 0.5, "0.4 pt rounds to one device pixel = 0.5 pt")
        #expect(abs(c.remainder - -0.1) < 0.0001)
    }

    @Test func negativeDeltasCarryToo() {
        var c = ScrollCarry()
        #expect(c.whole(-0.6, scale: 1) == -1)
        #expect(abs(c.remainder - 0.4) < 0.0001)
    }
}
