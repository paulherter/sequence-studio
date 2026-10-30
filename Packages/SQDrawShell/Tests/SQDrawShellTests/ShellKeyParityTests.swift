import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Keyboard parity of the shared shell with the AppKit app (audit 1): undo after edits, every focus.
@MainActor
@Suite struct ShellKeyParityTests {
    func host() -> (ShellHost, Clip) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        let h = ShellHost(session: EditorSession(project: Project(name: "P", timelines: [tl])), map: .premiereDefault)
        h.size = CGSize(width: 1000, height: 700)
        return (h, clip)
    }
    func count(_ h: ShellHost) -> Int { h.session.activeTimeline?.tracks.flatMap(\.clips).count ?? 0 }

    @Test func undoAndRedoAfterARealEditInEveryFocus() {
        let focuses: [PanelID?] = [nil] + PanelID.allCases.map { Optional($0) }
        for focus in focuses {
            let (h, clip) = host()
            h.focus = focus
            h.session.select(clips: [clip.id])
            h.session.seek(to: Time(1, 1))
            h.session.addEditAtPlayhead()
            #expect(count(h) == 2)
            #expect(h.handle(.keyDown(.character("z"), modifiers: .command), scale: 1), "undo taken, focus \(String(describing: focus))")
            #expect(count(h) == 1, "undone, focus \(String(describing: focus))")
            #expect(h.handle(.keyDown(.character("z"), modifiers: [.command, .shift]), scale: 1))
            #expect(count(h) == 2, "redone, focus \(String(describing: focus))")
        }
    }

    func press(_ h: ShellHost, _ k: InputKey, repeating: Bool = false, _ m: InputModifiers = []) -> Bool {
        HostKeyRepeat.shared.with(repeating) { h.handle(.keyDown(k, modifiers: m), scale: 1) }
    }

    @Test func aHeldKeyDoesNotRepeatAOneShotCommand() {
        let (h, clip) = host()
        h.session.select(clips: [clip.id])
        #expect(press(h, .space))
        #expect(h.session.isPlaying)
        #expect(press(h, .space, repeating: true), "swallowed, not passed on")
        #expect(h.session.isPlaying, "a held Space runs once")
    }

    @Test func repeatedUndoStillUndoes() {
        let (h, clip) = host()
        h.session.select(clips: [clip.id])
        h.session.seek(to: Time(1, 1)); h.session.addEditAtPlayhead(); h.session.addEditAtPlayhead()
        _ = press(h, .character("z"), repeating: true, .command)
        #expect(count(h) <= 2)
    }

    @Test func lPlaysAndKStops() {
        let (h, _) = host()
        #expect(press(h, .character("l")))
        #expect(h.session.isPlaying)
        h.keyUp(.character("l"))
        #expect(h.session.isPlaying, "L keeps playing after the key comes up")
        #expect(press(h, .character("k")))
        h.keyUp(.character("k"))
        #expect(!h.session.isPlaying)
    }

    @Test func kHeldAndLStepsOneFrame() {
        let (h, _) = host()
        let t0 = h.session.monitorTime
        #expect(press(h, .character("k")))
        #expect(press(h, .character("l")))
        h.keyUp(.character("l")); h.keyUp(.character("k"))
        #expect(h.session.monitorTime > t0)
        #expect(!h.session.isPlaying)
    }

    @Test func escapeClearsTheSelection() {
        let (h, clip) = host()
        h.session.select(clips: [clip.id])
        #expect(press(h, .escape))
        #expect(h.session.selection.isEmpty)
        #expect(!press(h, .escape), "nothing selected: Esc is not ours")
    }
}
