import Foundation
import Testing
import SSCore
import SSText
import SSTranscribe
@testable import SSEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                     tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

@MainActor @Suite struct ClipSectionTests {
    @Test func sectionFollowsSelection() {
        let video = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let audio = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                        generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
        #expect(ClipSectionMode.resolve(nil) == .none)
        #expect(ClipSectionMode.resolve(video) == .none)
        #expect(ClipSectionMode.resolve(audio) == .audio)
        #expect(ClipSectionMode.resolve(text) == .text)
        #expect(ClipSectionMode.text.title == "Text" && ClipSectionMode.audio.title == "Audio")
    }

    @Test func captionsShiftOntoTimelineAndStayInsideClip() {
        // Clip shows source 10..14 at timeline 100..104: offset +90.
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(100))
        func word(_ a: Int64) -> TranscriptWord { TranscriptWord(text: "w\(a)", range: TimeRange(start: s(a), duration: Time(1, 2))) }
        let transcript = Transcript(language: "en-US", words: [word(2), word(11), word(12), word(30)])
        let captions = CaptionSegmenter.segment(transcript, preset: .standard)
        let items = CaptionMapping.items(captions, for: clip)
        #expect(!items.isEmpty && items.count < captions.count)
        #expect(items.allSatisfy { clip.timeline.intersection($0.range) == $0.range })
        let inside = captions.filter { $0.range.overlaps(clip.source) }
        #expect(items.first?.range.start == max(inside[0].range.start + s(90), s(100)))
    }

    @Test func captionsOfAllClipsOfOneMediaAreMappedAndNeverOverlap() {
        let media = UUID()
        // Two cuts of the same recording (source 0..4 at 0, source 10..14 at 4) plus the linked audio half of the first.
        let a = Clip(name: "a", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
        let b = Clip(name: "b", media: media, kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(4))
        let au = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
        func word(_ x: Int64) -> TranscriptWord { TranscriptWord(text: "w\(x)", range: TimeRange(start: s(x), duration: Time(1, 2))) }
        let captions = CaptionSegmenter.segment(Transcript(language: "en-US", words: [word(1), word(11), word(30)]),
                                                preset: CaptionPreset(maxCharsPerLine: 20, maxLines: 1, maxDuration: s(6), minDuration: .zero,
                                                                      pauseBreak: Time(1, 2), styleRef: "d", animationRef: "n"))
        let items = CaptionMapping.items(captions, forClips: [b, au, a])
        #expect(items.count == 2)                                   // word at 30 is outside both cuts; audio half adds nothing
        #expect(items[0].range.start == s(1) && items[1].range.start == s(5))
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.range.end <= $1.range.start })
    }

    @Test func captionsLandOnTheFrameGrid() {
        let fd = Time(1001, 30000)
        func item(_ a: Time, _ b: Time) -> CaptionItem { CaptionItem(lines: ["x"], range: TimeRange(start: a, end: b)) }
        // 0.52 s .. 1.7 s at 29.97: frame 15.55 -> 16, 50.9 -> 51
        let r = CaptionMapping.snapped([item(Time(52, 100), Time(17, 10))], to: fd)
        #expect(r[0].range.start == fd * 16 && r[0].range.end == fd * 51)
        // Two captions that touch still touch; one that collapses gets a frame or goes.
        let t = CaptionMapping.snapped([item(Time(52, 100), Time(100, 100)), item(Time(100, 100), Time(150, 100))], to: fd)
        #expect(t[0].range.end == t[1].range.start)
        let tiny = CaptionMapping.snapped([item(Time(1, 1), Time(1, 1) + Time(1, 1000)), item(Time(2, 1), Time(3, 1))], to: fd)
        #expect(tiny.count == 2 && tiny[0].range.end - tiny[0].range.start == fd)
        let squeezed = CaptionMapping.snapped([item(Time(1, 1), Time(1, 1) + Time(1, 1000)), item(Time(1, 1) + Time(1, 1000), Time(2, 1))], to: fd)
        #expect(squeezed.count == 1)                                   // no room for a frame: dropped, never overlapping
        #expect(zip(t, t.dropFirst()).allSatisfy { $0.range.end <= $1.range.start })
    }

    @Test func textTemplatesExist() {
        #expect(!TextTemplateCatalog.all.isEmpty)
        #expect(TextTemplateCatalog.all.allSatisfy { $0.template.text == TextTemplateCatalog.placeholderText })
    }

    @Test func addTextClipIsOneUndoStepAndSelects() throws {
        let session = makeSession()
        let entry = try #require(TextTemplateCatalog.all.first)
        let id = try #require(session.addTextClip(template: entry.template, at: s(2), duration: s(3)))
        #expect(session.selection == [id])
        let clip = try #require(session.singleSelectedClip)
        #expect(clip.generator?.kind == GeneratorRef.text)
        #expect(clip.start == s(2))
        session.undo()
        #expect(session.activeTimeline?.tracks.allSatisfy { $0.clips.isEmpty } == true)
    }

    @Test func textEditsOfOneGestureMergeIntoOneStep() throws {
        let session = makeSession()
        let entry = try #require(TextTemplateCatalog.all.first)
        let id = try #require(session.addTextClip(template: entry.template))
        var t = entry.template
        t.text = "A"; session.updateTextClip(id, template: t, animations: nil, continuesGesture: false)
        t.text = "AB"; session.updateTextClip(id, template: t, animations: nil, continuesGesture: true)
        t.text = "ABC"; session.updateTextClip(id, template: t, animations: nil, continuesGesture: true)
        let decoded = try TextGenerator.decode(try #require(session.singleSelectedClip?.generator)).0
        #expect(decoded.text == "ABC")
        session.undo()
        let back = try TextGenerator.decode(try #require(session.singleSelectedClip?.generator)).0
        #expect(back.text == TextTemplateCatalog.placeholderText)
    }

    @Test func roundedCornersOnlyOnPictureClipsAndOneStep() throws {
        let session = makeSession()
        let entry = try #require(TextTemplateCatalog.all.first)
        let id = try #require(session.addTextClip(template: entry.template))
        #expect(session.addRoundedCorners(radius: 12))
        #expect(session.singleSelectedClip?.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 12)
        #expect(!session.addRoundedCorners(radius: 30))           // already on: nothing changes
        #expect(session.singleSelectedClip?.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 12)
        session.undo()
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.roundedCorners == nil)
    }

    @Test func roundedCornersDroppedOnAnUnselectedClip() throws {
        let session = makeSession()
        let entry = try #require(TextTemplateCatalog.all.first)
        let id = try #require(session.addTextClip(template: entry.template))
        session.select(clips: [], captions: [])
        #expect(!session.addRoundedCorners())                       // nothing selected
        #expect(session.addRoundedCorners(to: [id], radius: 10))
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 10)
        session.undo()
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.roundedCorners == nil)
    }

    @Test func createCaptionsReplacesTrackInOneStep() throws {
        let session = makeSession()
        let item = CaptionItem(lines: ["Hi"], range: TimeRange(start: .zero, duration: s(1)))
        #expect(session.replaceCaptions([item]))
        #expect(session.activeTimeline?.captionTracks.first?.items.count == 1)
        session.undo()
        #expect(session.activeTimeline?.captionTracks.isEmpty == true)
    }
}
