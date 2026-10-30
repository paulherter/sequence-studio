import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// While playing, a layer drawn at half its native size or less is decoded at half (a quarter or less: at a quarter):
/// the picture still has every pixel the composite samples.
@Suite struct PlaybackLayerDetailTests {
    private func layer(scale: Double, tilt: Double = 0, groups: [Double] = []) -> LayerRequest {
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero,
                             transform: ClipTransform(scale: Vec2(scale, scale)))
        r.transform.tiltX = tilt
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        r.groups = groups.map { LayerGroup(clip: UUID(), track: UUID(), sequence: UUID(), format: f,
                                           transform: ClipTransform(scale: Vec2($0, $0))) }
        return r
    }

    @Test func aFourKClipAtHalfScaleDecodesAtHalf() {
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.5)) == 2)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.50156)) == 2)    // within the 10 % margin
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.26)) == 4)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.19)) == 4)
    }

    @Test func fullSizeAndLargerLayersKeepEveryPixel() {
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 1)) == 1)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.6)) == 1)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.3)) == 2)
    }

    @Test func groupsMultiplyAndTiltKeepsFullDetail() {
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 1, groups: [0.5])) == 2)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.5, groups: [2])) == 1)
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: 0.5, tilt: 20)) == 1)
        // The bigger axis decides (a squeezed layer keeps the detail of its long side).
        var wide = layer(scale: 0.5)
        wide.transform.scale = Vec2(1, 0.4)
        #expect(PlaybackLayerDetail.divisor(for: wide) == 1)
        // Mirrored (negative scale) counts by size.
        #expect(PlaybackLayerDetail.divisor(for: layer(scale: -0.5)) == 2)
    }
}
