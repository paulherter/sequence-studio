import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct SplitScreenSessionTests {
    private func session(tracks n: Int) -> (EditorSession, [Clip.ID]) {
        var ids: [Clip.ID] = []
        var tracks: [Track] = []
        for i in 0..<n {
            let c = Clip(name: "c\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
            ids.append(c.id)
            var t = Track(kind: .video)
            try! t.overwrite(c)
            tracks.append(t)
        }
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: tracks)
        return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine()), ids)
    }

    @Test func oneCommandOneUndoStep() {
        let (ses, ids) = session(tracks: 2)
        ses.select(clips: Set(ids))
        #expect(ses.applySplitScreen(.stacked, animated: true))
        let c = ses.activeTimeline!.tracks[1].clips[0]
        #expect(c.animation.position.isAnimated)
        #expect(c.effects.contains { $0.kind == ClipEffect.cropKind } || c.animation.scale.value != Vec2(1, 1) || c.animation.position.value != .zero)
        #expect(ses.undo())
        let back = ses.activeTimeline!.tracks[1].clips[0]
        #expect(back.effects.isEmpty && !back.animation.position.isAnimated && back.animation.position.value == .zero)
        #expect(!ses.canUndo)
    }

    @Test func refusesTooFewClips() {
        let (ses, ids) = session(tracks: 2)
        ses.select(clips: Set(ids))
        #expect(!ses.applySplitScreen(.threeStacked))
        #expect(!ses.canUndo)
    }

    @Test func sameTrackClipsAreRefused() {
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: Time(5, 1))
        var t = Track(kind: .video)
        try! t.overwrite(a); try! t.overwrite(b)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [t])
        let ses = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        ses.select(clips: [a.id, b.id])
        #expect(ses.splitScreenProblem(.sideBySide) == .sameTrack)
        #expect(!ses.applySplitScreen(.sideBySide))
        #expect(!ses.canUndo)
    }

    @Test func reportsExtraClips() {
        let (ses, ids) = session(tracks: 3)
        ses.select(clips: Set(ids))
        #expect(ses.splitScreenProblem(.sideBySide) == nil)
        #expect(ses.splitScreenExtraClips(.sideBySide) == 1)
    }

    @Test func menuReachesEveryPresetInTwoClicks() {
        let hasSubmenu = EditorMenus.clip.items.contains { item in
            if case .submenu("Split Screen", _) = item { return true }
            return false
        }
        #expect(hasSubmenu)
        let cmds = EditorMenus.clip.commands.filter { if case .splitScreen = $0 { true } else { false } }
        #expect(cmds.count == SplitLayoutPreset.allCases.count * 2)
        #expect(CommandSupport.isSupported(.splitScreen(.sideBySide, animated: false)))
    }
}
