import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct PlaybackBoundsTests {
    @Test func stopsAtEnd() {
        let b = PlaybackBounds()
        #expect(b.action(at: s(5), rate: .forward, frameDuration: fd, duration: s(10)) == .none)
        #expect(b.action(at: s(10) - fd, rate: .forward, frameDuration: fd, duration: s(10)) == .stop(at: s(10)))
    }
    @Test func loopWrapsToStart() {
        let b = PlaybackBounds(loop: true)
        #expect(b.action(at: s(10) - fd, rate: .forward, frameDuration: fd, duration: s(10)) == .wrap(to: .zero))
    }
    @Test func rangeLimitsPlayback() {
        let b = PlaybackBounds(range: TimeRange(start: s(2), end: s(4)))
        #expect(b.action(at: s(4) - fd, rate: .forward, frameDuration: fd, duration: s(10)) == .stop(at: s(4)))
        #expect(b.action(at: s(2), rate: .reverse, frameDuration: fd, duration: s(10)) == .stop(at: s(2)))
        let l = PlaybackBounds(loop: true, range: TimeRange(start: s(2), end: s(4)))
        #expect(l.action(at: s(4) - fd, rate: .forward, frameDuration: fd, duration: s(10)) == .wrap(to: s(2)))
    }
    @Test func reverseWithoutRangeIsLeftToTheEngine() {
        #expect(PlaybackBounds().action(at: .zero, rate: .reverse, frameDuration: fd, duration: s(10)) == .none)
    }
}
