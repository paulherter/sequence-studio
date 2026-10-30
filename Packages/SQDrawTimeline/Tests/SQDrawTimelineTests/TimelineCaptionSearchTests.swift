import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// One caption track: "the cat" at 0, "the dog" at 60 frames (word timings on both).
@MainActor private func setup(captions: Bool = true) -> (TimelinePanel, EditorSession) {
    func item(_ a: String, _ b: String, at f: Int64) -> CaptionItem {
        CaptionItem(lines: ["\(a) \(b)"], range: TimeRange(start: fd * f, duration: fd * 25),
                    words: [CaptionWord(text: a, range: TimeRange(start: fd * f, duration: fd * 12)),
                            CaptionWord(text: b, range: TimeRange(start: fd * (f + 13), duration: fd * 12))])
    }
    var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
    if captions { t.captionTracks = [CaptionTrack(name: "Subtitles", items: [item("the", "cat", at: 0), item("the", "dog", at: 60)])] }
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 100, w: 1000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
    return (p, s)
}

@MainActor private func send(_ p: inout TimelinePanel, _ s: EditorSession, _ e: InputEvent) -> [TimelineAction]? {
    guard let a = p.handleCaptionSearch(e) else { return nil }
    for x in a { TimelineSessionBridge.apply(x, to: s, host: nil) }
    p.sync(timeline: s.activeTimeline!, selection: s.selection, captions: s.captionSelection, playhead: s.playhead,
           selectedTransition: nil, labels: LabelResolver())
    return a
}

@MainActor private func type(_ p: inout TimelinePanel, _ s: EditorSession, _ text: String) {
    for ch in text { _ = send(&p, s, .keyDown(.character(ch), modifiers: [])) }
}

@MainActor private func click(_ p: inout TimelinePanel, _ s: EditorSession, _ r: CGRect) {
    _ = send(&p, s, .mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
    _ = send(&p, s, .mouseUp(x: Float(r.midX), y: Float(r.midY)))
}

@MainActor @Suite struct TimelineCaptionSearchTests {
    /// `showCaptionSearch`: under the first caption row at the content edge + 12 (window points); no captions, no card.
    @Test func opensUnderTheFirstCaptionRow() {
        var (p, _) = setup()
        let shown = p.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        #expect(shown)
        let row = p.geometry.captionRows(for: p.timeline)[0]
        let f = p.captionSearch!.frame
        #expect(f.minX == TimelineGeometry.contentOriginX + 12)
        #expect(f.minY == 100 + max(row.y, TimelineGeometry.rulerHeight) + row.height + 4)
        #expect(f.width == 356 && f.height == 12 + 22 + 8 + 22 + 8 + 22 + 12)
        #expect(p.captionSearch!.isEditing)
        var (q, _) = setup(captions: false)
        let none = q.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        #expect(!none)
        #expect(!q.isCaptionSearchShown)
    }

    /// Typing marks the first match, Return goes to it (seek), the next Return steps on; Esc closes.
    @Test func typingHighlightsReturnStepsEscCloses() {
        var (p, s) = setup()
        _ = p.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        type(&p, s, "the")
        #expect(p.captionSearch?.countText == "1 of 2")
        let first = s.activeTimeline!.captionTracks[0].items[0].id
        #expect(s.captionSelection == [first])
        #expect(s.playhead == .zero)
        _ = send(&p, s, .keyDown(.enter, modifiers: []))
        #expect(s.playhead == .zero && p.captionSearch?.countText == "1 of 2")
        _ = send(&p, s, .keyDown(.enter, modifiers: []))
        #expect(p.captionSearch?.countText == "2 of 2")
        #expect(s.playhead == fd * 60)
        _ = send(&p, s, .keyDown(.escape, modifiers: []))
        #expect(!p.isCaptionSearchShown)
    }

    /// Replace All: one undo step, "2 replaced" in place of the count; presses outside leave the card open.
    @Test func replaceAllIsOneUndoStepAndShowsTheCount() {
        var (p, s) = setup()
        _ = p.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        type(&p, s, "the")
        _ = send(&p, s, .keyDown(InputKey.tab, modifiers: []))
        type(&p, s, "a")
        let c = p.captionSearch!
        click(&p, s, c.rect(.replaceAll))
        #expect(s.activeTimeline!.captionTracks[0].items.map(\.lines) == [["a cat"], ["a dog"]])
        #expect(p.captionSearch?.countText == "2 replaced")
        #expect(s.undoName == "Replace All in Captions")
        s.undo()
        #expect(s.activeTimeline!.captionTracks[0].items.map(\.lines) == [["the cat"], ["the dog"]])
        let outside = send(&p, s, .mouseDown(x: 990, y: 490, modifiers: []))
        #expect(outside == nil)
        #expect(p.isCaptionSearchShown)
        click(&p, s, p.captionSearch!.rect(.close))
        #expect(!p.isCaptionSearchShown)
    }

    @Test func drawsTheCard() {
        var (p, _) = setup()
        _ = p.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        var c = Canvas(width: 1440, height: 900, atlas: nil, scale: 1)
        p.drawCaptionSearch(&c)
        #expect(c.list.quads.count > 10)
    }
}

extension TimelineCaptionSearchTests {
    /// The Find field keeps Cmd-Z / V: the card takes the key (the timeline's undo must not run).
    @Test func findFieldKeepsUndoAndPaste() {
        var (p, s) = setup()
        _ = p.showCaptionSearch(window: CGSize(width: 1440, height: 900))
        type(&p, s, "the")
        #expect(p.captionSearch?.findText == "the")
        #expect(send(&p, s, .keyDown(.character("z"), modifiers: .command)) != nil)
        #expect(p.captionSearch?.findText == "")
        TextClipboard.shared.write("dog")
        #expect(send(&p, s, .keyDown(.character("v"), modifiers: .command)) != nil)
        #expect(p.captionSearch?.findText == "dog")
    }
}
