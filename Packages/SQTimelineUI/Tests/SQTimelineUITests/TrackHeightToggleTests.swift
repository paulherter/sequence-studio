#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

/// Parity audit 17: double-click on an empty header area toggles the track between two heights (Shift: every track of its kind).
@Suite struct TrackHeightToggleTests {
    private func rows(_ heights: [(TrackKind, CGFloat)]) -> [TrackRow] {
        var y: CGFloat = 0
        return heights.enumerated().map { i, h in
            defer { y += h.1 }
            return TrackRow(track: UUID(), kind: h.0, label: "\(i)", y: y, height: h.1)
        }
    }

    @Test func smallerTrackGrowsToLargeAndLargeGoesBackToMedium() {
        let r = rows([(.video, 40), (.audio, 28)])
        let grown = TrackSizing.toggled(rows: r, track: r[0].track, wholeKind: false)
        #expect(grown[r[0].track] == TrackHeightMode.large.height(kind: .video))
        #expect(grown[r[1].track] == 28)                         // other rows stay as drawn
        let back = TrackSizing.toggled(rows: rows([(.video, 72), (.audio, 28)]).enumerated().map { i, x in
            var x = x; x.track = r[i].track; return x
        }, track: r[0].track, wholeKind: false)
        #expect(back[r[0].track] == TrackHeightMode.medium.height(kind: .video))
    }

    @Test func minimizedTrackGrowsToLarge() {
        let r = rows([(.audio, TrackSizing.minimizedHeight)])
        #expect(TrackSizing.toggled(rows: r, track: r[0].track, wholeKind: false)[r[0].track] == TrackHeightMode.large.height(kind: .audio))
    }

    @Test func shiftAppliesToEveryTrackOfTheKindOnly() {
        let r = rows([(.video, 40), (.video, 50), (.audio, 28)])
        let out = TrackSizing.toggled(rows: r, track: r[0].track, wholeKind: true)
        #expect(out[r[0].track] == 72 && out[r[1].track] == 72 && out[r[2].track] == 28)
    }

    @Test func unknownTrackChangesNothing() {
        let r = rows([(.video, 40)])
        #expect(TrackSizing.toggled(rows: r, track: UUID(), wholeKind: false) == TrackSizing.frozen(r))
    }
}
