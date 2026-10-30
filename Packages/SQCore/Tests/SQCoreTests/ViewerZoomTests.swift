import Foundation
import Testing
@testable import SQCore

@Suite struct ViewerZoomTests {
    let tex = CGSize(width: 1920, height: 1080)

    @Test func fitScalesToTheDrawableAndCenters() {
        let r = ViewerZoom.fit.destinationRect(textureSize: tex, drawableSize: CGSize(width: 960, height: 1000))
        #expect(r == CGRect(x: 0, y: 230, width: 960, height: 540))
    }

    @Test func percentIsDrawablePixelsPerTexturePixel() {
        let r = ViewerZoom.percent(50).destinationRect(textureSize: tex, drawableSize: CGSize(width: 1000, height: 600))
        #expect(r == CGRect(x: 20, y: 30, width: 960, height: 540))
    }

    @Test func viewPansByTheCenterOffset() {
        let r = ViewerZoom.view(scale: 1, centerX: 100, centerY: -50)
            .destinationRect(textureSize: tex, drawableSize: CGSize(width: 1920, height: 1080))
        #expect(r == CGRect(x: -100, y: 50, width: 1920, height: 1080))
    }

    @Test func emptySizesGiveZero() {
        #expect(ViewerZoom.fit.destinationRect(textureSize: .zero, drawableSize: CGSize(width: 10, height: 10)) == .zero)
    }
}
