import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

/// Sequence > Change Format / Duplicate as Format as session calls (the Mac sheet and the portable shell share them), the
/// text block measure the conform uses, and the Pixel Aspect choices of the Project selection.
@MainActor @Suite struct FormatSessionTests {
    static func session() -> (EditorSession, Clip) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), clip)
    }

    @Test func changeFormatIsOneUndoStepOnTheActiveSequence() throws {
        let (s, _) = Self.session()
        var f = try #require(s.activeTimeline).format
        f.width = 1080; f.height = 1920
        #expect(s.changeActiveFormat(to: f, mode: .fill, selectedMode: nil))
        #expect(s.activeTimeline?.format.width == 1080)
        #expect(s.activeTimeline?.format.height == 1920)
        #expect(s.undoName == "Change Format")
        s.undo()
        #expect(s.activeTimeline?.format.width == 1920)
    }

    @Test func changeFormatToTheSameFormatDoesNothing() throws {
        let (s, _) = Self.session()
        let f = try #require(s.activeTimeline).format
        #expect(!s.changeActiveFormat(to: f, mode: .fill, selectedMode: nil))
        #expect(!s.canUndo)
    }

    @Test func duplicateAsFormatOpensTheCopyAndKeepsTheOriginal() throws {
        let (s, _) = Self.session()
        let original = try #require(s.activeTimeline)
        var f = original.format
        f.width = 1080; f.height = 1080
        let id = try #require(s.duplicateActiveSequence(as: f, mode: .fit, selectedMode: nil, name: ""))
        #expect(s.project.timelines.count == 2)
        #expect(s.activeTimelineID == id)
        #expect(s.activeTimeline?.format.width == 1080)
        #expect(s.project.timeline(original.id)?.format.width == 1920)
        #expect(s.activeTimeline?.name != "")
    }

    @Test func selectedModeOverridesOnlyTheSelection() throws {
        let (s, clip) = Self.session()
        s.select(clips: [clip.id])
        #expect(s.conformOverrides(selectedMode: .fit) == [clip.id: .fit])
        #expect(s.conformOverrides(selectedMode: nil).isEmpty)
    }

    @Test func textBlockIsMeasuredForTextClipsOnly() throws {
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 40)), animations: nil)
        let text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, generator: ref)
        let block = EditorSession.conformTextBlock(text)
        #expect((block?.width ?? 0) > 0)
        #expect((block?.height ?? 0) > 0)
        let plain = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        #expect(EditorSession.conformTextBlock(plain) == nil)
    }

    @Test func pixelAspectChoicesFollowTheSelectedMedia() throws {
        let info = MediaInfo(duration: Time(2, 1), video: VideoTrackInfo(width: 1440, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                                                 nominalFrameDuration: Time(1, 25), isVariableFrameRate: false))
        var p = Project(name: "P")
        let a = MediaRef(name: "a", path: "/x/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1), info: info)
        let sound = MediaRef(name: "s", path: "/x/s.wav", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                             info: MediaInfo(duration: Time(2, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        p.add(a); p.add(sound)
        let state = try #require(PixelAspectChoices.state(project: p, media: [a.id]))
        #expect(state.fromFile)
        #expect(state.sharedFile == .square)
        #expect(PixelAspectChoices.state(project: p, media: [a.id, sound.id]) == nil)   // sound has no picture
        #expect(PixelAspectChoices.state(project: p, media: []) == nil)
        #expect(PixelAspectChoices.ratioText(PixelAspect(4, 3)!) == "1.33")
        #expect(PixelAspectChoices.aspect(fromRatio: 2) == PixelAspect(2, 1))
        #expect(PixelAspectChoices.aspect(fromRatio: 0) == nil)
    }
}
