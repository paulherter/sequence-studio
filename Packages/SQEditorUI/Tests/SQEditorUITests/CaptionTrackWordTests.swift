import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

/// Correcting captions on the caption track: level of detail, word hits, retiming by dragging, the inline field,
/// split / join / delete, find and replace, the read-only list. Every edit must arrive as exactly one commit.
@MainActor @Suite struct CaptionTrackWordTests {
    static let fd = Time(1, 30)
    static let texts = ["alpha beta gamma delta", "Beta epsilon zeta eta", "theta iota beta kappa"]

    /// Three captions of 2 s, back to back, four timed words of half a second each.
    static func timeline(locked: Bool = false) -> Timeline {
        // A clip far out makes the sequence long enough to zoom out to block level.
        let far = Clip(name: "far", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(600, 1))
        var t = Timeline(name: "captions", frameDuration: fd, tracks: [Track(kind: .video, clips: [far], name: "V1")])
        t.captionTracks = [CaptionTrack(isLocked: locked, items: texts.enumerated().map { n, text in
            CaptionItem(lines: [text], range: TimeRange(start: Time(Int64(n * 2), 1), end: Time(Int64(n * 2 + 2), 1)),
                        words: text.split(separator: " ").enumerated().map { i, w in
                            CaptionWord(text: String(w), range: TimeRange(start: Time(Int64(i), 2), end: Time(Int64(i + 1), 2)))
                        })
        })]
        return t
    }

    static func geometry(_ pps: Double) -> TimelineGeometry { TimelineGeometry(frameDuration: fd, pointsPerSecond: pps) }

    private func items(_ t: Timeline) -> [CaptionItem] { t.captionTracks[0].items }

    /// `t` with its captions changed.
    private func changing(_ t: Timeline, _ change: (inout [CaptionItem]) -> Void) -> Timeline {
        var out = t, all = t.captionTracks[0].items
        change(&all)
        out.captionTracks = [CaptionTrack(isLocked: t.captionTracks[0].isLocked, items: all)]
        return out
    }

    /// A point on the caption row at `seconds` (plus `dx` points).
    private func point(_ seconds: Double, dx: CGFloat = 0, _ g: TimelineGeometry, _ t: Timeline) -> CGPoint {
        let row = g.captionRows(for: t)[0]
        return CGPoint(x: g.x(for: Time(Int64(seconds * 600), 600)) + dx, y: row.y + row.height / 2)
    }

    private func view(_ pps: Double = 200, timeline t: Timeline = timeline()) -> (TimelineView, () -> [TimelineCommit]) {
        let v = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1500, height: 300))
        v.setZoom(pointsPerSecond: pps)
        v.scroll(toX: 0)
        final class Box { var commits: [TimelineCommit] = [] }
        let box = Box()
        v.onCommit = { box.commits.append($0) }
        return (v, { box.commits })
    }

    // MARK: Level of detail and hits

    @Test func wordsShowOnlyWithRoom() {
        let t = Self.timeline(), item = items(t)[0]
        #expect(!CaptionWordLayout.showsWords(item, geometry: Self.geometry(40)))
        #expect(!CaptionWordLayout.showsWords(item, geometry: Self.geometry(59)))
        #expect(CaptionWordLayout.showsWords(item, geometry: Self.geometry(200)))
        // A fast speaker (many words in a short caption) stays a block until its words have room.
        var fast = item
        fast.lines = [Array(repeating: "a", count: 40).joined(separator: " ")]
        fast.words = []
        #expect(!CaptionWordLayout.showsWords(fast, geometry: Self.geometry(200)))
        #expect(CaptionWordLayout.showsWords(fast, geometry: Self.geometry(CaptionWordLayout.zoomForWords(fast))))
        #expect(CaptionWordLayout.showsWords(item, geometry: Self.geometry(CaptionWordLayout.zoomForWords(item))))
    }

    @Test func boxesSitAtWordTimesAndNeverOverlap() {
        let t = Self.timeline(), g = Self.geometry(200), row = g.captionRows(for: t)[0]
        let boxes = CaptionWordLayout.boxes(items(t)[1], geometry: g, row: row)
        #expect(boxes.count == 4)
        for (a, b) in zip(boxes, boxes.dropFirst()) { #expect(a.maxX <= b.minX) }
        #expect(abs(boxes[0].minX - g.x(for: Time(2, 1))) <= 1)
        #expect(abs(boxes[3].maxX - g.x(for: Time(4, 1))) <= 1)
        #expect(boxes.allSatisfy { $0.minY >= row.y && $0.maxY <= row.maxY })
    }

    @Test func hitFindsWordBodyAndEdges() {
        let t = Self.timeline(), g = Self.geometry(200), id = items(t)[0].id
        let body = CaptionWordLayout.hit(point(0.75, g, t), caption: id, in: t, geometry: g)
        #expect(body == CaptionWordHit(ref: CaptionWordRef(caption: id, index: 1), zone: .body))
        #expect(CaptionWordLayout.hit(point(1.0, dx: -2, g, t), caption: id, in: t, geometry: g)?.zone == .tail)
        #expect(CaptionWordLayout.hit(point(1.0, dx: 1, g, t), caption: id, in: t, geometry: g)
                == CaptionWordHit(ref: CaptionWordRef(caption: id, index: 2), zone: .head))
        #expect(CaptionWordLayout.hit(point(0.75, Self.geometry(40), t), caption: id, in: t, geometry: Self.geometry(40)) == nil)
    }

    @Test func firstIndexIsTheFirstCaptionEndingAfter() {
        let all = items(Self.timeline())
        #expect(CaptionWordLayout.firstIndex(endingAfter: Time(-1, 1), in: all) == 0)
        #expect(CaptionWordLayout.firstIndex(endingAfter: Time(2, 1), in: all) == 1)
        #expect(CaptionWordLayout.firstIndex(endingAfter: Time(5, 1), in: all) == 2)
        #expect(CaptionWordLayout.firstIndex(endingAfter: Time(6, 1), in: all) == 3)
    }

    // MARK: Selection and retime

    @Test func clickSelectsTheCaptionAndASecondClickItsWord() {
        let t = Self.timeline(), g = Self.geometry(200)
        var i = TimelineInteraction(timeline: t, geometry: g)
        // First click, also at word zoom: the caption only.
        i.mouseDown(point(2.75, g, t), modifiers: [])
        #expect(i.mouseUp(point(2.75, g, t), modifiers: []) == nil)
        #expect(i.wordSelection == nil)
        #expect(i.captionSelection == [items(t)[1].id])
        // A click on a word of the selected caption: that word.
        i.mouseDown(point(2.75, g, t), modifiers: [])
        #expect(i.mouseUp(point(2.75, g, t), modifiers: []) == nil)
        #expect(i.wordSelection == CaptionWordRef(caption: items(t)[1].id, index: 1))
        #expect(i.captionSelection == [items(t)[1].id])
        i.mouseDown(point(3.25, g, t), modifiers: [])
        _ = i.mouseUp(point(3.25, g, t), modifiers: [])
        #expect(i.wordSelection == CaptionWordRef(caption: items(t)[1].id, index: 2))
        // Another caption: back to caption depth.
        i.mouseDown(point(0.75, g, t), modifiers: [])
        _ = i.mouseUp(point(0.75, g, t), modifiers: [])
        #expect(i.wordSelection == nil && i.captionSelection == [items(t)[0].id])
        i.mouseDown(point(2.75, g, t), modifiers: [])
        _ = i.mouseUp(point(2.75, g, t), modifiers: [])
        #expect(i.wordSelection == nil && i.captionSelection == [items(t)[1].id])
        // A Shift-click only changes which captions are selected.
        i.mouseDown(point(4.75, g, t), modifiers: .shift)
        _ = i.mouseUp(point(4.75, g, t), modifiers: .shift)
        #expect(i.wordSelection == nil)
        #expect(i.captionSelection == [items(t)[1].id, items(t)[2].id])
        // Zoomed out there are no words to pick.
        var far = TimelineInteraction(timeline: t, geometry: Self.geometry(40))
        far.mouseDown(point(2.75, Self.geometry(40), t), modifiers: [])
        _ = far.mouseUp(point(2.75, Self.geometry(40), t), modifiers: [])
        #expect(far.wordSelection == nil)
        #expect(far.captionSelection == [items(t)[1].id])
    }

    @Test func draggingASharedWordEdgeRollsBothWords() throws {
        let t = Self.timeline(), g = Self.geometry(200)
        var i = TimelineInteraction(timeline: t, geometry: g)
        i.mouseDown(point(1.0, dx: -2, g, t), modifiers: [])
        i.mouseDragged(point(0.8, dx: -2, g, t), modifiers: [])
        let r1 = i.mouseUp(point(0.8, dx: -2, g, t), modifiers: [])
        let commit = try #require(r1)
        #expect(commit.undoName == "Retime Word")
        #expect(commit.edits.count == 1)
        let w = items(commit.timeline)[0].words
        #expect(w[1].range.end < Time(1, 1))
        #expect(w[1].range.end == w[2].range.start)
        #expect(w[0].range == TimeRange(start: .zero, end: Time(1, 2)))
        #expect(w[2].range.end == Time(3, 2))
        // Replaying the edit gives the same timeline (the session replays edits, it does not take the preview).
        var replay = t
        for e in commit.edits { try e.apply(to: &replay) }
        #expect(replay == commit.timeline)
    }

    @Test func optionDragMovesOnlyTheGrabbedEdge() throws {
        let t = Self.timeline(), g = Self.geometry(200)
        var i = TimelineInteraction(timeline: t, geometry: g)
        i.mouseDown(point(1.0, dx: -2, g, t), modifiers: .option)
        i.mouseDragged(point(0.8, dx: -2, g, t), modifiers: .option)
        let r2 = i.mouseUp(point(0.8, dx: -2, g, t), modifiers: .option)
        let commit = try #require(r2)
        let w = items(commit.timeline)[0].words
        #expect(w[1].range.end < Time(1, 1))
        #expect(w[2].range.start == Time(1, 1))         // a pause opens, the neighbor stays
    }

    @Test func aWordEdgeStopsAtItsNeighbor() throws {
        let t = Self.timeline(), g = Self.geometry(200)
        var i = TimelineInteraction(timeline: t, geometry: g)
        // Roll the gamma / delta edge far left, past beta: it stops one frame after gamma's start.
        i.mouseDown(point(1.5, dx: -2, g, t), modifiers: [])
        i.mouseDragged(point(0.2, g, t), modifiers: [])
        let r3 = i.mouseUp(point(0.2, g, t), modifiers: [])
        let commit = try #require(r3)
        let w = items(commit.timeline)[0].words
        #expect(w[2].range.start == Time(1, 1))
        #expect(w[2].range.end == Time(1, 1) + Self.fd)
        #expect(w[3].range.start == w[2].range.end)
        #expect(w[1].range == TimeRange(start: Time(1, 2), end: Time(1, 1)))
        #expect(items(commit.timeline)[0].range == items(t)[0].range)
    }

    // MARK: Inline field

    @Test func typingIntoAWordIsOneCommit() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        #expect(v.beginWordEditing(CaptionWordRef(caption: id, index: 1)))
        #expect(v.wordEditor != nil)
        #expect(v.wordSelection == CaptionWordRef(caption: id, index: 1))
        v.finishWordEditing(text: "BETA")
        #expect(v.wordEditor == nil)
        #expect(commits().count == 1)
        #expect(commits().first?.undoName == "Edit Word")
        #expect(items(v.timeline)[0].lines == ["alpha BETA gamma delta"])
        #expect(items(v.timeline)[0].words.map(\.range) == items(Self.timeline())[0].words.map(\.range))
    }

    @Test func escapeAndUnchangedTextCommitNothing() {
        let (v, commits) = view()
        let ref = CaptionWordRef(caption: items(v.timeline)[0].id, index: 0)
        v.beginWordEditing(ref)
        v.finishWordEditing(text: nil)
        v.beginWordEditing(ref)
        v.finishWordEditing(text: "alpha")
        #expect(commits().isEmpty)
        #expect(v.wordEditor == nil)
    }

    @Test func typingTwoWordsOrNothingChangesTheWordCount() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        v.beginWordEditing(CaptionWordRef(caption: id, index: 1))
        v.finishWordEditing(text: " be  ta ")
        #expect(items(v.timeline)[0].tokens == ["alpha", "be", "ta", "gamma", "delta"])
        #expect(items(v.timeline)[0].words.count == 5)
        v.beginWordEditing(CaptionWordRef(caption: id, index: 0))
        v.finishWordEditing(text: "")
        #expect(items(v.timeline)[0].tokens == ["be", "ta", "gamma", "delta"])
        #expect(commits().map(\.undoName) == ["Edit Word", "Delete Word"])
    }

    @Test func tabWalksThroughWordsAndCaptions() {
        let (v, commits) = view()
        let all = items(v.timeline)
        v.beginWordEditing(CaptionWordRef(caption: all[0].id, index: 2))
        v.finishWordEditing(text: "GAMMA", step: 1)
        #expect(v.wordEditor?.target == .word(CaptionWordRef(caption: all[0].id, index: 3)))
        v.finishWordEditing(text: "delta", step: 1)                 // unchanged: no commit, still moves on
        #expect(v.wordEditor?.target == .word(CaptionWordRef(caption: all[1].id, index: 0)))
        v.finishWordEditing(text: "Beta", step: -1)
        #expect(v.wordEditor?.target == .word(CaptionWordRef(caption: all[0].id, index: 3)))
        v.finishWordEditing(text: nil)
        #expect(commits().count == 1)
    }

    @Test func insertingAWordIsOneCommit() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        #expect(v.beginWordInsert(in: id, at: 4))
        v.finishWordEditing(text: "omega")
        #expect(items(v.timeline)[0].tokens == ["alpha", "beta", "gamma", "delta", "omega"])
        #expect(v.beginWordInsert(in: id, at: 0))
        v.finishWordEditing(text: "")                               // nothing typed: nothing inserted
        #expect(commits().map(\.undoName) == ["Insert Word"])
        #expect(items(v.timeline)[0].range == items(Self.timeline())[0].range)
    }

    @Test func doubleClickOnABlockZoomsToItsWords() {
        let (v, _) = view(40)
        let t = v.timeline, id = items(t)[1].id
        #expect(!CaptionWordLayout.showsWords(items(t)[1], geometry: v.geometry))
        #expect(v.beginWordEditing(at: point(2.75, v.geometry, t), caption: id))
        #expect(CaptionWordLayout.showsWords(items(t)[1], geometry: v.geometry))
        #expect(v.wordEditor != nil)
        v.finishWordEditing(text: nil)
    }

    @Test func aLockedTrackOpensNoField() {
        let (v, commits) = view(timeline: Self.timeline(locked: true))
        let id = items(v.timeline)[0].id
        #expect(!v.beginWordEditing(CaptionWordRef(caption: id, index: 0)))
        #expect(!v.deleteWord(CaptionWordRef(caption: id, index: 0)))
        #expect(v.captionWordMenuItems(at: point(0.75, v.geometry, v.timeline)).isEmpty)
        #expect(commits().isEmpty)
    }

    // MARK: Delete, split, join

    @Test func deleteRemovesTheSelectedWordOnlyAtWordLevel() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        #expect(!v.deleteSelectedWord())
        v.selectWord(CaptionWordRef(caption: id, index: 3))
        #expect(v.deleteSelectedWord())
        #expect(items(v.timeline)[0].tokens == ["alpha", "beta", "gamma"])
        #expect(v.wordSelection == CaptionWordRef(caption: id, index: 2))
        #expect(commits().map(\.undoName) == ["Delete Word"])
        v.setZoom(pointsPerSecond: 40)                              // the word is no longer shown: Delete is the caption's
        #expect(!v.deleteSelectedWord())
        #expect(commits().count == 1)
    }

    @Test func splitAndJoinKeepWordTimings() {
        let (v, commits) = view()
        let before = items(v.timeline)[0]
        #expect(v.splitCaption(before.id, beforeWord: 2))
        var all = items(v.timeline)
        #expect(all.count == 4)
        #expect(all[0].tokens == ["alpha", "beta"] && all[1].tokens == ["gamma", "delta"])
        #expect(all[0].effectiveWords.map(\.range) + all[1].effectiveWords.map(\.range) == before.effectiveWords.map(\.range))
        #expect(v.captionSelection == [all[1].id])
        #expect(v.joinCaption(all[1].id, with: .previous))
        all = items(v.timeline)
        #expect(all.count == 3)
        #expect(all[0].tokens == before.tokens)
        #expect(all[0].effectiveWords.map(\.range) == before.effectiveWords.map(\.range))
        #expect(!v.joinCaption(all[0].id, with: .previous))         // nothing before the first caption
        #expect(commits().map(\.undoName) == ["Split Caption", "Join Captions"])
    }

    @Test func menuOffersWordItemsOnlyAtWordLevel() {
        let (v, _) = view()
        let titles = v.captionWordMenuItems(at: point(0.75, v.geometry, v.timeline)).map(\.title).filter { !$0.isEmpty }
        #expect(titles == ["Edit Word", "Insert Word Before", "Insert Word After", "Delete Word", "Split Caption Before This Word",
                           "Join with Previous Caption", "Join with Next Caption", "Find and Replace in Captions\u{2026}"])
        let first = v.captionWordMenuItems(at: point(0.75, v.geometry, v.timeline))
        #expect(first.first { $0.title == "Join with Previous Caption" }?.isEnabled == false)
        #expect(first.first { $0.title == "Join with Next Caption" }?.isEnabled == true)
        v.setZoom(pointsPerSecond: 40)
        v.scroll(toX: 0)
        let far = v.captionWordMenuItems(at: point(0.75, v.geometry, v.timeline)).map(\.title).filter { !$0.isEmpty }
        #expect(far == ["Join with Previous Caption", "Join with Next Caption", "Find and Replace in Captions\u{2026}"])
    }

    // MARK: Find and replace

    @Test func searchCountsStepsAndWraps() {
        let t = Self.timeline()
        var m = CaptionSearchModel()
        #expect(m.countLabel == "")
        m.find = "beta"
        m.refresh(in: t, from: Time(3, 1))
        #expect(m.matches.count == 3)
        #expect(m.countLabel == "3 of 3")                           // first match at or after the playhead
        m.step(forward: true)
        #expect(m.countLabel == "1 of 3")
        m.step(forward: false)
        #expect(m.countLabel == "3 of 3")
        m.caseSensitive = true
        m.refresh(in: t)
        #expect(m.matches.count == 2)
        m.find = "nothing"
        m.refresh(in: t)
        #expect(m.countLabel == "No matches" && !m.canReplace)
    }

    @Test func replaceOneAndAll() throws {
        let t = Self.timeline()
        var m = CaptionSearchModel()
        m.find = "beta"; m.replacement = "betabeta"
        m.refresh(in: t)
        let r4 = m.replacingCurrent(in: t)
        let one = try #require(r4)
        #expect(items(one)[0].lines == ["alpha betabeta gamma delta"])
        #expect(m.currentMatch?.caption == items(t)[1].id)          // steps over what it just wrote
        m.replacement = "B"
        m.find = "beta"
        m.refresh(in: t)
        let r5 = m.replacingAll(in: t)
        let all = try #require(r5)
        #expect(all.count == 3)
        #expect(items(all.timeline).map(\.lines) == [["alpha B gamma delta"], ["B epsilon zeta eta"], ["theta iota B kappa"]])
        #expect(m.matches.isEmpty)
        #expect(items(all.timeline)[0].words.count == 4)
    }

    @Test func popupReplaceAllIsOneCommit() {
        let (v, commits) = view()
        let popup = v.makeCaptionSearch()
        var seeks: [Time] = []
        v.onSeek = { seeks.append($0) }
        let scrollBefore = v.geometry.scrollX
        // Typing: count and highlight only, the playhead and the scroll position stay.
        popup.setFind("be")
        popup.setFind("beta")
        #expect(popup.countText == "1 of 3")
        #expect(v.wordSelection == CaptionWordRef(caption: items(v.timeline)[0].id, index: 1))
        popup.setCaseSensitive(true)
        popup.setCaseSensitive(false)
        #expect(seeks.isEmpty && v.geometry.scrollX == scrollBefore)
        // Return / Next goes to the marked match first, then steps on.
        popup.performNext()
        #expect(popup.countText == "1 of 3" && seeks.count == 1)
        popup.performNext()
        #expect(popup.countText == "2 of 3" && seeks.count == 2)
        #expect(v.captionSelection == [items(v.timeline)[1].id])
        popup.setCaseSensitive(true)
        #expect(popup.model.matches.count == 2)
        popup.setCaseSensitive(false)
        popup.setReplacement("B")
        popup.performReplace()
        #expect(commits().map(\.undoName) == ["Replace in Caption"])
        popup.performReplaceAll()
        #expect(commits().map(\.undoName) == ["Replace in Caption", "Replace All in Captions"])
        #expect(popup.countText == "2 replaced")
        popup.resync()                                              // what the commit triggers while the popup is open
        #expect(popup.countText == "2 replaced")
        #expect(items(v.timeline).map(\.lines) == [["alpha B gamma delta"], ["B epsilon zeta eta"], ["theta iota B kappa"]])
        popup.setFind("B")                                          // the next thing typed brings the count back
        #expect(popup.countText == "1 of 3")
    }

    // MARK: Review fixes

    @Test func deleteAfterOneClickIsNotAWordDelete() {
        let (v, commits) = view()
        let p = point(0.75, v.geometry, v.timeline)
        var i = TimelineInteraction(timeline: v.timeline, geometry: v.geometry)
        i.mouseDown(p, modifiers: [])
        _ = i.mouseUp(p, modifiers: [])
        #expect(i.captionSelection == [items(v.timeline)[0].id] && i.wordSelection == nil)
        // The view with only a caption selected: Delete is not taken by the word path (the host deletes the caption).
        v.selectWord(CaptionWordRef(caption: items(v.timeline)[0].id, index: 1))
        v.selectWord(nil)
        #expect(v.captionSelection == [items(v.timeline)[0].id])
        #expect(!v.deleteSelectedWord())
        #expect(commits().isEmpty)
    }

    @Test func wordsTheZoomCannotReachLeaveTheZoomAlone() throws {
        let dense = CaptionItem(lines: [Array(repeating: "a", count: 200).joined(separator: " ")],
                                range: TimeRange(start: Time(10, 1), end: Time(10, 1) + Self.fd))
        let t = changing(Self.timeline()) { $0.append(dense) }
        let (v, commits) = view(40, timeline: t)
        try #require(v.zoomLimits.upperBound < CaptionWordLayout.zoomForWords(dense))
        #expect(!v.canShowWords(dense))
        let zoom = v.geometry.pointsPerSecond, scroll = v.geometry.scrollX
        #expect(!v.beginWordEditing(at: point(10.01, v.geometry, t), caption: dense.id))
        #expect(!v.beginWordEditing(CaptionWordRef(caption: dense.id, index: 3)))
        #expect(!v.beginWordInsert(in: dense.id, at: 0))
        #expect(v.geometry.pointsPerSecond == zoom && v.geometry.scrollX == scroll)
        #expect(v.wordEditor == nil && commits().isEmpty)
        // No words, or a locked track: the same, zoom untouched.
        let empty = changing(Self.timeline()) { $0[0].lines = [""]; $0[0].words = [] }
        let (e, _) = view(40, timeline: empty)
        #expect(!e.beginWordEditing(at: point(0.75, e.geometry, empty), caption: items(empty)[0].id))
        #expect(e.geometry.pointsPerSecond == zoom)
        let (l, _) = view(40, timeline: Self.timeline(locked: true))
        #expect(!l.beginWordEditing(at: point(0.75, l.geometry, l.timeline), caption: items(l.timeline)[0].id))
        #expect(l.geometry.pointsPerSecond == zoom)
        // A caption whose words the zoom can reach still zooms in.
        #expect(v.canShowWords(items(t)[0]))
    }

    @Test func tabAfterDeletingACaptionsLastWordGoesOn() {
        func solo(_ n: Int) -> Timeline {
            changing(Self.timeline()) {
                $0[n].lines = ["solo"]
                $0[n].words = [CaptionWord(text: "solo", range: TimeRange(start: .zero, end: Time(2, 1)))]
            }
        }
        let (v, commits) = view(timeline: solo(0))
        var all = items(v.timeline)
        v.beginWordEditing(CaptionWordRef(caption: all[0].id, index: 0))
        v.finishWordEditing(text: "", step: 1)
        #expect(items(v.timeline).map(\.id) == [all[1].id, all[2].id])
        #expect(v.wordEditor?.target == .word(CaptionWordRef(caption: all[1].id, index: 0)))
        v.finishWordEditing(text: nil)
        #expect(commits().map(\.undoName) == ["Delete Word"])

        let (b, _) = view(timeline: solo(1))
        all = items(b.timeline)
        b.beginWordEditing(CaptionWordRef(caption: all[1].id, index: 0))
        b.finishWordEditing(text: "", step: -1)
        #expect(b.wordEditor?.target == .word(CaptionWordRef(caption: all[0].id, index: 3)))
        b.finishWordEditing(text: nil)

        let (f, _) = view(timeline: solo(1))
        all = items(f.timeline)
        f.beginWordEditing(CaptionWordRef(caption: all[1].id, index: 0))
        f.finishWordEditing(text: "", step: 1)
        #expect(f.wordEditor?.target == .word(CaptionWordRef(caption: all[2].id, index: 0)))
        f.finishWordEditing(text: nil)
    }

    @Test func aFieldWhoseCaptionChangedWritesNothing() throws {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        // The caption changes under the open field (undo, another panel): the field goes, nothing is written.
        v.beginWordEditing(CaptionWordRef(caption: id, index: 1))
        var other = v.timeline
        try other.deleteCaptionWord(id, index: 0)
        v.setTimeline(other)
        #expect(v.wordEditor == nil)
        v.finishWordEditing(text: "WRONG")
        #expect(commits().isEmpty && items(v.timeline)[0].tokens == ["beta", "gamma", "delta"])
        // Same for a field that inserts.
        #expect(v.beginWordInsert(in: id, at: 3))
        var third = v.timeline
        try third.setCaptionWord(id, index: 2, text: "DELTA")
        v.setTimeline(third)
        #expect(v.wordEditor == nil && commits().isEmpty)
        // A change elsewhere leaves the field open.
        v.beginWordEditing(CaptionWordRef(caption: id, index: 1))
        var elsewhere = v.timeline
        try elsewhere.setCaptionWord(items(v.timeline)[2].id, index: 0, text: "THETA")
        v.setTimeline(elsewhere)
        #expect(v.wordEditor != nil)
        v.finishWordEditing(text: "GAMMA")
        #expect(commits().map(\.undoName) == ["Edit Word"])
        #expect(items(v.timeline)[0].tokens == ["beta", "GAMMA", "DELTA"])
    }

    @Test func listShapesEachRowOnce() {
        let list = CaptionReadListView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        list.setModel(CaptionListModel(timeline: Self.timeline(), timecode: Timecode(frameDuration: Self.fd, dropFrame: false)))
        list.drawForTest()
        let shaped = list.shapedCount
        #expect(shaped == 6)                                        // three rows: a time and a text each
        list.setPlayhead(Time(5, 2))
        list.drawForTest()
        list.drawForTest()
        #expect(list.shapedCount == shaped)
    }

    // MARK: Read-only list

    @Test func listModelRowsAndCurrentRow() {
        let m = CaptionListModel(timeline: Self.timeline(), timecode: Timecode(frameDuration: Self.fd, dropFrame: false))
        #expect(m.rows.map(\.text) == Self.texts)
        #expect(m.rows[1].time == Timecode(frameDuration: Self.fd, dropFrame: false).format(Time(2, 1)))
        #expect(m.currentRow(at: Time(1, 2)) == 0)
        #expect(m.currentRow(at: Time(2, 1)) == 1)
        #expect(m.currentRow(at: Time(59, 10)) == 2)
        #expect(m.currentRow(at: Time(7, 1)) == nil)
        #expect(m.seekTime(row: 2) == Time(4, 1))
        #expect(m.seekTime(row: 3) == nil)
        #expect(CaptionListModel(timeline: nil, timecode: Timecode(frameDuration: Self.fd, dropFrame: false)).rows.isEmpty)
    }

    @Test func listViewMarksThePlayheadRowAndSeeksOnClick() {
        let list = CaptionReadListView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        list.setModel(CaptionListModel(timeline: Self.timeline(), timecode: Timecode(frameDuration: Self.fd, dropFrame: false)))
        #expect(list.contentHeight == 3 * Theme.Row.list)
        var seeks: [Time] = []
        list.onSeek = { seeks.append($0) }
        list.setPlayhead(Time(5, 2))
        #expect(list.currentRow == 1)
        list.setPlayhead(Time(9, 1))
        #expect(list.currentRow == nil)
        list.click(row: 2)
        list.click(row: 9)
        #expect(seeks == [Time(4, 1)])
    }

    // MARK: Return edits the selected word, All Captions marks the selection

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func returnOpensTheSelectedWordAndCommitsOneStep() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        v.selectWord(CaptionWordRef(caption: id, index: 2))
        v.keyDown(with: key(36))
        #expect(v.wordEditor?.target == .word(CaptionWordRef(caption: id, index: 2)))
        v.finishWordEditing(text: "GAMMA")
        #expect(commits().map(\.undoName) == ["Edit Word"])
        #expect(items(v.timeline)[0].lines == ["alpha beta GAMMA delta"])
    }

    @Test func escapeCancelsTheReturnEditor() {
        let (v, commits) = view()
        let id = items(v.timeline)[0].id
        v.selectWord(CaptionWordRef(caption: id, index: 0))
        v.keyDown(with: key(76))
        #expect(v.wordEditor != nil)
        v.finishWordEditing(text: nil)
        #expect(v.wordEditor == nil && commits().isEmpty)
        #expect(items(v.timeline)[0].lines == [Self.texts[0]])
    }

    @Test func returnWithoutWordSelectionOrOnLockedTrackDoesNothing() {
        let (v, _) = view()
        v.keyDown(with: key(36))
        #expect(v.wordEditor == nil)
        let (l, _) = view(timeline: Self.timeline(locked: true))
        l.selectWord(CaptionWordRef(caption: items(l.timeline)[0].id, index: 1))
        l.keyDown(with: key(36))
        #expect(l.wordEditor == nil)
    }

    @Test func listMarksSelectedAndPlayheadRowsApart() {
        let list = CaptionReadListView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let t = Self.timeline()
        list.setModel(CaptionListModel(timeline: t, timecode: Timecode(frameDuration: Self.fd, dropFrame: false)))
        list.setPlayhead(Time(1, 2))
        list.setSelected(Set([items(t)[2].id]))
        #expect(list.currentRow == 0)
        #expect(list.selectedRows == [2])
        #expect(list.mark(row: 0) == .playhead)
        #expect(list.mark(row: 2) == .selected)
        list.setSelected(Set([items(t)[0].id]))
        #expect(list.mark(row: 0) == .selected)                    // selection wins over the playhead mark
        #expect(list.mark(row: 1) == .none)
        list.setSelected([])
        #expect(list.mark(row: 0) == .playhead)
    }
}
