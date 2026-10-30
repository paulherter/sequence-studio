import Foundation
import Testing
import SQCore
import SQLibrary
import SQText
import SQTranscribe
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}
private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "default")
}
private func tempStore() throws -> PresetStore {
    try PresetStore(applicationSupport: FileManager.default.temporaryDirectory.appendingPathComponent("SQLook-\(UUID().uuidString)"))
}

@MainActor @Suite struct CaptionLookSessionTests {
    @Test func createdCaptionsAllAnimateWithTheDefaultLook() {
        let words = (0..<12).map { i in
            TranscriptWord(text: "w\(i)", range: TimeRange(start: Time(Int64(i), 2), end: Time(Int64(i) + 1, 2)))
        }
        let preset = CaptionLookLibrary(store: nil, defaults: UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!)
            .applyDefault(to: .standard)
        let caps = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(Transcript(language: "en-US", words: words), preset: preset),
                                                preset: preset)
        #expect(!caps.isEmpty)
        var noAnim = CaptionPreset.standard
        noAnim.animationRef = "none"
        let none = CaptionLookLibrary(store: nil, defaults: UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!)
            .applyDefault(to: noAnim)
        #expect(none.animationRef == "none")
        for c in caps {
            #expect(CaptionPresetLibrary.builtIn.animation(for: c.animationRef) == .captionPop)
            #expect(CaptionPresetLibrary.builtIn.style(for: c.styleRef).shadow != nil)
        }
    }

    @Test func pushLookIsOneUndoStepAndReachesEveryCaption() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        var look = CaptionLook.default
        look.style.size = 77
        let id = UUID().uuidString
        defer { CaptionLookRegistry.shared.unregister(id: id) }
        let depth = session.undoDepth
        #expect(session.pushCaptionLook(look, id: id))
        #expect(session.undoDepth == depth + 1)
        for c in session.captionItems {
            #expect(CaptionPresetLibrary.builtIn.style(for: c.styleRef).size == 77)
            #expect(CaptionPresetLibrary.builtIn.animation(for: c.animationRef) == .captionPop)
        }
    }

    @Test func styleEditKeepsTheCustomAnimationOfAllCaptions() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        var look = CaptionLook.default
        look.animation = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 3), 1, .linear)])], duration: Time(1, 3))
        let id = UUID().uuidString
        defer { CaptionLookRegistry.shared.unregister(id: id) }
        #expect(session.pushCaptionLook(look, id: id))
        #expect(session.editCaptionStyle(.size(60), scope: .all))
        let lib = CaptionLookRegistry.shared.library(for: session.project)
        for c in session.captionItems { #expect(lib.animation(for: c.animationRef) == look.animation) }
    }

    @Test func pushReleasesTheOverrideOfTheEditedCaption() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        session.select(clips: [], captions: [session.captionItems[1].id])
        #expect(session.setSelectedCaptionStyle("outline"))
        var look = session.currentCaptionLook()!
        look.style.size = 55
        let id = UUID().uuidString
        defer { CaptionLookRegistry.shared.unregister(id: id) }
        let depth = session.undoDepth
        #expect(session.pushCaptionLook(look, id: id))
        #expect(session.undoDepth == depth + 1)
        #expect(!session.selectedCaptionsHaveOwnStyle)
        #expect(session.captionItems.allSatisfy { CaptionPresetLibrary.builtIn.style(for: $0.styleRef).size == 55 })
    }

    @Test func lookOfSelectedCaptionIsWhatUpdateLookPushes() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        session.select(clips: [], captions: [session.captionItems[1].id])
        #expect(session.setSelectedCaptionStyle("outline"))
        let look = session.currentCaptionLook()
        #expect(look?.style == CaptionPresetLibrary.builtIn.style(for: "outline"))
    }

    @Test func animationFromSelectedTextClip() throws {
        let session = makeSession()
        let style = TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white)
        let template = TextTemplate(name: "t", text: "Hi", style: style)
        let id = try #require(session.addTextClip(template: template))
        session.updateTextClip(id, template: template, animations: AnimationSet(in: .captionPop, out: nil), continuesGesture: false)
        session.select(clips: [])
        #expect(session.animationFromSelectedTextClip() == nil)       // nothing selected
        session.select(clips: [id])
        #expect(session.animationFromSelectedTextClip() == .captionPop)
    }

    /// W7.3: a text clip animated only by a text animator (word pop) hands it to the captions.
    @Test func animatorOnlyTextClipAnimationGoesToCaptions() throws {
        let session = makeSession()
        let template = TextTemplate(name: "t", text: "Hi there", style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white))
        let id = try #require(session.addTextClip(template: template))
        let words = KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, easing: .overshoot,
                                                                duration: Time(3, 10), stagger: Time(2, 25)))
        session.updateTextClip(id, template: template, animations: AnimationSet(in: words, out: nil), continuesGesture: false)
        session.select(clips: [id])
        #expect(session.animationFromSelectedTextClip() == words)
    }

    /// An empty in-animation does not hide a real out-animation.
    @Test func emptyInSideFallsThroughToOut() throws {
        let session = makeSession()
        let template = TextTemplate(name: "t", text: "Hi", style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white))
        let id = try #require(session.addTextClip(template: template))
        let out = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 2), 0, .linear)]),
        ], duration: Time(1, 2), anchor: .end)
        session.updateTextClip(id, template: template, animations: AnimationSet(in: .none, out: out), continuesGesture: false)
        session.select(clips: [id])
        #expect(session.animationFromSelectedTextClip() == out)
    }

    @Test func libraryPersistsLooksAndDefault() async throws {
        let store = try tempStore()
        let defaults = UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!
        // Both libraries are views of one Look store; the old preset store only keeps a copy.
        let looks = LookStore(url: nil, registry: .shared)
        let lib = CaptionLookLibrary(looks: looks, legacy: store, defaults: defaults)
        var look = CaptionLook.default; look.style.size = 61
        let id = try await lib.save(name: "Big", look: look, segmentation: .shortVideo, makeDefault: true)
        #expect(lib.defaultLookID == id)
        let again = CaptionLookLibrary(looks: looks, legacy: store, defaults: defaults)
        await again.reload()
        #expect(again.looks.count == 1)
        #expect(again.looks[0].look == look && again.looks[0].segmentation == .shortVideo)
        let preset = again.applyDefault(to: .standard)
        #expect(CaptionPresetLibrary.builtIn.style(for: preset.styleRef).size == 61)
        #expect(preset.maxCharsPerLine == CaptionPreset.shortVideo.maxCharsPerLine)
        var edited = look; edited.style.size = 62
        try await again.update(id, look: edited, segmentation: nil)
        await lib.reload()
        #expect(lib.looks[0].look.style.size == 62)
        try await lib.delete(id)
        #expect(lib.defaultLookID == nil && lib.looks.isEmpty)
    }
}
