import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}
private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "default")
}
private let textTemplate = TextTemplate(name: "Text", text: "Hello", style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white))

@MainActor @Suite struct CaptionStyleSessionTests {
    @Test func trackStyleIsOneUndoStepAndRespectsOverrides() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        let b = session.captionItems[1].id
        session.select(clips: [], captions: [b])
        #expect(session.setSelectedCaptionStyle("outline"))
        let depth = session.undoDepth
        #expect(session.setCaptionStyle(styleRef: "tiktok"))
        #expect(session.undoDepth == depth + 1)
        #expect(session.captionItems.map(\.styleRef) == ["tiktok", "outline"])
        #expect(session.selectedCaptionsHaveOwnStyle)
        #expect(session.setSelectedCaptionStyle(nil))
        #expect(session.captionItems.map(\.styleRef) == ["tiktok", "tiktok"])
        session.undo()
        #expect(session.captionItems.map(\.styleRef) == ["tiktok", "outline"])
        session.undo()                      // the track style was one step
        #expect(session.captionItems.map(\.styleRef) == ["default", "outline"])
    }

    @Test func karaokeTurnsOnAndOffForTheTrackInOneStep() {
        let session = makeSession()
        session.replaceCaptions([item("a b", 0, 2)])
        #expect(session.captionKaraoke == nil)
        let depth = session.undoDepth
        #expect(session.setCaptionKaraoke(KaraokeStyle()))
        #expect(session.captionKaraoke == KaraokeStyle() && session.undoDepth == depth + 1)
        #expect(session.setCaptionKaraoke(nil))
        #expect(session.captionKaraoke == nil)
    }

    @Test func karaokeNeedsACaptionTrack() {
        #expect(!makeSession().setCaptionKaraoke(KaraokeStyle()))
    }

    // MARK: Type tool hit test

    @Test func theTopmostTextClipUnderTheClickIsHitAndNothingIsChanged() throws {
        let session = makeSession()
        let a = try #require(session.addTextClip(template: textTemplate, position: .zero))
        let b = try #require(session.addTextClip(template: textTemplate, position: .zero))   // second text goes one track higher
        let depth = session.undoDepth
        let tl = try #require(session.activeTimeline)
        let top = try #require(tl.tracks.last { $0.kind == .video && $0.clips.contains { $0.id == a || $0.id == b } })
        let topClip = try #require(top.clips.first)
        let hit = TextHitTest.topmostTextClip(at: .zero, in: tl, project: session.project, time: .zero)
        #expect(hit == topClip.id)
        #expect(TextHitTest.topmostTextClip(at: Vec2(900, 500), in: tl, project: session.project, time: .zero) == nil)
        #expect(TextHitTest.topmostTextClip(at: .zero, in: tl, project: session.project, time: s(60)) == nil)   // not under the playhead
        #expect(session.undoDepth == depth)
    }

    // MARK: Captions in the monitor

    @Test func aDoubleClickOnTheCaptionTextHitsIt() throws {
        let session = makeSession()
        session.replaceCaptions([item("Hello world", 0, 4)])
        let tl = try #require(session.activeTimeline)
        let it = session.captionItems[0]
        let r = CaptionMonitorHit.textRect(of: it, canvas: tl.format)
        #expect(r.maxY < Double(tl.format.height) / 2 && r.minY > 0)          // in the lower half
        #expect(CaptionMonitorHit.caption(at: Vec2(Double(r.midX), Double(r.midY)), in: tl, time: s(1)) == it.id)
        #expect(CaptionMonitorHit.caption(at: Vec2(0, -400), in: tl, time: s(1)) == nil)       // the top of the picture
        #expect(CaptionMonitorHit.caption(at: Vec2(Double(r.midX), Double(r.midY)), in: tl, time: s(5)) == nil)   // not showing
    }

    @Test func anEmptyCaptionCanStillBeClicked() throws {
        let session = makeSession()
        session.replaceCaptions([item("", 0, 4)])
        let tl = try #require(session.activeTimeline)
        let r = CaptionMonitorHit.textRect(of: session.captionItems[0], canvas: tl.format)
        #expect(CaptionMonitorHit.caption(at: Vec2(Double(r.midX), Double(r.midY)), in: tl, time: s(1)) != nil)
    }

    @Test func aHiddenCaptionTrackIsNotHit() throws {
        let session = makeSession()
        session.replaceCaptions([item("Hello", 0, 4)])
        var tl = try #require(session.activeTimeline)
        tl.captionTracks[0].isVisible = false
        let r = CaptionMonitorHit.textRect(of: tl.captionTracks[0].items[0], canvas: tl.format)
        #expect(CaptionMonitorHit.caption(at: Vec2(Double(r.midX), Double(r.midY)), in: tl, time: s(1)) == nil)
    }

    // MARK: Default text length

    @Test func theTextLengthPreferenceRoundTripsAndFallsBack() {
        let name = "sq-textlen-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(AppSettings.load(from: d).defaultTextSeconds == 5)
        var st = AppSettings.standard
        st.defaultTextSeconds = 8
        st.save(to: d)
        #expect(AppSettings.load(from: d).defaultTextSeconds == 8)
        d.set(0, forKey: AppSettings.Key.textSeconds)
        #expect(AppSettings.load(from: d).defaultTextSeconds == 5)
    }

    @Test func aTextClipTakesTheRequestedLength() throws {
        let session = makeSession()
        let id = try #require(session.addTextClip(template: textTemplate, duration: s(8), position: .zero))
        let clip = try #require(session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(clip.source.duration == s(8))
    }

    // MARK: Words of created captions

    @Test func createdCaptionsKeepTheirWordTimingsThroughTheClipMapping() {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), end: s(20)), start: s(2))
        let words = [CaptionWord(text: "a", range: TimeRange(start: s(11), end: s(12))),
                     CaptionWord(text: "b", range: TimeRange(start: s(12), end: s(14)))]
        let cap = Caption(lines: ["a b"], range: TimeRange(start: s(11), end: s(14)), styleRef: "default", animationRef: "none",
                          words: words)
        let items = CaptionMapping.items([cap], for: clip)
        #expect(items.count == 1)
        #expect(items[0].range == TimeRange(start: s(3), end: s(6)))
        #expect(items[0].words.map(\.range.start) == [s(0), s(1)])   // relative to the caption start
        #expect(items[0].effectiveWords.map(\.range.start) == [s(3), s(4)])
        #expect(items[0].hasWordTimings)
    }
}
