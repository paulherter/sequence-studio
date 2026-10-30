import Foundation
import Testing
@testable import SQCore

@Suite struct PlaybackNudgeTests {
    @Test func startsAtFiveQuartersFromStop() {
        #expect(PlaybackRate.zero.nudged(forward: true) == PlaybackRate(5, 4))
        #expect(PlaybackRate.zero.nudged(forward: false) == PlaybackRate(-5, 4))
    }
    @Test func speedsUpInOwnDirectionAndSlowsAgainstIt() {
        #expect(PlaybackRate(1).nudged(forward: true) == PlaybackRate(5, 4))
        #expect(PlaybackRate(5, 4).nudged(forward: true) == PlaybackRate(3, 2))
        #expect(PlaybackRate(2).nudged(forward: false) == PlaybackRate(7, 4))
        #expect(PlaybackRate(-1).nudged(forward: false) == PlaybackRate(-5, 4))
    }
    @Test func stopsWhenSlowedToZeroAndCapsAtEight() {
        #expect(PlaybackRate(1, 4).nudged(forward: false) == .zero)
        #expect(PlaybackRate(8).nudged(forward: true) == PlaybackRate(8))
    }
}
