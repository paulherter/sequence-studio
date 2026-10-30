import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellTrimModeTests {
    private func f(_ n: Int64) -> Time { Time(n, 30) }

    func host() -> ShellHost {
        func c(_ start: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
        }
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c(0)); try! v.overwrite(c(60)); try! v.overwrite(c(150))
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
        let s = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        s.seek(to: f(58))
        return ShellHost(session: s, map: .premiereDefault)
    }

    @Test func toggleOpensAtTheNearestEditAndClosesAgain() {
        let h = host()
        #expect(h.execute(.toggleTrimMode))
        #expect(h.trim.isActive)
        #expect(h.execute(.toggleTrimMode))
        #expect(!h.trim.isActive)
    }

    @Test func arrowsTrimOnlyWhileTrimModeIsOn() {
        let h = host()
        h.focus = .timeline
        #expect(!h.runTrimCommand(.stepForward))
        _ = h.execute(.toggleTrimMode)
        let before = h.trim.frames
        #expect(h.runTrimCommand(.stepForward))
        #expect(h.trim.frames != before || h.trim.note != "")
        #expect(h.runTrimCommand(.toggleTrimType))
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        #expect(h.runTrimCommand(.playPause))
        #expect(lines.last == "Close Trim mode to play.")
    }

    @Test func trimKeysAreForTheTimelineAndProgramOnly() {
        let h = host()
        _ = h.execute(.toggleTrimMode)
        h.focus = .project
        #expect(!h.runTrimCommand(.stepForward))
        h.focus = .programMonitor
        #expect(h.runTrimCommand(.stepForward))
    }

    @Test func escapeLeavesTrimModeBeforeAnythingElse() {
        let h = host()
        _ = h.execute(.toggleTrimMode)
        let clip = h.session.activeTimeline!.tracks[0].clips[0].id
        h.session.select(clips: [clip], captions: [])
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(!h.trim.isActive)
        #expect(!h.session.selection.isEmpty)   // the selection waits for the next Esc
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(h.session.selection.isEmpty)
    }
}

@MainActor
@Suite struct ShellFullScreenTests {
    @Test func escapeLeavesFullScreenAndOnlyEscape() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        var seen: [Bool] = []
        h.onFullScreenChange = { seen.append($0) }
        #expect(!h.fullScreenKey(.keyDown(.escape, modifiers: [])))   // not in Full Screen: not taken
        #expect(h.enterProgramFullScreen())
        #expect(!h.enterProgramFullScreen())
        #expect(!h.fullScreenKey(.keyDown(.space, modifiers: [])))    // other keys use the normal routing
        #expect(!h.fullScreenKey(.keyDown(.escape, modifiers: .shift)))
        #expect(h.fullScreenKey(.keyDown(.escape, modifiers: [])))
        #expect(!h.isProgramFullScreen && seen == [true, false])
    }

    @Test func noSequenceNoFullScreen() {
        let h = ShellHost(session: EditorSession(project: Project(name: "P", timelines: [])), map: .premiereDefault)
        #expect(!h.enterProgramFullScreen())
    }

    @Test func pictureIsFittedAndCentered() {
        let r = ShellHost.fullScreenPictureRect(in: CGSize(width: 1000, height: 400), picture: (1920, 1080))
        #expect(r.height == 400 && r.width == 711 && r.minX == 144.5.rounded())
        let tall = ShellHost.fullScreenPictureRect(in: CGSize(width: 400, height: 1000), picture: (1920, 1080))
        #expect(tall.width == 400 && tall.height == 225 && tall.minY == 388)
    }
}
