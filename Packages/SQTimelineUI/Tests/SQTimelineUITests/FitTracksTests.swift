import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@MainActor
struct FitTracksTests {
    @Test func fitSharesTheHeightByWeight() {
        let h = TrackSizing.fitHeights(weights: [3, 2], available: 250)
        #expect(abs(h[0] - 150) < 0.01 && abs(h[1] - 100) < 0.01)
    }

    @Test func fitClampsAndRedistributes() {
        let big = TrackSizing.fitHeights(weights: [1, 1, 1, 1], available: 1200)
        #expect(big.allSatisfy { $0 == TrackSizing.maxHeight })
        let tight = TrackSizing.fitHeights(weights: Array(repeating: 1, count: 20), available: 100)
        #expect(tight.allSatisfy { $0 == TrackSizing.minimizedHeight })
        let mix = TrackSizing.fitHeights(weights: [100, 1], available: 300)
        #expect(mix[0] == TrackSizing.maxHeight && abs(mix[1] - 60) < 0.01)
        #expect(TrackSizing.fitHeights(weights: [], available: 100).isEmpty)
    }

    @Test func fitFillsTheAreaWhenItFits() {
        let h = TrackSizing.fitHeights(weights: [3, 3, 2, 2, 2], available: 400)
        #expect(abs(h.reduce(0, +) - 400) < 0.01)
    }

    private func makeView(height: CGFloat) -> TimelineView {
        let fd = Time(1, 24)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: height))
    }

    @Test func fitFollowsPanelHeightAndFreezesWhenTurnedOff() {
        let v = makeView(height: 300)
        var notified: [Bool] = []
        v.onFitTracksChange = { notified.append($0) }
        v.setFitsTracks(true)
        let a = v.layoutRows().map(\.height)
        v.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        let b = v.layoutRows().map(\.height)
        #expect(b.reduce(0, +) > a.reduce(0, +))
        v.setFitsTracks(false)
        #expect(v.layoutRows().map(\.height) == b && !v.fitsTracks)
        #expect(notified == [true, false])
    }

    @Test func manualStepTurnsFitOff() {
        let v = makeView(height: 300)
        v.setFitsTracks(true)
        v.sizeTracks(nil, direction: 1)
        #expect(!v.fitsTracks)
    }
}
