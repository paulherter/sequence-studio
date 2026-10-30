import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession(clips: [(Int64, Int64)] = []) -> EditorSession {
    let cs = clips.map { a, b in
        Clip(name: "c\(a)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(b - a)), start: s(a))
    }
    let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                     tracks: [Track(kind: .video, clips: cs), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}
private func item(_ text: String, _ a: Int64, _ b: Int64, words: [CaptionWord] = []) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "default", words: words)
}
private func timeline(_ items: [CaptionItem]) -> Timeline {
    var t = Timeline(name: "T", frameDuration: Time(1, 30))
    var ct = CaptionTrack()
    try? ct.replaceAll(items)
    t.captionTracks = [ct]
    return t
}

@MainActor @Suite struct KeywordAtPlayheadTests {
    @Test func findsTheWordUnderThePlayhead() {
        // No stored timings: spread by length, "three" covers 3.2 s to 6.4 s.
        let t = timeline([item("one two three four", 0, 8)])
        #expect(KeywordAtPlayhead.word(at: s(4), in: t)?.text == "three")
        #expect(KeywordAtPlayhead.word(at: s(0), in: t)?.text == "one")
        #expect(KeywordAtPlayhead.word(at: s(8), in: t) == nil)   // half-open
        #expect(KeywordAtPlayhead.word(at: s(9), in: t) == nil)
    }

    @Test func aPauseKeepsTheWordSpokenLast() {
        let words = [CaptionWord(text: "hello", range: TimeRange(start: .zero, end: s(1))),
                     CaptionWord(text: "world", range: TimeRange(start: s(3), end: s(4)))]
        let t = timeline([item("hello world", 10, 15, words: words)])
        #expect(KeywordAtPlayhead.word(at: Time(23, 2), in: t)?.text == "hello")   // 11.5 s, in the pause
        #expect(KeywordAtPlayhead.word(at: s(13), in: t)?.text == "world")
    }

    @Test func hiddenCaptionTracksAreIgnored() {
        var t = timeline([item("one", 0, 4)])
        t.captionTracks[0].isVisible = false
        #expect(KeywordAtPlayhead.word(at: s(1), in: t) == nil)
    }

    @Test func cleansPunctuationAtTheEdgesOnly() {
        #expect(KeywordAtPlayhead.cleaned("\u{201C}Wow!\u{201D},") == "Wow")
        #expect(KeywordAtPlayhead.cleaned("don't") == "don't")
        #expect(KeywordAtPlayhead.cleaned("3.5") == "3.5")
        #expect(KeywordAtPlayhead.cleaned("...") == "")
    }

    @Test func rangeRunsToTheNextCutPlusThreeTenths() {
        let fd = Time(1, 30)
        let w = CaptionWord(text: "x", range: TimeRange(start: s(2), end: Time(5, 2)))
        let r = KeywordAtPlayhead.range(for: w, editPoints: [s(0), s(4), s(9)], frameDuration: fd)
        #expect(r == TimeRange(start: s(2), end: Time(43, 10).snapped(to: fd)))
    }

    @Test func rangeWithoutACutIsOneSecondAndNeverShorterThanTheWord() {
        let fd = Time(1, 30)
        let w = CaptionWord(text: "x", range: TimeRange(start: s(2), end: Time(5, 2)))
        #expect(KeywordAtPlayhead.range(for: w, editPoints: [], frameDuration: fd) == TimeRange(start: s(2), end: s(3)))
        let long = CaptionWord(text: "x", range: TimeRange(start: s(2), end: s(5)))
        #expect(KeywordAtPlayhead.range(for: long, editPoints: [], frameDuration: fd) == TimeRange(start: s(2), end: s(5)))
    }

    @Test func rangeIsCappedAtThreeSeconds() {
        let w = CaptionWord(text: "x", range: TimeRange(start: s(2), end: Time(5, 2)))
        let r = KeywordAtPlayhead.range(for: w, editPoints: [s(60)], frameDuration: Time(1, 30))
        #expect(r.end == s(5))
    }

    @Test func templateIsBigHeavyAndPopsIn() {
        let t = timeline([item("one", 0, 4)])
        let tpl = KeywordAtPlayhead.template(text: "Wow", format: t.format, item: t.captionTracks[0].items[0], track: t.captionTracks[0])
        #expect(tpl.text == "Wow" && tpl.name == "Keyword")
        #expect(tpl.style.weight >= .heavy)
        #expect(tpl.style.size >= Double(t.format.height) * 0.08)
        #expect(tpl.style.shadow != nil)
        #expect(tpl.animation == .captionPop)
    }

    // MARK: Session

    @Test func commandMakesATextClipAtTheWordAndIsOneUndoStep() throws {
        let session = makeSession(clips: [(0, 10)])
        #expect(session.replaceCaptions([item("one two three four", 0, 8)]))
        session.seek(to: s(4))
        let depth = session.undoDepth
        #expect(session.addKeywordAtPlayhead())
        #expect(session.undoDepth == depth + 1)
        let clip = try #require(session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.generator != nil })
        let (tpl, _) = try TextGenerator.decode(try #require(clip.generator))
        #expect(tpl.text == "three")
        #expect(clip.start == Time(16, 5).snapped(to: Time(1, 30)))   // word start 3.2 s
        #expect(session.selection == [clip.id])
        session.undo()
        #expect(session.activeTimeline?.tracks.lazy.flatMap(\.clips).contains { $0.generator != nil } == false)
    }

    @Test func noCaptionUnderThePlayheadSaysWhat() {
        let session = makeSession()
        session.seek(to: s(1))
        let depth = session.undoDepth
        #expect(!session.addKeywordAtPlayhead())
        #expect(session.undoDepth == depth)
        #expect(session.lastError == "No transcript word under the playhead. Create captions first.")
    }

    @Test func keepsSymbolsAndStripsOnlyPunctuation() {
        for w in ["100%", "$5", "C++", "+1", "&"] { #expect(KeywordAtPlayhead.cleaned(w) == w) }
        #expect(KeywordAtPlayhead.cleaned("\"100%\"!") == "100%")
        #expect(KeywordAtPlayhead.cleaned("Wow!!!") == "Wow")
    }

    @Test func boundaryBetweenWordsBelongsToTheLaterWord() {
        let words = [CaptionWord(text: "a", range: TimeRange(start: .zero, end: s(2))),
                     CaptionWord(text: "b", range: TimeRange(start: s(2), end: s(4)))]
        let t = timeline([item("a b", 0, 4, words: words)])
        #expect(KeywordAtPlayhead.word(at: s(2), in: t)?.text == "b")
        #expect(KeywordAtPlayhead.word(at: Time(59, 30), in: t)?.text == "a")
    }

    @Test func leadInBeforeTheFirstWordHasNoWord() {
        let words = [CaptionWord(text: "a", range: TimeRange(start: s(1), end: s(2)))]
        let t = timeline([item("a", 0, 4, words: words)])
        #expect(KeywordAtPlayhead.word(at: Time(1, 2), in: t) == nil)
        #expect(KeywordAtPlayhead.word(at: s(1), in: t)?.text == "a")
    }

    @Test func cutPointsIgnoreGeneratorClips() {
        let foot = Clip(name: "f", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        let gen = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(3)), start: s(2),
                       generator: GeneratorRef(kind: "text", payload: Data(), payloadVersion: 1))
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [foot])])
        t.tracks.append(Track(kind: .video, clips: [gen]))
        #expect(KeywordAtPlayhead.cutPoints(in: t) == [.zero, s(10)])
    }

    @Test func pressingTwiceOnTheSameWordNeverOverwrites() throws {
        let session = makeSession(clips: [(0, 10)])
        #expect(session.replaceCaptions([item("one two three four", 0, 8)]))
        session.seek(to: s(4))
        #expect(session.addKeywordAtPlayhead())
        let depth = session.undoDepth
        let first = try #require(session.selection.first)
        #expect(session.addKeywordAtPlayhead())
        #expect(session.undoDepth == depth + 1)   // new track and clip: one step
        let tl = try #require(session.activeTimeline)
        let gens = tl.tracks.lazy.flatMap(\.clips).filter { $0.generator != nil }
        #expect(gens.count == 2)
        #expect(gens.contains { $0.id == first })
        session.undo()
        let after = try #require(session.activeTimeline)
        #expect(after.tracks.count == tl.tracks.count - 1)
        #expect(after.tracks.lazy.flatMap(\.clips).contains { $0.id == first })
    }

    @Test func adjacentWordsWithOverlappingClipsKeepEarlierOnes() throws {
        let session = makeSession(clips: [(0, 10)])
        #expect(session.replaceCaptions([item("one two three four", 0, 8)]))
        var ids: [Clip.ID] = []
        for sec in [Time(1, 2), Time(2, 1), Time(4, 1), Time(7, 1)] {
            session.seek(to: sec)
            #expect(session.addKeywordAtPlayhead())
            ids.append(try #require(session.selection.first))
        }
        let all = try #require(session.activeTimeline).tracks.flatMap(\.clips)
        for id in ids { #expect(all.contains { $0.id == id }) }
        #expect(all.filter { $0.generator != nil }.count == 4)
    }

    @Test func secondKeywordIsNotShortenedByTheFirstKeywordsEdge() throws {
        let session = makeSession(clips: [(0, 10)])
        #expect(session.replaceCaptions([item("one two three four", 0, 8)]))
        session.seek(to: Time(1, 2))   // "one", 0 s, runs 3 s (cap)
        #expect(session.addKeywordAtPlayhead())
        session.seek(to: Time(2, 1))   // "two", 1.6 s: its own cap is 4.6 s, not first clip end 3 s + 0.3
        #expect(session.addKeywordAtPlayhead())
        let id = try #require(session.selection.first)
        let clip = try #require(session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(clip.timeline.end == Time(23, 5).snapped(to: Time(1, 30)))
    }
}
