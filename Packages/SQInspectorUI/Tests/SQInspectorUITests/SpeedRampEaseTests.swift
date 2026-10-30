import CoreGraphics
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQInspectorUI

private let fd = Time(1, 24)
private func f(_ n: Int64) -> Time { fd * n }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private let easeInOut = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.5, dy: 0), in: EaseHandle(dx: 0.5, dy: 0))
private let slowStart = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.6, dy: 0), in: .linear)

@MainActor
private func session(with c: Clip) throws -> EditorSession {
    var p = EditorSession.makeUntitled()
    var t = Track(kind: .video)
    try t.overwrite(c)
    p.timelines[0].tracks = [t]
    p.timelines[0].format = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rampease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
}

/// 24 f at 100 %, a 24 f ramp to 300 %, then 300 %.
private func rampKeys(_ c: Clip) -> SpeedKeys {
    let k = SpeedKeys.of(c)
    let (a, b) = k.addingKey(at: f(24), frameDuration: fd)!
    let fast = a.settingSpeed(ofSegment: b, to: pct(300), frameDuration: fd)
    return fast.splittingKey(atBoundary: 1, takeLeft: .zero, takeRight: f(24), frameDuration: fd)!
}

@MainActor
@Suite struct SpeedRampEaseTests {
    private func ramped() throws -> (EditorSession, Clip.ID) {
        let c = Clip(name: "clip", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(240)), start: .zero,
                     mediaDuration: f(4000))
        let s = try session(with: c)
        s.select(clips: [c.id])
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: SpeedKeys.of(c), phase: .began))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: rampKeys(c), phase: .changed))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: rampKeys(c), phase: .ended))
        return (s, c.id)
    }
    private func clip(_ s: EditorSession) -> Clip { s.activeTimeline!.tracks[0].clips[0] }

    /// A speed transition stores neither Hold (it clears the curve) nor overshoot: no Hold chip, the handles stop at 0...1.
    @Test func popoverOffersNoHoldAndNoOvershootForASpeedTransition() throws {
        let (s, id) = try ramped()
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        src.applyEaseShape(.hold)
        #expect(src.easeReading == .common(.linear))                        // Hold is not stored
        #expect(!src.allowsHold && src.handleValueRange == 0...1)
        let c = EasingCurvePopoverController(source: src, library: EasingPresetLibrary(store: nil))
        c.loadView(); c.refresh()
        #expect(!c.chipItemsForTests.contains { $0.name == "Hold" })
        #expect(c.editor.valueRange == 0...1)
    }

    @Test func readingShowsTheRampCurveAndNothingForSegments() throws {
        let (s, id) = try ramped()
        #expect(clip(s).speedKeys!.segments[1].isRamp)
        #expect(SpeedRampEaseSource(session: s, clip: id, segment: 1).easeReading == .common(.linear))
        #expect(SpeedRampEaseSource(session: s, clip: id, segment: 0).easeReading == .empty)
        #expect(s.speedRampEase(clip: id, segment: 7) == nil)
    }

    @Test func aCurveDragIsOneUndoStepAndKeepsTheClipLength() throws {
        let (s, id) = try ramped()
        let before = clip(s)
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        src.beginGesture()
        src.applyEaseShape(slowStart)
        src.applyEaseShape(easeInOut)
        src.applyEaseShape(slowStart)
        src.endGesture()
        let after = clip(s)
        #expect(after.duration == before.duration)
        #expect(after.speedKeys!.ease(ofSegment: 1).isApproximatelyEqual(to: slowStart, tolerance: 1e-4))
        #expect(after.source == after.speedKeys!.hull)
        guard case .common(let shown) = src.easeReading else { Issue.record("no reading"); return }
        #expect(shown.isApproximatelyEqual(to: slowStart, tolerance: 1e-4))
        #expect(s.undoName == "Speed Transition Curve")
        #expect(s.undo())
        #expect(clip(s) == before)                                          // one step back to the linear ramp
    }

    @Test func chipClicksAreSeparateStepsAndLinearRestoresTheRamp() throws {
        let (s, id) = try ramped()
        let before = clip(s)
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        src.applyEaseShape(easeInOut)
        let eased = clip(s)
        src.applyEaseShape(.linear)
        #expect(clip(s) == before)                                          // linear equals the untouched ramp
        #expect(s.undo())
        #expect(clip(s) == eased)
        #expect(s.undo())
        #expect(clip(s) == before)
    }

    @Test func anUnchangedCurveRecordsNoUndoStep() throws {
        let (s, id) = try ramped()
        let name = s.undoName
        #expect(!s.setSpeedRampEase(.linear, clip: id, segment: 1))         // already linear
        #expect(s.undoName == name)
        #expect(s.setSpeedRampEase(easeInOut, clip: id, segment: 1))
        #expect(!s.setSpeedRampEase(easeInOut, clip: id, segment: 1))
        #expect(s.undo())
        #expect(s.undoName == name)                                         // only one step was recorded
        // A drag whose first move changes nothing does not coalesce into the previous step.
        s.setSpeedRampEase(easeInOut, clip: id, segment: 1)
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        src.beginGesture()
        src.applyEaseShape(easeInOut)                                       // no change
        src.applyEaseShape(slowStart)
        src.endGesture()
        #expect(s.undo())
        #expect(clip(s).speedKeys!.ease(ofSegment: 1).isApproximatelyEqual(to: easeInOut, tolerance: 1e-4))
    }

    @Test func aSourceWhoseRampWasReplacedWritesNothing() throws {
        let (s, id) = try ramped()
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        #expect(src.isCurrent)
        // A band drag widens the ramp: segment 1 is now a different transition.
        let wider = clip(s).speedKeys!.settingRampWidth(ofSegment: 1, to: f(36), frameDuration: fd)!
        s.applySpeedEdit(SpeedEdit(clip: id, keys: clip(s).speedKeys!, phase: .began))
        s.applySpeedEdit(SpeedEdit(clip: id, keys: wider, phase: .changed))
        let before = clip(s)
        #expect(!src.isCurrent && src.easeReading == .empty)
        src.applyEaseShape(easeInOut)
        #expect(clip(s) == before)
    }

    @Test func aKeyAddedBeforeTheRampDoesNotRedirectTheSource() throws {
        let (s, id) = try ramped()
        let src = SpeedRampEaseSource(session: s, clip: id, segment: 1)
        // A key inside the first (constant) segment shifts the ramp's index from 1 to 2.
        #expect(s.addSpeedKey(clip: id, atLocal: f(12)))
        #expect(src.currentSegment == 2)
        src.applyEaseShape(easeInOut)
        #expect(clip(s).speedKeys!.ease(ofSegment: 2).isApproximatelyEqual(to: easeInOut, tolerance: 1e-4))
        #expect(clip(s).speedKeys!.ease(ofSegment: 1) == .linear)
    }

    @Test func theRubberBandFollowsTheCurve() throws {
        let (s, id) = try ramped()
        let lane = CGRect(x: 0, y: 0, width: 960, height: 60)
        let x: (Time) -> CGFloat = { CGFloat(Double($0.value) / Double($0.timescale)) * 100 }
        let lin = SpeedBand.linePoints(keys: clip(s).speedKeys!, clipStart: .zero, lane: lane, x: x)
        SpeedRampEaseSource(session: s, clip: id, segment: 1).applyEaseShape(easeInOut)
        let eased = SpeedBand.linePoints(keys: clip(s).speedKeys!, clipStart: .zero, lane: lane, x: x)
        #expect(lin.count == eased.count)
        // A quarter into the ramp (x = 1.25 s) the eased line is lower on screen (slower = larger y).
        let i = try #require(lin.firstIndex { $0.x >= 125 })
        #expect(eased[i].y > lin[i].y + 1)
    }
}
