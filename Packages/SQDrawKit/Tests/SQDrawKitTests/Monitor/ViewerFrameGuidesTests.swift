import Foundation
import Testing
import SQCore
@testable import SQDrawKit

@Suite struct ViewerFrameGuidesTests {
    @Test func verticalFrameInsideLandscapePicture() {
        let r = AspectFrame.vertical9x16.rect(in: CGRect(x: 10, y: 20, width: 1600, height: 900))!
        #expect(abs(r.height - 900) < 0.001 && abs(r.width - 506.25) < 0.001)
        #expect(abs(r.midX - 810) < 0.001 && abs(r.midY - 470) < 0.001)
    }

    @Test func wideFrameInsideVerticalPicture() {
        let r = AspectFrame.wide16x9.rect(in: CGRect(x: 0, y: 0, width: 900, height: 1600))!
        #expect(abs(r.width - 900) < 0.001 && abs(r.height - 506.25) < 0.001)
        #expect(abs(r.midY - 800) < 0.001)
    }

    @Test func squareAndPortraitFit() {
        let s = AspectFrame.square1x1.rect(in: CGRect(x: 0, y: 0, width: 1920, height: 1080))!
        #expect(s.width == 1080 && s.height == 1080)
        let p = AspectFrame.portrait4x5.rect(in: CGRect(x: 0, y: 0, width: 1920, height: 1080))!
        #expect(abs(p.width - 864) < 0.001 && p.height == 1080)
        #expect(AspectFrame.off.rect(in: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        #expect(AspectFrame.square1x1.rect(in: .zero) == nil)
    }

    @Test func safeMarginSizesClampAndKeepTitleInsideAction() {
        #expect(SafeMarginSizes.default.fractions == [0.9, 0.8])
        let s = SafeMarginSizes.default.settingAction(70).settingTitle(85)
        #expect(s.action == 70 && s.title == 70)
        #expect(SafeMarginSizes.default.settingAction(95).title == 80)
        #expect(SafeMarginSizes(action: 10, title: 10).action == 50)
        #expect(SafeMarginSizes.default.settingAction(75).title == 75)
    }
}

