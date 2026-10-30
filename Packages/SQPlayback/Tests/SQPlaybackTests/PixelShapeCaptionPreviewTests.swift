import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

// The monitor lays a caption out in the display canvas of a non-square sequence (1440x1080 at 4:3 = 1920x1080).
@Suite struct PixelShapeCaptionPreviewTests {
    @Test func previewPositionAndTemplateMatchTheDisplayCanvas() {
        var shaped = SequenceFormat(width: 1440, height: 1080, frameDuration: Time(1, 30))
        shaped.pixelAspect = PixelAspect(4, 3)!
        let square = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let item = CaptionItem(lines: ["Pixel Shape"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: "default")
        #expect(CaptionPreview.position(for: item, canvas: shaped) == CaptionPreview.position(for: item, canvas: square))
        #expect(CaptionPreview.template(for: item, canvas: shaped) == CaptionPreview.template(for: item, canvas: square))
    }
}
