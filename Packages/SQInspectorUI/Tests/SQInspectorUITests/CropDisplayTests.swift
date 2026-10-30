import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Crop is stored as percent of the picture and shown in px of the clip's own picture (display boundary only).
@Suite struct CropDisplayTests {
    private func crop(_ key: String) -> EffectProperty { .fx(UUID(), kind: ClipEffect.cropKind, key: key) }
    private let hd = Vec2(1920, 1080)

    @Test func widthAxisRowsUsePictureWidth() {
        let left = crop(ClipEffect.cropLeftKey), right = crop(ClipEffect.cropRightKey)
        #expect(left.display(10, picture: hd) == 192)
        #expect(right.display(50, picture: hd) == 960)
        #expect(left.native(fromDisplay: 192, picture: hd) == 10)
        #expect(left.displayUnit(picture: hd) == "px")
        #expect(left.displayRange(picture: hd) == 0...1920)
    }

    @Test func heightAxisRowsUsePictureHeight() {
        let top = crop(ClipEffect.cropTopKey), bottom = crop(ClipEffect.cropBottomKey)
        #expect(top.display(10, picture: hd) == 108)
        #expect(bottom.native(fromDisplay: 540, picture: hd) == 50)
        #expect(top.displayRange(picture: hd) == 0...1080)
    }

    @Test func roundTripAndPortraitPicture() {
        let p = crop(ClipEffect.cropLeftKey), portrait = Vec2(1080, 1920)
        for m in stride(from: 0.0, through: 100, by: 12.5) {
            #expect(abs(p.native(fromDisplay: p.display(m, picture: portrait), picture: portrait) - m) < 1e-9)
        }
        #expect(p.display(10, picture: portrait) == 108)
    }

    @Test func unknownPictureKeepsPercent() {
        let p = crop(ClipEffect.cropLeftKey)
        #expect(p.display(10) == 10)
        #expect(p.displayUnit(picture: nil) == "%")
        #expect(p.displayRange(picture: nil) == 0...100)
        #expect(p.native(fromDisplay: 10) == 10)
    }

    @Test func clampStaysInsidePicture() {
        let p = crop(ClipEffect.cropRightKey)
        #expect(p.clampedNative(150, picture: hd) == 100)
        #expect(p.clampedNative(-5, picture: hd) == 0)
    }

    @Test func softnessIsNotPictureRelative() {
        let s = crop(ClipEffect.cropSoftnessKey)
        #expect(s.display(12, picture: hd) == 12)
        #expect(s.displayUnit(picture: hd) == "px")
    }

    @Test func otherRowsIgnorePicture() {
        #expect(EffectProperty.position.display(40, component: .y, picture: hd) == -40)
        #expect(EffectProperty.opacity.display(0.5, picture: hd) == 50)
    }
}
