import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct ScrubGripHitTests {
    // 216 pt wide, inset 8: 200 pt of track for 10 s = 20 pt per second.
    private let m = MonitorScrubMath(duration: s(10), frameDuration: fd, width: 216, inset: 8)

    @Test func gripsWinWithinSixPoints() {
        #expect(m.hit(x: 48, markIn: s(2), markOut: s(8)) == .markIn)       // exactly on In (x = 48)
        #expect(m.hit(x: 53.9, markIn: s(2), markOut: s(8)) == .markIn)     // 5.9 pt off
        #expect(m.hit(x: 54.5, markIn: s(2), markOut: s(8)) == .playhead)   // 6.5 pt off
        #expect(m.hit(x: 168, markIn: s(2), markOut: s(8)) == .markOut)
        #expect(m.hit(x: 100, markIn: s(2), markOut: s(8)) == .playhead)
    }

    @Test func missingMarksAreNeverHit() {
        #expect(m.hit(x: 48, markIn: nil, markOut: nil) == .playhead)
        #expect(m.hit(x: 48, markIn: nil, markOut: s(8)) == .playhead)
        #expect(m.hit(x: 168, markIn: s(2), markOut: nil) == .playhead)
    }

    @Test func nearestGripWinsWhenBothAreInRange() {
        // In at 5 s (x 108) and Out at 5.25 s (x 113): a click at 112 is nearer to Out.
        #expect(m.hit(x: 112, markIn: s(5), markOut: Time(21, 4)) == .markOut)
        #expect(m.hit(x: 109, markIn: s(5), markOut: Time(21, 4)) == .markIn)
    }
}

@MainActor @Suite struct MarkDragModelTests {
    private func model() -> MonitorPanelModel {
        let m = MonitorPanelModel(frameDuration: fd, mode: .source)
        m.duration = s(10)
        return m
    }

    @Test func draggingInPastOutClearsOut() {
        let m = model()
        m.markIn = s(2); m.markOut = s(4)
        m.previewMark(.markIn, frame: s(6))
        #expect(m.markIn == s(6) && m.markOut == nil)
    }

    @Test func draggingOutBeforeInClearsInAndStoresTheFrameEnd() {
        let m = model()
        m.markIn = s(4); m.markOut = s(8)
        m.previewMark(.markOut, frame: s(3))
        #expect(m.markOut == s(3) + fd && m.markIn == nil)
        m.markIn = s(1)
        m.previewMark(.markOut, frame: s(5))
        #expect(m.markOut == s(5) + fd && m.markIn == s(1))
    }

    @Test func commitReportsOnceWithTheFinalValue() {
        let m = model()
        var got: [(MonitorScrubMath.Hit, Time)] = []
        m.onMarkEdit = { got.append(($0, $1)) }
        m.markIn = s(2); m.markOut = s(8)
        m.previewMark(.markIn, frame: s(3)); m.previewMark(.markIn, frame: s(4))
        #expect(got.isEmpty)
        m.commitMark(.markIn)
        #expect(got.count == 1 && got[0].0 == .markIn && got[0].1 == s(4))
    }
}

@MainActor @Suite struct RelativeTimecodeTests {
    private let tc = Timecode(frameDuration: fd, dropFrame: false)

    @Test func framesAndTimecodeAmounts() {
        #expect(tc.parseRelative("+10") == fd * 10)
        #expect(tc.parseRelative("-5") == .zero - fd * 5)
        #expect(tc.parseRelative("+1:00") == s(1))
        #expect(tc.parseRelative("-0:15") == .zero - fd * 15)
        #expect(tc.parseRelative("10") == nil)            // no sign: absolute entry
        #expect(tc.parseRelative("+") == nil)
        #expect(tc.parseRelative("+abc") == nil)
    }

    @Test func fieldSeeksRelativeToTheCurrentTimeAndClampsAtZero() {
        let m = MonitorPanelModel(frameDuration: fd)
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        m.currentTime = s(2)
        #expect(m.commitTimecodeText("+10"))
        #expect(m.commitTimecodeText("-5"))
        m.currentTime = fd * 3
        #expect(m.commitTimecodeText("-100"))
        #expect(seeks == [s(2) + fd * 10, s(2) - fd * 5, .zero])
        #expect(!m.commitTimecodeText("+x"))
    }
}

@MainActor @Suite struct ProjectDeleteFindPosterTests {
    private func media(_ name: String, offline: Bool = false) -> MediaRef {
        MediaRef(name: name, path: offline ? "/nonexistent/\(name)" : "/tmp", fingerprint: MediaFingerprint(size: 1), duration: s(10))
    }

    private func make(_ p: Project) -> (ProjectPanelModel, Box) {
        let box = Box()
        let m = ProjectPanelModel(project: p, status: { $0.path.hasPrefix("/nonexistent") ? .missing : .ok },
                                  onEdit: { box.edits.append(($0, $1)) })
        return (m, box)
    }
    @MainActor final class Box { var edits: [(Project, String)] = [] }

    private func used(_ m: MediaRef, in name: String) -> Timeline {
        var v = Track(kind: .video)
        try? v.overwrite(Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero))
        return Timeline(name: name, format: SequenceFormat(frameDuration: fd), tracks: [v])
    }

    @Test func usedClipReportsTheBlockingSequences() {
        let a = media("a"), b = media("b")
        let (m, box) = make(Project(name: "P", media: [a, b], timelines: [used(a, in: "Main"), used(a, in: "Alt")]))
        let r = m.delete([.media(a.id), .media(b.id)])
        #expect(r.changed)                                       // b was unused and went
        #expect(r.blockedBy == ["Main", "Alt"])
        #expect(r.message == "Not deleted: still used in \u{201C}Main\u{201D}, \u{201C}Alt\u{201D}.")
        #expect(m.project.media.map(\.id) == [a.id])
        #expect(box.edits.count == 1)                            // one undo step
    }

    @Test func nothingDeletedIsNotAnEditButStillReports() {
        let a = media("a")
        let (m, box) = make(Project(name: "P", media: [a], timelines: [used(a, in: "Main")]))
        let r = m.delete([.media(a.id)])
        #expect(!r.changed && r.blockedBy == ["Main"] && box.edits.isEmpty)
    }

    @Test func sequencesDeleteExceptTheLastOne() {
        let t1 = Timeline(name: "A", frameDuration: fd), t2 = Timeline(name: "B", frameDuration: fd)
        let (m, box) = make(Project(name: "P", timelines: [t1, t2], activeTimeline: t1.id))
        let r = m.delete([.sequence(t1.id), .sequence(t2.id)])
        #expect(r.changed)
        #expect(m.project.timelines.map(\.name) == ["B"])
        #expect(m.project.activeTimeline == t2.id)
        #expect(r.message == "The last sequence cannot be deleted.")
        #expect(box.edits.count == 1 && box.edits[0].1 == "Delete")
    }

    @Test func findByNameLabelAndOffline() {
        var a = media("Interview A"), b = media("Broll", offline: true), c = media("Interview B", offline: true)
        a.label = .mango; b.label = .iris; c.label = .mango
        let (m, _) = make(Project(name: "P", media: [a, b, c]))
        #expect(m.find(.init()).isEmpty)
        #expect(m.find(.init(text: "interview")) == [.media(a.id), .media(c.id)])
        #expect(m.find(.init(offlineOnly: true)) == [.media(b.id), .media(c.id)])
        #expect(m.find(.init(text: "interview", offlineOnly: true)) == [.media(c.id)])
        #expect(m.find(.init(text: "mango", field: .label)) == [.media(a.id), .media(c.id)])
    }

    @Test func posterIsOneUndoStepAndClears() {
        let a = media("a"), b = media("b")
        let (m, box) = make(Project(name: "P", media: [a, b]))
        #expect(m.setPoster(s(3), for: [.media(a.id), .media(b.id)]))
        #expect(box.edits.count == 1 && box.edits[0].1 == "Set Poster Frame")
        #expect(m.project.media(a.id)?.posterTime == s(3) && m.project.media(b.id)?.posterTime == s(3))
        #expect(m.setPoster(nil, for: [.media(a.id)]))
        #expect(m.project.media(a.id)?.posterTime == nil && m.project.media(b.id)?.posterTime == s(3))
        #expect(!m.setPoster(s(1), for: [.bin(m.project.rootBin.id)]))
    }
}

@MainActor @Suite struct OverlayFeelRegressionTests {
    // The monitors stream built these; this pins them (FEEDBACK-5 #2-4).
    private func geo(_ t: ClipTransform = .identity) -> TransformOverlayGeometry {
        TransformOverlayGeometry(sequenceSize: CGSize(width: 1920, height: 1080), viewRect: CGRect(x: 10, y: 10, width: 960, height: 540),
                                 mediaAspect: 16.0 / 9, transform: t)
    }

    @Test func anchorIsGrabbableAtTheCentreAndRotateZoneSitsOutsideCorners() {
        let g = geo()
        #expect(g.hitTest(CGPoint(x: 490, y: 280)) == .anchor)
        #expect(g.hitTest(CGPoint(x: 0, y: 0)) == .rotate(.topLeft))
    }

    @Test func uniformScaleScalesBothAxesAndIsOptional() {
        let g = geo()
        let p = g.viewPoint(of: .right)
        let uni = g.scaled(handle: .right, from: p, to: CGPoint(x: p.x - 240, y: p.y))
        #expect(abs(uni.scale.x - uni.scale.y) < 1e-9)
        let free = g.scaled(handle: .right, from: p, to: CGPoint(x: p.x - 240, y: p.y),
                            modifiers: .init(uniformScale: false))
        #expect(free.scale.y == 1 && free.scale.x < 1)
    }

    @Test func rotateCursorExistsAndTurnsWithTheCorner() {
        let a = OverlayCursors.rotate(angle: 45), b = OverlayCursors.rotate(angle: 225)
        #expect(a !== b)
    }
}
