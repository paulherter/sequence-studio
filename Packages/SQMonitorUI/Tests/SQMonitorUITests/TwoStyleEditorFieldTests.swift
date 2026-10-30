import AppKit
import Testing
import SQCore
import SQText
@testable import SQMonitorUI

/// N4 review: the in-place text field over a two-style text keeps each paragraph in its own font while typing.
@MainActor @Suite struct TwoStyleEditorFieldTests {
    func style() -> TextStyle {
        var s = TextStyle(fontName: "Helvetica", size: 20)
        s.secondLine = TextLineStyle(fontName: "Helvetica", size: 60, weight: .bold, color: .white)
        return s
    }

    func surface(width: CGFloat) -> ProgramSurfaceView {
        let v = ProgramSurfaceView(viewer: NSView())
        v.frame = NSRect(x: 0, y: 0, width: width, height: width * 9 / 16)
        v.sequenceSize = CGSize(width: 1920, height: 1080)
        return v
    }

    let target = OverlayTarget(clip: UUID(), size: CGSize(width: 200, height: 100), isText: true,
                               baseTransform: ClipTransform(), shift: .zero, positionTrack: KeyframeTrack<Vec2>())

    func sizes(_ tv: NSTextView) -> [CGFloat] {
        let ts = tv.textStorage!
        let f0 = ts.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let f1 = ts.attribute(.font, at: ts.length - 1, effectiveRange: nil) as! NSFont
        return [f0.pointSize, f1.pointSize].map { ($0 * 100).rounded() / 100 }
    }

    func type(_ s: String, at loc: Int, in tv: NSTextView) {
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.insertText(s, replacementRange: tv.selectedRange())    }

    @Test func typingInEitherParagraphKeepsBothFonts() throws {
        let v = surface(width: 960)                            // half size: 10 pt and 30 pt
        v.beginTextEditing(text: "small\nBIG", style: style(), target: target, selectAll: false)
        let tv = try #require(v.textEditor)
        let start = sizes(tv)
        #expect(start[1] > start[0] * 2.5)
        type("X", at: (tv.string as NSString).length, in: tv)   // in paragraph 2
        #expect(tv.string == "small\nBIGX")
        #expect(sizes(tv) == start)
        type("Y", at: 0, in: tv)                                // in paragraph 1
        #expect(tv.string == "Ysmall\nBIGX")
        #expect(sizes(tv) == start)
        let small = tv.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
        #expect(small.pointSize == start[0])                    // the rest of paragraph 1 kept its font
        #expect(tv.font?.pointSize == start[0])
    }

    @Test func theSixPointMinimumDoesNotChangeTheSecondLineOnTheFirstKeystroke() throws {
        let v = surface(width: 384)                            // a fifth: the top line clamps to 6 pt
        v.beginTextEditing(text: "small\nBIG", style: style(), target: target, selectAll: false)
        let tv = try #require(v.textEditor)
        let start = sizes(tv)
        #expect(start[0] == 6)
        type("X", at: (tv.string as NSString).length, in: tv)
        #expect(sizes(tv) == start)
    }
}
