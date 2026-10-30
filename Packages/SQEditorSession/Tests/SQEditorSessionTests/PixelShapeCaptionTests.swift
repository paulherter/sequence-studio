import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

// Captions on a non-square sequence (1440x1080 at 4:3, display 1920x1080): hit test, edit box and Cut Check read the
// display canvas, so they agree with a square 1920x1080 sequence.
@MainActor @Suite struct PixelShapeCaptionTests {
    private let shaped: SequenceFormat = {
        var f = SequenceFormat(width: 1440, height: 1080, frameDuration: Time(1, 30))
        f.pixelAspect = PixelAspect(4, 3)!
        return f
    }()
    private let square = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
    private let item = CaptionItem(lines: ["Pixel Shape"], range: TimeRange(start: .zero, end: Time(2, 1)), styleRef: "default")

    @Test func editBoxAndTextRectFollowTheDisplayCanvas() {
        #expect(shaped.displayWidth == 1920)
        let a = CaptionMonitorHit.editBox(canvas: shaped), b = CaptionMonitorHit.editBox(canvas: square)
        #expect(a.centre == b.centre && a.box.width == b.box.width && a.box.height == b.box.height)
        #expect(CaptionMonitorHit.textRect(of: item, canvas: shaped) == CaptionMonitorHit.textRect(of: item, canvas: square))
    }

    @Test func hitTestUsesTheDisplayCanvas() {
        var tl = Timeline(name: "T", format: shaped)
        tl.captionTracks = [CaptionTrack(items: [item])]
        let r = CaptionMonitorHit.textRect(of: item, canvas: shaped)
        let p = Vec2(Double(r.midX), Double(r.midY))
        #expect(CaptionMonitorHit.caption(at: p, in: tl, time: Time(1, 1)) == item.id)
        #expect(CaptionMonitorHit.caption(at: Vec2(Double(r.midX), Double(r.midY) - 400), in: tl, time: Time(1, 1)) == nil)
    }

    @Test func cutCheckBoxIsTheSquareSequencesBox() {
        let a = EditorSession.captionBox(item, canvas: shaped), b = EditorSession.captionBox(item, canvas: square)
        #expect(a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height)
    }

    @Test func squareIsUnchanged() {
        #expect(square.layoutFormat == square)
    }
}
