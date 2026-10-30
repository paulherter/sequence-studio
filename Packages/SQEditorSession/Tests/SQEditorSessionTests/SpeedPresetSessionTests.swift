import Foundation
import SQCore
import Testing
@testable import SQEditorSession

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@MainActor
@Suite struct SpeedPresetSessionTests {
    private func make(beats: [Time] = []) -> (EditorSession, Clip) {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero, mediaDuration: f(4000))
        var t = Track(kind: .video)
        try! t.overwrite(c)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [t])
        tl.replaceBeatMarkers(in: TimeRange(start: .zero, duration: Time(100, 1)), with: beats)
        return (EditorSession(project: Project(name: "P", timelines: [tl])), c)
    }
    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    @Test func presetIsOneUndoStepAndEditableAfterwards() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        let depth = ses.undoDepth
        #expect(ses.applySpeedPreset(.punch, onBeat: false) == .applied(clips: 1))
        #expect(ses.undoDepth == depth + 1)
        #expect(clip(ses, c.id).speedKeys != nil)
        #expect(ses.canRemoveTimeRemapping)
        ses.undo()
        #expect(clip(ses, c.id).speedKeys == nil)
    }

    @Test func hitOnBeatNeedsABeatInsideTheClip() {
        let (ses, c) = make(beats: [Time(30, 1)])         // far outside the 5 s clip
        ses.select(clips: [c.id], captions: [])
        #expect(ses.applySpeedPreset(.pulse, onBeat: true) == .noBeat)
        #expect(clip(ses, c.id).speedKeys == nil)
    }

    @Test func hitOnBeatPutsThePeakOnTheBeat() {
        let (ses, c) = make(beats: [Time(2, 1)])
        ses.select(clips: [c.id], captions: [])
        #expect(ses.applySpeedPreset(.crest, onBeat: true) == .applied(clips: 1))
        let k = clip(ses, c.id).speedKeys!
        let d = k.peakTime - Time(2, 1)
        #expect((d < .zero ? .zero - d : d) <= fd * 2)
    }

    @Test func cutAndSnapAreUndoable() {
        let (ses, c) = make(beats: [Time(1, 1), Time(2, 1), Time(4, 1)])
        ses.select(clips: [c.id], captions: [])
        #expect(ses.cutToBeats() == 3)
        #expect(ses.activeTimeline!.tracks[0].clips.count == 4)
        ses.undo()
        #expect(ses.activeTimeline!.tracks[0].clips.count == 1)
        #expect(ses.snapToBeats() == 1)                    // the 5 s end moves to the 4 s beat
        #expect(ses.activeTimeline!.tracks[0].clips[0].timeline.end == Time(4, 1))
        ses.undo()
        #expect(ses.activeTimeline!.tracks[0].clips[0].timeline.end == Time(5, 1))
    }

    @Test func commandsAreSupportedAndInTheClipMenu() {
        let cmds = EditorMenus.clip.commands
        #expect(cmds.contains(.cutToBeats) && cmds.contains(.snapToBeats))
        #expect(cmds.contains(.speedRampPreset(.surge, onBeat: true)))
        #expect(CommandSupport.isSupported(.speedRampPreset(.rush, onBeat: false)))
        #expect(CommandSupport.isSupported(.cutToBeats))
    }
}
