import Foundation
import Testing
import SQCore
@testable import SQEditorSession

// Bundle / Unbundle (Opt+Cmd+G), Make Subclip (Cmd+U) and Edit Original (Cmd+E) at the session level.

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, media: UUID = UUID(), link: UUID? = nil) -> Clip {
    Clip(name: "c\(start)", media: media, kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}

private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}

@MainActor private func makeSession(_ tracks: [Track], media: [MediaRef] = []) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    var p = Project(name: "P", timelines: [t])
    for m in media { p.add(m) }
    return EditorSession(project: p, engine: StubProgramEngine())
}

@MainActor @Suite struct BundleSessionTests {
    @Test func bundleSelectsTheWholeBundleAndUndoes() {
        let a = clip(0, 2), b = clip(4, 2), c = clip(8, 2)
        let ses = makeSession([track([a, b, c])])
        ses.select(clips: [a.id])
        #expect(ses.bundleMenuState.canBundle == false)
        ses.select(clips: [a.id, b.id])
        #expect(ses.bundleMenuState == (true, false))
        #expect(ses.bundleSelection())
        #expect(ses.selection == [a.id, b.id])
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips[0].bundle != nil && clips[0].bundle == clips[1].bundle && clips[2].bundle == nil)
        // An existing bundle counts as one unit: nothing more to bundle.
        #expect(ses.bundleMenuState == (false, true))
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.allSatisfy { $0.bundle == nil })
    }

    @Test func nudgeMovesTheBundleTogether() {
        let a = clip(0, 2), b = clip(4, 2)
        let ses = makeSession([track([a, b])])
        ses.select(clips: [a.id, b.id])
        ses.bundleSelection()
        ses.nudgeSelection(frames: 3)
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0) + fd * 3, s(4) + fd * 3])
    }

    @Test func unbundleClearsAndRefusesWithoutABundle() {
        let a = clip(0, 2), b = clip(4, 2)
        let ses = makeSession([track([a, b])])
        ses.select(clips: [a.id])
        #expect(!ses.unbundleSelection())
        ses.select(clips: [a.id, b.id])
        ses.bundleSelection()
        ses.select(clips: [b.id])
        #expect(ses.unbundleSelection())
        #expect(ses.activeTimeline!.tracks[0].clips.allSatisfy { $0.bundle == nil })
    }

    @Test func linkedSelectionExpandsToTheBundle() {
        let a = clip(0, 2), b = clip(4, 2)
        let ses = makeSession([track([a, b])])
        ses.select(clips: [a.id, b.id])
        ses.bundleSelection()
        #expect(ses.expandingLinks([a.id]) == [a.id, b.id])
        ses.linkedSelection = false
        #expect(ses.expandingLinks([a.id]) == [a.id])
    }

    @Test func makeSubclipUsesTheSourceMarks() {
        let m = MediaRef(name: "Interview.mov", path: "/v/Interview.mov", fingerprint: MediaFingerprint(size: 1), duration: s(60))
        let ses = makeSession([track([])], media: [m])
        #expect(ses.makeSubclip(of: m.id) == nil)
        #expect(ses.lastError != nil)
        ses.setSourceMarks(SourceMarks(markIn: s(10), markOut: s(20)), for: m.id)
        let id = ses.makeSubclip(of: m.id)
        let sub = ses.project.media(id ?? UUID())
        #expect(sub?.subclip?.parent == m.id)
        #expect(sub?.subclip?.range.start == s(10))
        #expect(sub?.path == m.path)
        #expect(ses.undo())
        #expect(ses.project.media.count == 1)
    }

    @Test func originalFilesSkipGeneratorsAndRepeat() {
        let m = MediaRef(name: "A.mov", path: "/v/A.mov", fingerprint: MediaFingerprint(size: 1), duration: s(60))
        let a = clip(0, 2, media: m.id), b = clip(4, 2, media: m.id)
        var title = clip(8, 2)
        title.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data())
        let ses = makeSession([track([a, b, title])], media: [m])
        ses.select(clips: [a.id, b.id, title.id])
        #expect(ses.originalFilesOfSelection == ["/v/A.mov"])
        ses.select(clips: [title.id])
        #expect(ses.originalFilesOfSelection.isEmpty)
    }
}
