import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)

/// Hand-held shake over whatever range is asked for; records the ranges and options it saw.
private final class FakeAnalyzer: StabilizationAnalyzing, @unchecked Sendable {
    struct Broken: Error {}
    let fail: Bool
    /// Runs on the main actor while the analysis is in flight (edits made during a run).
    var during: (@MainActor @Sendable () -> Void)?
    private let lock = NSLock()
    private var _ranges: [TimeRange] = []
    var ranges: [TimeRange] { lock.withLock { _ranges } }
    private var _rolling: [Bool] = []
    /// Whether each run was asked for the per-row motion (Rolling Shutter on).
    var rolling: [Bool] { lock.withLock { _rolling } }
    init(fail: Bool = false) { self.fail = fail }

    func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int, rolling: Bool,
                 progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        lock.withLock { _rolling.append(rolling) }
        return try await analyze(sourceRange: sourceRange, pictureWidth: pictureWidth, pictureHeight: pictureHeight, progress: progress)
    }

    func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int,
                 progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        lock.withLock { _ranges.append(sourceRange) }
        if fail { throw Broken() }
        if let during { await during() }
        let n = Int(sourceRange.duration.frameIndex(frameDuration: fd))
        var s: UInt64 = 3
        func r() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        }
        var motions = [CameraMotion.identity]
        for _ in 1..<n { motions.append(CameraMotion(dx: 6 * r(), dy: 6 * r(), rotation: 0.2 * r())) }
        progress?(1)
        return StabilizationAnalysis(pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                                     frameTimes: (0..<n).map { sourceRange.start + fd * Int64($0) }, motions: motions)
    }
}

@MainActor private struct Fixture {
    let session: EditorSession
    let clip: Clip
    let media: MediaRef

    init(effects: [ClipEffect] = []) {
        let info = MediaInfo(duration: Time(10, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
                                                                         chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false))
        let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1), info: info)
        var c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: Time(1, 1), duration: Time(2, 1)), start: Time(5, 1))
        c.effects = effects
        var track = Track(kind: .video)
        try! track.overwrite(c)
        let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [track])
        session = EditorSession(project: Project(name: "P", media: [m], timelines: [t]), engine: StubProgramEngine())
        clip = c; media = m
        session.select(clips: [c.id])
    }

    func live() -> Clip { session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == clip.id }! }
}

@MainActor @Suite struct StabilizeSessionTests {
    /// Rolling Shutter switched on while another Stabilize analysis runs: the clip waits in the queue and is handed out
    /// when that run ends; a clip deleted meanwhile, or one that lost its Stabilizer, drops out.
    @Test func anAnalysisAskedForDuringARunWaitsInTheQueue() async throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(1)
        let f = Fixture(effects: [e])
        #expect(f.session.takeQueuedStabilizerAnalysis().isEmpty)
        let gone = UUID()
        f.session.queueStabilizerAnalysis([f.clip.id, gone])
        f.session.queueStabilizerAnalysis([f.clip.id])
        #expect(f.session.takeQueuedStabilizerAnalysis() == [f.clip.id])
        #expect(f.session.takeQueuedStabilizerAnalysis().isEmpty)             // handed out once
        // The run that follows asks the analyzer for the per-row motion; a Stabilizer without the option does not.
        let a = FakeAnalyzer()
        _ = try await f.session.stabilize(only: [f.clip.id]) { _ in a }
        #expect(a.rolling == [true])
        let plain = Fixture()
        let b = FakeAnalyzer()
        _ = try await plain.session.stabilize { _ in b }
        #expect(b.rolling == [false])
        // Canceling the run forgets what waited.
        f.session.queueStabilizerAnalysis([f.clip.id])
        f.session.dropQueuedStabilizerAnalysis()
        #expect(f.session.takeQueuedStabilizerAnalysis().isEmpty)
        // The Stabilizer removed while waiting: nothing to analyze.
        f.session.queueStabilizerAnalysis([f.clip.id])
        var c = f.live()
        c.effects.removeAll { $0.kind == ClipEffect.stabilizeKind }
        f.session.replaceDisplayedClip(c, name: "Remove Effect", continuesGesture: false)
        #expect(f.session.takeQueuedStabilizerAnalysis().isEmpty)
    }

    @Test func writesAStabilizerStageWithKeysOnEveryFrameInOneUndoStep() async throws {
        let f = Fixture()
        let a = FakeAnalyzer()
        let out = try await f.session.stabilize { _ in a }
        #expect(out.stabilized == 1 && out.failed == 0 && out.uncovered == 0)
        #expect(out.maxCrop > 0 && out.maxCrop < 0.1)
        #expect(a.ranges == [TimeRange(start: Time(1, 1), duration: Time(2, 1))])
        let c = f.live()
        #expect(c.animation == f.clip.animation)
        let e = try #require(c.effect(ofKind: ClipEffect.stabilizeKind))
        let keys = try #require(e.parameters[ClipEffect.stagePositionXKey]?.track.keys)
        #expect(keys.count > 2 && keys.count <= 60 && keys.first?.time == .zero && keys.last?.time == fd * 59)
        #expect(c.renderTransform(at: c.start + fd * 10, frame: Vec2(1920, 1080)) != c.transform(at: c.start + fd * 10))
        #expect(f.session.undoName == "Stabilize")
        #expect(f.session.undo())
        #expect(f.live() == f.clip)
    }

    @Test func goesBeforeOtherTransformStagesAndKeepsItsIdOnARerun() async throws {
        var transform = ClipEffect.make(kind: ClipEffect.transformKind)!
        transform.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(150)
        let blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        let f = Fixture(effects: [blur, transform])
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        let first = f.live()
        #expect(first.effects.map(\.kind) == [ClipEffect.gaussianBlurKind, ClipEffect.stabilizeKind, ClipEffect.transformKind])
        let id = try #require(first.effect(ofKind: ClipEffect.stabilizeKind)).id

        // Switch the stored Result to No Motion, run again: same effect, re-planned locked.
        var o = StabilizerOptions(); o.mode = .locked
        _ = try await f.session.stabilize(options: o) { _ in FakeAnalyzer() }
        let second = f.live()
        #expect(second.effects.count == 3)
        let e = try #require(second.effect(ofKind: ClipEffect.stabilizeKind))
        #expect(e.id == id)
        #expect(e.parameters[ClipEffect.stabilizeModeKey]?.value == Double(StabilizerMode.locked.rawValue))
        // nil options read the stored settings back.
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        #expect(f.live().effect(ofKind: ClipEffect.stabilizeKind)?.parameters[ClipEffect.stabilizeModeKey]?.value == 1)
    }

    @Test func aFailingAnalysisWritesNothing() async throws {
        let f = Fixture()
        let out = try await f.session.stabilize { _ in FakeAnalyzer(fail: true) }
        #expect(out == StabilizeOutcome(stabilized: 0, failed: 1))
        #expect(!f.session.canUndo)
        let none = try await f.session.stabilize { _ in nil }
        #expect(none.failed == 1)
    }

    @Test func cancellingWritesNothing() async throws {
        let f = Fixture()
        let task = Task { @MainActor in
            try await f.session.stabilize { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return FakeAnalyzer()
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!f.session.canUndo)
    }

    @Test func sourceRangeFollowsReverse() {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(1, 1), duration: Time(2, 1)), start: .zero)
        c.reversed = true
        let r = EditorSession.stabilizeSourceRange(of: c, frameDuration: fd)
        #expect(r?.start == Time(1, 1))
        #expect(r?.end == Time(3, 1))
    }

    @Test func aRerunKeepsADisabledStabilizerDisabled() async throws {
        var off = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        off.enabled = false
        let f = Fixture(effects: [off])
        let out = try await f.session.stabilize { _ in FakeAnalyzer() }
        #expect(out.stabilized == 1)
        let e = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(e.id == off.id && !e.enabled)
        #expect(e.parameters[ClipEffect.stagePositionXKey]?.track.isEmpty == false)
    }

    @Test func aStabilizerChangedDuringTheRunIsLeftAlone() async throws {
        let f = Fixture(effects: [try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))])
        var changed = try #require(f.clip.effect(ofKind: ClipEffect.stabilizeKind))
        changed.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(0.9)
        let a = FakeAnalyzer()
        let session = f.session, id = f.clip.id
        a.during = { session.applyStabilizer([id: changed]) }
        let out = try await f.session.stabilize { _ in a }
        #expect(out.stabilized == 0 && out.failed == 1)
        #expect(f.live().effect(ofKind: ClipEffect.stabilizeKind) == changed)
    }

    @Test func planningRunsOffTheMainActor() async throws {
        let f = Fixture()
        let clip = f.clip
        let analysis = try await FakeAnalyzer().analyze(sourceRange: TimeRange(start: Time(1, 1), duration: Time(2, 1)),
                                                        pictureWidth: 1920, pictureHeight: 1080, progress: nil)
        let built = await Task.detached {
            EditorSession.buildStabilizer(analysis: analysis, options: StabilizerOptions(), clip: clip, frameDuration: fd, id: UUID())
        }.value
        let (e, plan) = try #require(built)
        #expect(e.kind == ClipEffect.stabilizeKind && plan.crop > 0)
    }

    // MARK: Live re-plan and stale analysis

    private func editSettings(_ f: Fixture, _ body: (inout ClipEffect) -> Void) {
        var c = f.live()
        let i = c.effects.firstIndex { $0.kind == ClipEffect.stabilizeKind }!
        body(&c.effects[i])
        f.session.replaceClip(c, name: "Stabilizer", continuesGesture: false)
    }

    @Test func changingTheSettingsReplansFromTheCachedAnalysisInTheSameUndoStep() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        let stabilized = f.live()
        let before = try #require(stabilized.effect(ofKind: ClipEffect.stabilizeKind))
        editSettings(f) { $0.parameters[ClipEffect.stabilizeModeKey] = AnimatedProperty(Double(StabilizerMode.locked.rawValue)) }
        let a = FakeAnalyzer()
        let lookup: EditorSession.StabilizationLookup = { _, range, w, h in
            try? await a.analyze(sourceRange: range, pictureWidth: w, pictureHeight: h, progress: nil)
        }
        let ok = await f.session.replanStabilizer(clip: f.clip.id, lookup: lookup)
        #expect(ok)
        let e = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(e.id == before.id && e.parameters[ClipEffect.stabilizeModeKey]?.value == 1)
        #expect(e.parameters[ClipEffect.stagePositionXKey] != before.parameters[ClipEffect.stagePositionXKey])
        // The settings edit and the re-plan are one step.
        #expect(f.session.undo())
        #expect(f.live() == stabilized)
    }

    @Test func aMissingAnalysisLeavesTheStabilizerAlone() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        editSettings(f) { $0.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(2) }
        let edited = f.live()
        let ok = await f.session.replanStabilizer(clip: f.clip.id) { _, _, _, _ in nil }
        #expect(!ok && f.live() == edited)
    }

    @Test func aClipTrimmedLongerThanTheAnalysisIsStaleUntilItIsRunAgain() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        #expect(f.session.staleStabilizerClips().isEmpty)
        let id = f.clip.id
        try f.session.performTimeline("Trim") { _ = try $0.trim(id, edge: .tail, by: Time(2, 1)) }
        #expect(f.session.staleStabilizerClips() == [f.clip.id])
        // Not selected, still re-run by id.
        f.session.select(clips: [])
        let a = FakeAnalyzer()
        let out = try await f.session.stabilize(only: [f.clip.id]) { _ in a }
        #expect(out.stabilized == 1)
        #expect(a.ranges == [TimeRange(start: Time(1, 1), duration: Time(4, 1))])
        #expect(f.session.staleStabilizerClips().isEmpty)
    }

    @Test func theQueueIsPerSequenceAndRunsWhicheverSequenceIsOpen() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(1)
        let f = Fixture(effects: [e])
        let first = try #require(f.session.activeTimelineID)
        f.session.queueStabilizerAnalysis([f.clip.id])
        f.session.queueStabilizerAnalysis([UUID()], in: UUID())       // a sequence that is gone drops out
        #expect(f.session.takeNextQueuedStabilizerAnalysis()?.timeline == first)
        #expect(f.session.takeNextQueuedStabilizerAnalysis() == nil)
        f.session.queueStabilizerAnalysis([f.clip.id], in: first)
        #expect(f.session.takeQueuedStabilizerAnalysis(in: first) == [f.clip.id])
    }

    @Test func cancelingTheRollingShutterAnalysisSwitchesTheOptionBackOffInOneStep() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        let tid = try #require(f.session.activeTimelineID)
        let lookup: EditorSession.StabilizationLookup = { _, r, w, h in
            try? await FakeAnalyzer().analyze(sourceRange: r, pictureWidth: w, pictureHeight: h, progress: nil)
        }
        editSettings(f) { $0.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(1) }
        var asked = 0
        f.session.onStabilizerNeedsAnalysis = { _, _ in asked += 1 }
        #expect(await f.session.replanStabilizer(clip: f.clip.id, lookup: lookup) == false)
        #expect(asked == 1 && f.session.rollingShutterRequests[tid] == [f.clip.id])
        f.session.withdrawRollingShutterRequests()
        let off = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(!StabilizerOptions(effect: off).rollingShutter && f.session.undoName == "Rolling Shutter")
        // The next Smoothness edit re-plans from the cache and asks for nothing.
        editSettings(f) { $0.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(80) }
        #expect(await f.session.replanStabilizer(clip: f.clip.id, lookup: lookup))
        #expect(asked == 1)
    }

    @Test func severalClipsReplanInOneUndoStep() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        let lookup: EditorSession.StabilizationLookup = { _, r, w, h in
            try? await FakeAnalyzer().analyze(sourceRange: r, pictureWidth: w, pictureHeight: h, progress: nil)
        }
        let before = f.live()
        editSettings(f) { $0.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(90) }
        let written = await f.session.replanStabilizers(clips: [f.clip.id], lookup: lookup)
        let replanned = f.live()
        #expect(written == [f.clip.id] && replanned != before && f.session.undoName == "Stabilize")
        _ = f.session.undo()
        #expect(f.live() != replanned && f.session.undoName == "Stabilizer")
    }

    @Test func aReplanKeepsTheKeysOfAKeyframedRollingShutterStrength() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        var keyed = AnimatedProperty(100)
        keyed.track = KeyframeTrack(keys: [Keyframe(time: Time(0, 1), value: 50), Keyframe(time: Time(1, 1), value: 150)])
        editSettings(f) { $0.parameters[ClipEffect.rollingShutterStrengthKey] = keyed; $0.parameters[ClipEffect.stabilizeSmoothnessKey] = AnimatedProperty(70) }
        _ = await f.session.replanStabilizer(clip: f.clip.id) { _, r, w, h in
            try? await FakeAnalyzer().analyze(sourceRange: r, pictureWidth: w, pictureHeight: h, progress: nil)
        }
        #expect(f.live().effect(ofKind: ClipEffect.stabilizeKind)?.parameters[ClipEffect.rollingShutterStrengthKey]?.track.keys.count == 2)
    }

    @Test func aClipThatFailedItsAnalysisGetsRollingShutterSwitchedOff() async throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(1)
        let f = Fixture(effects: [e])
        let tid = try #require(f.session.activeTimelineID)
        f.session.rollingShutterRequests[tid] = [f.clip.id]
        let out = try await f.session.stabilize(only: [f.clip.id]) { _ in FakeAnalyzer(fail: true) }
        #expect(out.failed == 1 && out.stabilized == 0)
        let now = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(!StabilizerOptions(effect: now).rollingShutter && f.session.rollingShutterRequests[tid]?.isEmpty != false)
        // A written clip keeps it on.
        let g = Fixture(effects: [e])
        let gt = try #require(g.session.activeTimelineID)
        g.session.rollingShutterRequests[gt] = [g.clip.id]
        let ok = try await g.session.stabilize(only: [g.clip.id]) { _ in FakeAnalyzer() }
        let kept = StabilizerOptions(effect: try #require(g.live().effect(ofKind: ClipEffect.stabilizeKind))).rollingShutter
        #expect(ok.stabilized == 1 && kept)
        #expect(g.session.rollingShutterRequests[gt]?.isEmpty != false)
    }

    @Test func aQueuedClipThatDropsOutLosesItsRollingShutterRequest() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(1)
        e.enabled = false
        let f = Fixture(effects: [e])
        let tid = try #require(f.session.activeTimelineID)
        f.session.rollingShutterRequests[tid] = [f.clip.id]
        f.session.queueStabilizerAnalysis([f.clip.id])
        #expect(f.session.takeQueuedStabilizerAnalysis().isEmpty)
        #expect(f.session.rollingShutterRequests[tid]?.isEmpty != false)
        f.session.withdrawRollingShutterRequests()
        let still = StabilizerOptions(effect: try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))).rollingShutter
        #expect(still)
    }

    @Test func aRunForASequenceThatIsGoneDoesNothing() async throws {
        let f = Fixture()
        let a = FakeAnalyzer()
        let out = try await f.session.stabilize(only: [f.clip.id], in: UUID()) { _ in a }
        #expect(out.stabilized == 0 && a.ranges.isEmpty)
    }

    // MARK: Stabilize as an effect (Effects panel, Method)

    @Test func droppingStabilizeAddsAFreshStabilizerAndWaitsForStart() async throws {
        let f = Fixture()
        var asked: [Set<Clip.ID>] = []
        f.session.onStabilizerNeedsAnalysis = { _, ids in asked.append(ids) }
        #expect(f.session.addEffect(kind: ClipEffect.stabilizeKind, to: [f.clip.id]))
        let e = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(!e.stabilizeIsAnalysed && e.stabilizeMethod == .standard)
        #expect(f.session.undoName == "Add Stabilizer")
        #expect(asked.isEmpty, "adding the effect never starts an analysis")
        // Dropped again: no second Stabilizer, no undo step, still no analysis.
        let before = f.live()
        #expect(f.session.addEffect(kind: ClipEffect.stabilizeKind, to: [f.clip.id]))
        #expect(f.live() == before)
        #expect(asked.isEmpty)
        // The analysis (Start) fills the same effect.
        _ = try await f.session.stabilize(only: [f.clip.id]) { _ in FakeAnalyzer() }
        let done = try #require(f.live().effect(ofKind: ClipEffect.stabilizeKind))
        #expect(done.id == e.id && done.stabilizeIsAnalysed)
        // Dropped on an analyzed clip: nothing to do.
        #expect(f.session.addEffect(kind: ClipEffect.stabilizeKind, to: [f.clip.id]))
        #expect(asked.isEmpty)
    }

    @Test func editingTransformOrOtherEffectsAfterStabilizingNeverAsksForAnAnalysis() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        var asked = 0
        f.session.onStabilizerNeedsAnalysis = { _, _ in asked += 1 }
        var c = f.live()
        c.animation.scale = AnimatedProperty(Vec2(1.4, 1.4))
        f.session.replaceClip(c, name: "Scale", continuesGesture: false)
        c = f.live()
        c.animation.opacity = AnimatedProperty(0.5)
        f.session.replaceClip(c, name: "Opacity", continuesGesture: false)
        #expect(f.session.staleStabilizerClips().isEmpty && asked == 0)
        #expect(f.live().effect(ofKind: ClipEffect.stabilizeKind)?.stabilizeIsAnalysed == true)
    }

    @Test func aRunEndsWhenItsEffectIsRemovedOrItsClipDeleted() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        let ids: Set<Clip.ID> = [f.clip.id]
        #expect(!f.session.stabilizeRunIsObsolete(clips: ids, watching: ids))
        #expect(!f.session.stabilizeRunIsObsolete(clips: ids, watching: []), "a run that started without an effect is not canceled")
        var c = f.live()
        c.effects.removeAll { $0.kind == ClipEffect.stabilizeKind }
        f.session.replaceClip(c, name: "Remove Stabilizer", continuesGesture: false)
        #expect(f.session.stabilizeRunIsObsolete(clips: ids, watching: ids))
    }

    @Test func aGyroflowStabilizerIsNotAnalysedOrReplannedAsStandard() async throws {
        let f = Fixture()
        _ = try await f.session.stabilize { _ in FakeAnalyzer() }
        editSettings(f) { $0.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1) }
        let gyro = f.live()
        let a = FakeAnalyzer()
        let out = try await f.session.stabilize(only: [f.clip.id]) { _ in a }
        #expect(out.stabilized == 0 && out.gyroflow == 1 && a.ranges.isEmpty)
        #expect(f.live() == gyro)
        let replanned = await f.session.replanStabilizer(clip: f.clip.id) { _, r, w, h in
            try? await a.analyze(sourceRange: r, pictureWidth: w, pictureHeight: h, progress: nil)
        }
        #expect(!replanned && f.live() == gyro)
        #expect(f.session.staleStabilizerClips().isEmpty)
    }
}
