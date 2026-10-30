import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

/// The pill look in the Program monitor: same template (style, box) the export burn-in builds, so the same pill rect.
@Suite struct CaptionPillPreviewTests {
    let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))

    @Test func previewTemplateCarriesThePill() throws {
        let item = CaptionItem(lines: ["Wow"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: CaptionPill.styleID)
        let t = CaptionPreview.template(for: item, canvas: canvas)
        let bg = try #require(t.style.background)
        #expect(bg == CaptionPresetLibrary.builtIn.style(for: "pill").background)
    }

    /// Burn-in builds `CaptionLayout.template` with `CaptionPlacement.bottomSafeArea.maxWidthFraction`; the preview's pill
    /// rect must equal the one laid out from that template.
    @Test func previewPillRectEqualsBurnInPillRect() throws {
        let item = CaptionItem(lines: ["Wow"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: CaptionPill.styleID)
        let p = CaptionPreview.template(for: item, canvas: canvas)
        let b = CaptionLayout.template(text: "Wow", style: CaptionPresetLibrary.builtIn.style(for: "pill"),
                                       canvasWidth: 1080, canvasHeight: 1920, widthFraction: 0.86)
        func rect(_ t: TextTemplate) -> TextRect? {
            CaptionPill.rect(of: TextLayout.layout(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
        }
        #expect(rect(p) != nil)
        #expect(rect(p) == rect(b))
    }
}
