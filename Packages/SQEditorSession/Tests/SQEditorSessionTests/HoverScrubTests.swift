import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@Suite struct HoverScrubTests {
    private let fd = Time(1, 30)

    @Test func fractionMapsToFrameAlignedTime() {
        let d = Time(10, 1)
        #expect(HoverScrub.time(fraction: 0, duration: d, frameDuration: fd) == .zero)
        #expect(HoverScrub.time(fraction: 0.5, duration: d, frameDuration: fd) == Time(5, 1))
        let t = HoverScrub.time(fraction: 0.333, duration: d, frameDuration: fd)
        #expect(t == t.snapped(to: fd))
    }

    @Test func neverPastLastFrameAndClamps() {
        let d = Time(10, 1)
        #expect(HoverScrub.time(fraction: 1, duration: d, frameDuration: fd) == d - fd)
        #expect(HoverScrub.time(fraction: 7, duration: d, frameDuration: fd) == d - fd)
        #expect(HoverScrub.time(fraction: -3, duration: d, frameDuration: fd) == .zero)
        #expect(HoverScrub.time(fraction: 0.5, duration: .zero, frameDuration: fd) == .zero)
    }

    @Test func posterIsEarlyAndCapped() {
        #expect(HoverScrub.poster(duration: Time(10, 1), frameDuration: fd) == Time(1, 1))
        #expect(HoverScrub.poster(duration: Time(600, 1), frameDuration: fd) == Time(2, 1))
    }
}
