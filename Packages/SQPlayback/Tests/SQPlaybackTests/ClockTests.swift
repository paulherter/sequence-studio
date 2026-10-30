import Testing
import Foundation
import Synchronization
import SQCore
@testable import SQPlayback

private final class FakeNs: Sendable {
    private let m = Mutex<Int64>(0)
    func get() -> Int64 { m.withLock { $0 } }
    func add(_ d: Int64) { m.withLock { $0 += d } }
}

@Suite struct ManualClockTests {
    @Test func startsPausedAtZero() {
        let c = ManualClock()
        c.advance(by: Time(5, 1))
        #expect(c.now() == .zero)
        #expect(c.rate == .zero)
    }

    @Test func rateOne() {
        let c = ManualClock(position: Time(10, 1), rate: .forward)
        c.advance(by: Time(1001, 30000))
        #expect(c.now() == Time(10, 1) + Time(1001, 30000))
    }

    @Test func rateMinusOne() {
        let c = ManualClock(position: Time(10, 1), rate: .reverse)
        c.advance(by: Time(1001, 30000))
        #expect(c.now() == Time(10, 1) - Time(1001, 30000))
        c.advance(by: Time(20, 1))
        #expect(c.now() == Time(-10, 1) - Time(1001, 30000))
    }

    @Test func rateQuarter() {
        let c = ManualClock(position: .zero, rate: PlaybackRate(1, 4))
        c.advance(by: Time(1, 1))
        #expect(c.now() == Time(1, 4))
        c.advance(by: Time(1, 3))
        #expect(c.now() == Time(1, 4) + Time(1, 12))
    }

    @Test func rateEight() {
        let c = ManualClock(position: Time(1, 1), rate: PlaybackRate(8))
        c.advance(by: Time(1001, 24000))
        #expect(c.now() == Time(1, 1) + Time(1001, 3000))
    }

    @Test func rateChangeKeepsPositionContinuous() {
        let c = ManualClock(position: .zero, rate: .forward)
        c.advance(by: Time(2, 1))
        let before = c.now()
        c.setRate(PlaybackRate(1, 4))
        #expect(c.now() == before)
        c.advance(by: Time(4, 1))
        #expect(c.now() == Time(3, 1))
        c.setRate(.reverse)
        c.advance(by: Time(1, 2))
        #expect(c.now() == Time(5, 2))
    }

    @Test func seekReanchorsKeepingRate() {
        let c = ManualClock(position: .zero, rate: PlaybackRate(8))
        c.advance(by: Time(1, 1))
        c.seek(to: Time(100, 1))
        #expect(c.now() == Time(100, 1))
        #expect(c.rate == PlaybackRate(8))
        c.advance(by: Time(1, 8))
        #expect(c.now() == Time(101, 1))
    }

    @Test func stopHoldsAndReturnsPosition() {
        let c = ManualClock(position: .zero, rate: .forward)
        c.advance(by: Time(3, 2))
        #expect(c.stop() == Time(3, 2))
        c.advance(by: Time(10, 1))
        #expect(c.now() == Time(3, 2))
        #expect(c.rate.isPaused)
    }

    @Test func startReanchors() {
        let c = ManualClock()
        c.advance(by: Time(7, 1))
        c.start(at: Time(2, 1), rate: .forward)
        c.advance(by: Time(1, 1))
        #expect(c.now() == Time(3, 1))
    }

    @Test func rateZeroHolds() {
        let c = ManualClock(position: Time(4, 1), rate: .zero)
        c.advance(by: Time(9, 1))
        #expect(c.now() == Time(4, 1))
    }
}

@Suite(.serialized) struct HostClockTests {
    /// 1 s sleep: the clock must match an independent wall measurement (ContinuousClock) of the same
    /// interval within 5 ms. Comparing against a measured interval, not the nominal 1 s, keeps scheduler
    /// oversleep from counting as clock error.
    @Test func oneSecondWithinTwoMs() {
        let c = HostClock()
        let w0 = ContinuousClock.now
        c.start(at: .zero, rate: .forward)
        Thread.sleep(forTimeInterval: 1.0)
        let pos = c.now()
        let wall = ContinuousClock.now - w0
        let posNs = Int128(pos.value) * 1_000_000_000 / Int128(pos.timescale)
        let wallNs = Int128(wall.components.seconds) * 1_000_000_000 + Int128(wall.components.attoseconds / 1_000_000_000)
        #expect(posNs >= 1_000_000_000 - 5_000_000)
        #expect(abs(posNs - wallNs) < 5_000_000, "clock \(posNs) ns vs wall \(wallNs) ns")
    }

    @Test func rateChangeContinuousWithFakeSource() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        c.start(at: Time(10, 1), rate: .forward)
        ns.add(1_500_000_000)
        #expect(c.now() == Time(23, 2))
        c.setRate(PlaybackRate(1, 4))
        #expect(c.now() == Time(23, 2))
        ns.add(4_000_000_000)
        #expect(c.now() == Time(25, 2))
        c.setRate(PlaybackRate(-8))
        ns.add(500_000_000)
        #expect(c.now() == Time(17, 2))
        #expect(c.stop() == Time(17, 2))
        ns.add(1_000_000_000)
        #expect(c.now() == Time(17, 2))
    }

    @Test func rateChangeRoundsOnlyTheElapsedDelta() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        c.start(at: .zero, rate: PlaybackRate(1, 3))
        ns.add(1_000)                       // 1000/3 ns = 333.33 ns
        c.setRate(.forward)
        #expect(c.now() == Time(333, 1_000_000_000))
    }

    @Test func seekThenStopKeepsExactPosition() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        let p = Time(1001, 30000) * 2
        c.start(at: .zero, rate: .forward)
        c.seek(to: p)
        #expect(c.stop() == p)
        #expect(c.now() == p)
    }

    @Test func seekThenSetRateKeepsExactPosition() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        let p = Time(1001, 30000) * 2
        c.start(at: .zero, rate: .forward)
        c.seek(to: p)
        c.setRate(PlaybackRate(1, 4))
        #expect(c.now() == p)
    }

    @Test func pausedClockNeverRounds() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        let p = Time(1001, 30000) * 2
        c.start(at: p, rate: .zero)
        ns.add(987_654_321)
        c.setRate(.zero)
        #expect(c.stop() == p)
    }

    @Test func stopAfterSeekStaysOnFrameBoundary() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        let fd = Time(1001, 30000)
        c.start(at: fd * 2, rate: .forward)
        let stopped = c.stop()                        // zero elapsed
        #expect(stopped.frameIndex(frameDuration: fd) == 2)
    }

    @Test func seekKeepsExactPositionAndRate() {
        let ns = FakeNs()
        let c = HostClock(nanosecondSource: { ns.get() })
        c.start(at: .zero, rate: .forward)
        ns.add(123)
        c.seek(to: Time(1001, 30000))
        #expect(c.now() == Time(1001, 30000))
        #expect(c.rate == .forward)
    }

    @Test func clocksAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(HostClock.self)
        requireSendable(ManualClock.self)
    }
}
