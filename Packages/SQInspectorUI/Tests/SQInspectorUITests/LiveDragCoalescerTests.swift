import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI
@testable import SQUIKit

/// Manual clock and scheduler for `LiveDragCoalescer`.
@MainActor final class FakeFrameClock {
    var t: TimeInterval = 100
    var queued: [(at: TimeInterval, body: @MainActor () -> Void)] = []

    func install(on c: LiveDragCoalescer) {
        c.now = { [unowned self] in t }
        c.schedule = { [unowned self] delay, body in queued.append((t + delay, body)) }
    }

    /// Moves time on and runs what came due.
    func advance(_ s: TimeInterval) {
        t += s
        let due = queued.filter { $0.at <= t }
        queued.removeAll { $0.at <= t }
        for d in due { d.body() }
    }
}

@MainActor @Suite struct LiveDragCoalescerTests {
    @Test func firstValueAtOnceThenOnePerFrameWithTheNewest() {
        var out: [Double] = []
        let c = LiveDragCoalescer { out.append($0) }
        let clock = FakeFrameClock(); clock.install(on: c)
        c.begin()
        c.submit(1)
        #expect(out == [1])
        c.submit(2); c.submit(3); c.submit(4)
        #expect(out == [1])                     // same frame: waiting
        clock.advance(LiveDragCoalescer.frame)
        #expect(out == [1, 4])                  // the newest only
        clock.advance(1)
        c.submit(5)
        #expect(out == [1, 4, 5])               // a frame has passed: at once
    }

    @Test func flushSendsTheWaitingValueOnce() {
        var out: [Double] = []
        let c = LiveDragCoalescer { out.append($0) }
        let clock = FakeFrameClock(); clock.install(on: c)
        c.begin()
        c.submit(1); c.submit(2)
        c.flush()
        #expect(out == [1, 2])
        clock.advance(1)                        // the scheduled flush finds nothing left
        #expect(out == [1, 2])
        c.flush()
        #expect(out == [1, 2])
    }

    @Test func dropForgetsTheWaitingValueAndAStaleTimer() {
        var out: [Double] = []
        let c = LiveDragCoalescer { out.append($0) }
        let clock = FakeFrameClock(); clock.install(on: c)
        c.begin()
        c.submit(1); c.submit(2)
        c.drop()
        clock.advance(1)
        #expect(out == [1])
        c.begin()                               // next drag starts fresh
        c.submit(7)
        #expect(out == [1, 7])
    }

    // MARK: ScrubField

    func field(_ clock: FakeFrameClock) -> ScrubField {
        let f = ScrubField()
        f.range = 0...1000
        f.value = 0
        clock.install(on: f.liveCoalescer)
        return f
    }

    @Test func scrubDragHandsOffPerFrameAndEndsOnTheExactValue() {
        let clock = FakeFrameClock()
        let f = field(clock)
        var log: [String] = []
        var live: [Double] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("change \($0)") }
        f.onEnd = { log.append("end \($0)") }
        f.onLiveValue = { live.append($0) }
        f.beginDragForTesting()
        for _ in 0..<100 { f.dragForTesting(pixels: 1) }
        #expect(f.value == 100)
        #expect(live.count == 100)              // the control itself follows every event
        f.endDragForTesting()
        #expect(log == ["begin", "change 1.0", "change 100.0", "end 100.0"])
    }

    @Test func scrubDragAcrossFramesSendsTheNewestPerFrame() {
        let clock = FakeFrameClock()
        let f = field(clock)
        var changes: [Double] = []
        f.onChange = { changes.append($0) }
        f.beginDragForTesting()
        for i in 0..<12 {
            f.dragForTesting(pixels: 1)
            if i % 4 == 3 { clock.advance(LiveDragCoalescer.frame) }
        }
        f.endDragForTesting()
        #expect(changes == [1, 4, 8, 12])
    }

    @Test func escapeDuringACoalescedDragRestoresWithoutTheWaitingValue() {
        let clock = FakeFrameClock()
        let f = field(clock)
        f.value = 40
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("change \($0)") }
        f.onEnd = { log.append("end \($0)") }
        f.beginDragForTesting()
        f.dragForTesting(pixels: 1); f.dragForTesting(pixels: 1); f.dragForTesting(pixels: 1)
        f.cancelGesture()
        clock.advance(1)
        #expect(f.value == 40)
        #expect(log == ["begin", "change 41.0", "change 40.0", "end 40.0"])
    }

    // MARK: SQSlider / NumericSlider

    @Test func sliderDragHandsOffPerFrameAndEndsOnTheExactValue() {
        let clock = FakeFrameClock()
        let s = SQSlider(value: 0, minValue: 0, maxValue: 100)
        clock.install(on: s.liveCoalescer)
        var log: [String] = []
        s.onBegin = { log.append("begin") }
        s.onChange = { log.append("change \($0)") }
        s.onEnd = { log.append("end \($0)") }
        s.trackBegan()
        for i in 1...50 { s.trackMoved(to: Double(i)) }
        s.trackEnded(cancelled: false)
        #expect(s.doubleValue == 50)
        #expect(log == ["begin", "change 1.0", "change 50.0", "end 50.0"])
    }

    @Test func sliderEscapeReturnsToTheStart() {
        let clock = FakeFrameClock()
        let s = SQSlider(value: 10, minValue: 0, maxValue: 100)
        clock.install(on: s.liveCoalescer)
        var log: [String] = []
        s.onChange = { log.append("change \($0)") }
        s.onEnd = { log.append("end \($0)") }
        s.trackBegan()
        for i in 11...20 { s.trackMoved(to: Double(i)) }
        s.trackEnded(cancelled: true)
        clock.advance(1)
        #expect(s.doubleValue == 10)
        #expect(log == ["change 11.0", "change 10.0", "end 10.0"])
    }

    @Test func numericSliderMirrorsEveryStepAndHandsOffPerFrame() {
        let clock = FakeFrameClock()
        let n = NumericSlider(value: 0, range: 0...100)
        clock.install(on: n.slider.liveCoalescer)
        var changes: [Double] = [], ends: [Double] = []
        n.onChange = { changes.append($0) }
        n.onEnd = { ends.append($0) }
        n.slider.trackBegan()
        for i in 1...30 {
            n.slider.trackMoved(to: Double(i))
            #expect(n.field.value == Double(i))     // the number follows the thumb live
        }
        n.slider.trackEnded(cancelled: false)
        #expect(changes == [1, 30])
        #expect(ends == [30])
    }

    // MARK: Color page slider

    @Test func colorSliderDragHandsOffPerFrame() {
        let clock = FakeFrameClock()
        let s = LumetriSlider()
        s.minValue = -100; s.maxValue = 100; s.step = 1
        clock.install(on: s.liveCoalescer)
        var log: [String] = []
        s.onBegin = { log.append("begin") }
        s.onChange = { log.append("change \($0)") }
        s.onEnd = { log.append("end") }
        s.dragBeganForTesting()
        for i in 1...40 { s.dragForTesting(to: Double(i)) }
        s.dragEndedForTesting()
        #expect(s.value == 40)
        #expect(log == ["begin", "change 1.0", "change 40.0", "end"])
    }

    // MARK: Esc after moving back to the start inside one frame (owner holds the last sent value)

    @Test func scrubEscapeBackAtTheStartStillResendsIt() {
        let clock = FakeFrameClock()
        let f = field(clock)
        f.value = 40
        var log: [String] = []
        f.onChange = { log.append("change \($0)") }
        f.onEnd = { log.append("end \($0)") }
        f.beginDragForTesting()
        f.dragForTesting(pixels: 5)             // 45, sent at once
        f.dragForTesting(pixels: -5)            // 40 again: the value waits for the frame
        f.cancelGesture()
        clock.advance(1)
        #expect(f.value == 40)
        #expect(log == ["change 45.0", "change 40.0", "end 40.0"])
    }

    @Test func sliderEscapeBackAtTheStartStillResendsIt() {
        let clock = FakeFrameClock()
        let s = SQSlider(value: 10, minValue: 0, maxValue: 100)
        clock.install(on: s.liveCoalescer)
        var log: [String] = []
        s.onChange = { log.append("change \($0)") }
        s.onEnd = { log.append("end \($0)") }
        s.trackBegan()
        s.trackMoved(to: 30)
        s.trackMoved(to: 10)
        s.trackEnded(cancelled: true)
        clock.advance(1)
        #expect(s.doubleValue == 10)
        #expect(log == ["change 30.0", "change 10.0", "end 10.0"])
    }

    @Test func colorSliderEscapeBackAtTheStartStillResendsIt() {
        let clock = FakeFrameClock()
        let s = LumetriSlider()
        s.minValue = -100; s.maxValue = 100; s.step = 1
        clock.install(on: s.liveCoalescer)
        var log: [String] = []
        s.onChange = { log.append("change \($0)") }
        s.onEnd = { log.append("end") }
        s.dragBeganForTesting()
        s.dragForTesting(to: 30)
        s.dragForTesting(to: 0)
        s.cancelDrag()
        clock.advance(1)
        #expect(s.value == 0)
        #expect(log == ["change 30.0", "change 0.0", "end"])
    }
}
