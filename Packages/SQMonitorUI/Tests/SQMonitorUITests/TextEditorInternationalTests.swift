import AppKit
import Testing
import SQCore
import SQText
@testable import SQMonitorUI

/// FILMCRAFT-ISSUES 15: the in-place text field takes IME composition and follows the style's writing direction.
@MainActor @Suite struct TextEditorInternationalTests {
    let target = OverlayTarget(clip: UUID(), size: CGSize(width: 200, height: 100), isText: true,
                               baseTransform: ClipTransform(), shift: .zero, positionTrack: KeyframeTrack<Vec2>())

    func surface() -> ProgramSurfaceView {
        let v = ProgramSurfaceView(viewer: NSView())
        v.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        v.sequenceSize = CGSize(width: 1920, height: 1080)
        return v
    }

    func direction(_ tv: NSTextView) -> NSWritingDirection? {
        (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.baseWritingDirection
    }

    @Test func directionFollowsTheStyle() throws {
        var s = TextStyle(fontName: "Helvetica", size: 40)
        let v = surface()
        v.beginTextEditing(text: "abc", style: s, target: target, selectAll: false)
        #expect(direction(try #require(v.textEditor)) == .natural)
        s.direction = .rightToLeft
        v.beginTextEditing(text: "abc", style: s, target: target, selectAll: false)
        #expect(direction(try #require(v.textEditor)) == .rightToLeft)
        s.direction = .leftToRight
        v.beginTextEditing(text: "abc", style: s, target: target, selectAll: false)
        #expect(direction(try #require(v.textEditor)) == .leftToRight)
    }

    @Test func imeCompositionIsReportedAndCommits() throws {
        let v = surface()
        v.beginTextEditing(text: "", style: TextStyle(fontName: "Helvetica", size: 40), target: target, selectAll: false)
        let tv = try #require(v.textEditor)
        // Pinyin composition: marked text first, then the chosen candidate replaces it.
        tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.hasMarkedText())
        #expect(tv.string == "nihao")
        tv.insertText("你好", replacementRange: tv.markedRange())
        #expect(!tv.hasMarkedText())
        #expect(tv.string == "你好")
    }

    @Test func arabicAndHebrewTextIsStoredAsTyped() throws {
        let v = surface()
        v.beginTextEditing(text: "", style: TextStyle(fontName: "Helvetica", size: 40), target: target, selectAll: false)
        let tv = try #require(v.textEditor)
        tv.insertText("مرحبا", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText(" שלום", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.string == "مرحبا שלום")
    }
}
