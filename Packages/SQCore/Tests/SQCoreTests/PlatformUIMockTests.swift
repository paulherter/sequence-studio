import Testing
@testable import SQCore

@Suite struct PlatformUIMockTests {
    @Test func onlyVerticalPlatformsHaveAMock() {
        #expect(SafeZoneChoice.allCases.filter(\.hasUIMock) == [.tiktok, .reels, .shorts])
        #expect(SafeZoneChoice.youtube.uiMock(frameAspect: 9.0 / 16).isEmpty)
        #expect(SafeZoneChoice.off.uiMock(frameAspect: 9.0 / 16).isEmpty)
    }

    @Test(arguments: [SafeZoneChoice.tiktok, .reels, .shorts], [9.0 / 16, 1.0, 16.0 / 9])
    func elementsStayInsideTheFrameOutsideTheZoneAndRoundButtonsAreRound(choice: SafeZoneChoice, aspect: Double) throws {
        let zone = try #require(choice.normRect(frameAspect: aspect))
        let els = choice.uiMock(frameAspect: aspect)
        let frame = NormRect(x: 0, y: 0, width: 1, height: 1)
        for e in els {
            #expect(frame.contains(e.rect), "\(choice) \(aspect) \(e.kind) leaves the frame")
            if e.kind != .progressBar {
                let overlapsZone = e.rect.x < zone.x + zone.width - 0.001 && e.rect.x + e.rect.width > zone.x + 0.001
                    && e.rect.y < zone.y + zone.height - 0.001 && e.rect.y + e.rect.height > zone.y + 0.001
                #expect(!overlapsZone, "\(choice) \(aspect) \(e.kind) covers the clear zone")
            }
            if e.isRoundButton { #expect(abs(e.rect.height - e.rect.width * aspect) < 1e-9) }
        }
        #expect(els.filter(\.isRoundButton).count == 5)
    }

    @Test func aFullFrameZoneLeavesNothingToDraw() {
        #expect(PlatformUIMock.elements(zone: NormRect(x: 0, y: 0, width: 1, height: 1), frameAspect: 9.0 / 16).isEmpty)
    }
}
