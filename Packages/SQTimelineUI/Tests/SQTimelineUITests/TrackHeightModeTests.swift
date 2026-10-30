import Testing
import SQCore
@testable import SQTimelineUI

@Suite struct TrackHeightModeTests {
    private func timeline() -> Timeline {
        Timeline(name: "t", frameDuration: Time(1, 25), tracks: [Track(kind: .video), Track(kind: .audio)])
    }

    @Test func smallIsThinAndDoesNotStretch() {
        var g = TimelineGeometry(frameDuration: Time(1, 25), pointsPerSecond: 50)
        g.viewportHeight = 900
        g.heightMode = .small
        #expect(g.rows(for: timeline()).allSatisfy { $0.height == 24 })
    }

    @Test func largeIsTallerAndAutoStretches() {
        var g = TimelineGeometry(frameDuration: Time(1, 25), pointsPerSecond: 50)
        g.viewportHeight = 900
        g.heightMode = .large
        #expect(g.rows(for: timeline()).map(\.height) == [72, 56])
        g.heightMode = .auto
        #expect(g.rows(for: timeline()).map(\.height).reduce(0, +) > 128)
    }
}
