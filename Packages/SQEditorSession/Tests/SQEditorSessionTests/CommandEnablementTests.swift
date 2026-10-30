import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

@MainActor @Suite struct CommandEnablementTests {
    @Test func selectionCommandsNeedASelection() {
        let a = clip(0, 2), b = clip(2, 2)
        let ses = makeSession([track([a, b])])
        #expect(!ses.canNudgeOrSlideSelection)
        #expect(!ses.canSelectAdjacentClip(forward: true))
        #expect(!ses.canGoToSelectedClipEdge)
        #expect(!ses.canTrimSelectionToRange)
        ses.select(clips: [a.id])
        #expect(ses.canNudgeOrSlideSelection)
        #expect(ses.canGoToSelectedClipEdge)
        #expect(ses.canSelectAdjacentClip(forward: true))
        #expect(!ses.canSelectAdjacentClip(forward: false))
    }

    @Test func unlinkAndSoloFollowSelection() {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link), plain = clip(5, 1)
        let ses = makeSession([track([v, plain]), track([au], kind: .audio)])
        #expect(!ses.canUnlinkSelection)
        #expect(!ses.canSoloSelectedTracks)
        ses.select(clips: [plain.id])
        #expect(!ses.canUnlinkSelection)
        #expect(!ses.canSoloSelectedTracks)
        ses.select(clips: [v.id])
        #expect(ses.canUnlinkSelection)
        #expect(ses.canSoloSelectedTracks)       // the linked audio partner's track
    }

    @Test func muteAndDetachAudioAreUndoable() {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link)
        let ses = makeSession([track([v]), track([au], kind: .audio)])
        #expect(!ses.canMuteSelectedTracks && !ses.canDetachAudioSelection)
        ses.select(clips: [v.id])
        #expect(ses.canMuteSelectedTracks && ses.canDetachAudioSelection)
        #expect(ses.muteSelectedTracks() == true)
        #expect(ses.activeTimeline!.tracks[1].isMuted)
        #expect(ses.muteSelectedTracks() == false)
        #expect(ses.detachAudioSelection())
        #expect(ses.activeTimeline!.tracks[0].clips[0].link == nil)
        #expect(ses.selection == [au.id])
        #expect(!ses.canDetachAudioSelection)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].link == link)
    }

    @Test func newMuteSoloDetachKeysAreBoundWithoutConflict() {
        let m = CommandMap.sqDefault
        #expect(m.duplicates.isEmpty)
        func cmd(_ k: Character, _ mod: KeyModifiers) -> EditorCommand? { m.command(for: KeyBinding(.char(k), mod), focus: .timeline) }
        #expect(cmd("m", [.control, .shift]) == .muteTracks)
        #expect(cmd("s", [.control, .option]) == .solo)
        #expect(cmd("d", [.control, .shift]) == .detachAudio)
        for c in [EditorCommand.muteTracks, .solo, .detachAudio] { #expect(!EditorMenus.menuOnly.contains(c)) }
    }
}
