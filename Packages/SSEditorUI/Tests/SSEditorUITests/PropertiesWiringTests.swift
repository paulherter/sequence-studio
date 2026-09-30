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

@MainActor @Suite struct PropertiesWiringTests {
    @Test func modeFollowsSelection() {
        let video = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let audio = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                        generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
        #expect(PropertiesMode.resolve(selectedClip: nil, captionSelectionCount: 0) == .none)
        #expect(PropertiesMode.resolve(selectedClip: video, captionSelectionCount: 0) == .clip)
        #expect(PropertiesMode.resolve(selectedClip: audio, captionSelectionCount: 0) == .audio)
        #expect(PropertiesMode.resolve(selectedClip: text, captionSelectionCount: 0) == .text)
        #expect(PropertiesMode.resolve(selectedClip: text, captionSelectionCount: 1) == .captions)
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
        #expect(session.singleSelectedClip?.animation.cornerRadius.value == 12)
        #expect(!session.addRoundedCorners(radius: 30))           // already on: nothing changes
        #expect(session.singleSelectedClip?.animation.cornerRadius.value == 12)
        session.undo()
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.animation.cornerRadius.value == 0)
    }

    @Test func roundedCornersDroppedOnAnUnselectedClip() throws {
        let session = makeSession()
        let entry = try #require(TextTemplateCatalog.all.first)
        let id = try #require(session.addTextClip(template: entry.template))
        session.select(clips: [], captions: [])
        #expect(!session.addRoundedCorners())                       // nothing selected
        #expect(session.addRoundedCorners(to: [id], radius: 10))
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.animation.cornerRadius.value == 10)
        session.undo()
        #expect(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.animation.cornerRadius.value == 0)
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
