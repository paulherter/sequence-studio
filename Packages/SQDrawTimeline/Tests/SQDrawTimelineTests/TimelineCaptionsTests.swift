import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// V1 with one clip and one caption track with two captions (the second with word timings).
@MainActor private func setup() -> (TimelinePanel, EditorSession) {
    let words = [CaptionWord(text: "Hello", range: TimeRange(start: .zero, duration: fd * 12)),
                 CaptionWord(text: "there", range: TimeRange(start: fd * 13, duration: fd * 12))]
    let items = [CaptionItem(lines: ["First line"], range: TimeRange(start: .zero, duration: fd * 50)),
                 CaptionItem(lines: ["Hello there"], range: TimeRange(start: fd * 60, duration: fd * 25), words: words)]
    var t = Timeline(name: "t", frameDuration: fd,
                     tracks: [Track(kind: .video, clips: [Clip(name: "c", media: UUID(), kind: .video,
                                                              source: TimeRange(start: .zero, duration: fd * 100), start: .zero)])])
    t.captionTracks = [CaptionTrack(name: "Subtitles", items: items)]
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
    return (p, s)
}

@MainActor private func apply(_ p: inout TimelinePanel, _ s: EditorSession, _ a: [TimelineAction]) -> [TimelineAction] {
    for x in a { TimelineSessionBridge.apply(x, to: s, host: nil) }
    p.sync(timeline: s.activeTimeline!, selection: s.selection, captions: s.captionSelection, playhead: s.playhead,
           selectedTransition: nil, labels: LabelResolver())
    return a
}

@MainActor private func run(_ p: inout TimelinePanel, _ s: EditorSession, _ e: InputEvent) -> [TimelineAction] {
    apply(&p, s, p.handle(e))
}

@MainActor private func keyRun(_ p: inout TimelinePanel, _ s: EditorSession, _ k: InputKey) -> [TimelineAction] {
    apply(&p, s, p.key(k, modifiers: []) ?? [])
}

@MainActor @Suite struct TimelineCaptionsTests {
    @Test func captionLaneAndHeaderDraw() {
        let (p, _) = setup()
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        let row = p.geometry.captionRows(for: p.timeline)[0]
        #expect(row.label == "C1")
        // The caption block fill sits inside the caption row of the content area.
        #expect(!list.quads.isEmpty)
        #expect(p.captionEyeRect(in: row).maxX <= TimelineGeometry.contentOriginX)
    }

    @Test func eyePressTogglesTheTrackAsOneUndoStep() {
        var (p, s) = setup()
        let row = p.geometry.captionRows(for: p.timeline)[0]
        let e = p.captionEyeRect(in: row)
        let a = p.handle(.mouseDown(x: Float(e.midX), y: Float(e.midY), modifiers: []))
        #expect(a == [.toggleCaptionTrackVisibility(row.track)])
        TimelineSessionBridge.apply(a[0], to: s)
        #expect(s.activeTimeline!.captionTracks[0].isVisible == false)
        s.undo()
        #expect(s.activeTimeline!.captionTracks[0].isVisible == true)
    }

    @Test func doubleClickOpensTheWordFieldAndReturnTypesIt() {
        var (p, s) = setup()
        let row = p.geometry.captionRows(for: p.timeline)[0]
        let id = s.activeTimeline!.captionTracks[0].items[0].id
        // "First line" has no timings: its words are spread over the caption, "line" is the second half.
        let x = Float(p.geometry.x(for: fd * 38)), y = Float(row.y + row.height / 2)
        _ = run(&p, s, .mouseDown(x: x, y: y, modifiers: []))
        _ = run(&p, s, .mouseUp(x: x, y: y))
        _ = run(&p, s, .mouseDown(x: x, y: y, modifiers: []))
        #expect(p.isEditingWord)
        #expect(p.interaction.wordSelection == CaptionWordRef(caption: id, index: 1))
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)                                    // the field draws over its word
        let depth = s.undoDepth
        for ch in "verse" { _ = keyRun(&p, s, .character(ch)) }
        let done = keyRun(&p, s, .enter)
        #expect(done.contains { if case .commit = $0 { true } else { false } })
        #expect(!p.isEditingWord)
        #expect(s.activeTimeline!.captionTracks[0].items[0].tokens == ["First", "verse"])
        #expect(s.undoDepth == depth + 1)
        s.undo()
        #expect(s.activeTimeline!.captionTracks[0].items[0].tokens == ["First", "line"])
    }

    @Test func escDropsTheFieldTabMovesOnAndAPressElsewhereTakesIt() {
        var (p, s) = setup()
        let first = s.activeTimeline!.captionTracks[0].items[0].id, second = s.activeTimeline!.captionTracks[0].items[1].id
        _ = apply(&p, s, p.beginWordEditing(CaptionWordRef(caption: first, index: 0)) ?? [])
        #expect(p.isEditingWord)
        for ch in "Zero" { _ = keyRun(&p, s, .character(ch)) }
        _ = keyRun(&p, s, .escape)
        #expect(!p.isEditingWord && !s.canUndo)                            // nothing written
        // Tab takes the text and opens the next word, past the caption's end on the next caption.
        _ = apply(&p, s, p.beginWordEditing(CaptionWordRef(caption: first, index: 1)) ?? [])
        for ch in "one" { _ = keyRun(&p, s, .character(ch)) }
        _ = keyRun(&p, s, InputKey.tab)
        #expect(s.activeTimeline!.captionTracks[0].items[0].tokens == ["First", "one"])
        #expect(p.isEditingWord)
        #expect(p.interaction.wordSelection == CaptionWordRef(caption: second, index: 0))
        // A press away from the field takes what was typed.
        for ch in "Hi" { _ = keyRun(&p, s, .character(ch)) }
        _ = run(&p, s, .mouseDown(x: 990, y: 390, modifiers: []))
        #expect(!p.isEditingWord)
        #expect(s.activeTimeline!.captionTracks[0].items[1].tokens == ["Hi", "there"])
    }

    @Test func returnAndDeleteActOnTheSelectedWord() {
        var (p, s) = setup()
        let second = s.activeTimeline!.captionTracks[0].items[1].id
        let ref = CaptionWordRef(caption: second, index: 1)
        _ = apply(&p, s, p.beginWordEditing(ref) ?? [])
        _ = keyRun(&p, s, .escape)                                         // word level, the word selected, no field
        #expect(!p.isEditingWord && p.interaction.wordSelection == ref)
        _ = keyRun(&p, s, .enter)
        #expect(p.isEditingWord)
        _ = keyRun(&p, s, .escape)
        _ = keyRun(&p, s, .delete)
        #expect(s.activeTimeline!.captionTracks[0].items[1].tokens == ["Hello"])
        s.undo()
        #expect(s.activeTimeline!.captionTracks[0].items[1].tokens == ["Hello", "there"])
    }

    @Test func wordMenuItemsSitAboveTheCaptionMenu() {
        var (p, s) = setup()
        let second = s.activeTimeline!.captionTracks[0].items[1].id
        _ = apply(&p, s, p.beginWordEditing(CaptionWordRef(caption: second, index: 0)) ?? [])
        _ = keyRun(&p, s, .escape)
        let host = TimelineHost()
        var asked: [TimelineEditorRequest] = []
        host.open = { asked.append($0); return true }
        var panel = p
        host.panel = { $0(&panel) }
        let box = CaptionWordLayout.box(CaptionWordRef(caption: second, index: 1), in: p.timeline, geometry: p.geometry)!
        let pt = CGPoint(x: box.midX, y: box.midY)
        let items = TimelineMenus.items(at: pt, panel: &p, session: s, host: host) ?? []
        let titles = items.map(\.title)
        #expect(Array(titles.prefix(4)) == ["Edit Word", "Insert Word Before", "Insert Word After", "Delete Word"])
        #expect(titles.contains("Join with Previous Caption") && titles.contains("Find and Replace in Captions\u{2026}"))
        items.first { $0.title == "Split Caption Before This Word" }?.action?()
        #expect(s.activeTimeline!.captionTracks[0].items.map(\.tokens) == [["First", "line"], ["Hello"], ["there"]])
        items.first { $0.title == "Find and Replace in Captions\u{2026}" }?.action?()
        #expect(asked == [.captionFindReplace])
    }

    @Test func fastCutSkimmerFollowsThePointerAndEndsOnAPress() {
        var (p, s) = setup()
        var t = s.activeTimeline!
        t.editMode = .magnetic
        p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let row = p.rows[0]
        let x = p.geometry.x(for: fd * 40), y = row.y + row.height / 2
        let a = p.handle(.mouseMoved(x: Float(x), y: Float(y)))
        #expect(a == [.skim(fd * 40)])
        #expect(p.handle(.mouseMoved(x: Float(x), y: Float(y))).isEmpty)      // same frame: nothing to tell
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        p.isPlaying = true
        #expect(p.handle(.mouseMoved(x: Float(x + 30), y: Float(y))) == [.skim(nil)])   // playback hides it
        p.isPlaying = false
        _ = p.handle(.mouseMoved(x: Float(x), y: Float(y)))
        #expect(p.handle(.mouseDown(x: Float(x), y: Float(y), modifiers: [])).first == .skim(nil))
        // Off Fast Cut there is no skimmer.
        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        #expect(p.handle(.mouseMoved(x: Float(x), y: Float(y))).isEmpty)
    }
}
