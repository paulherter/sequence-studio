import Foundation
import Testing
@testable import SQCore

// Stabilize as an effect (2026-10-06): Method (Standard | Gyroflow), the rows each method shows, applying it from the
// Effects panel, the analyzed state, and the v52 file gate.

private let fd30 = Time(1, 30)

private func videoClip(effects: [ClipEffect] = []) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero, effects: effects)
}

private func project(_ c: Clip) throws -> Project {
    var tr = Track(kind: .video)
    try tr.overwrite(c)
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                   tracks: [tr])])
}

private func analysis(frames n: Int = 60) -> StabilizationAnalysis {
    var motions = [CameraMotion.identity]
    for k in 1..<n { motions.append(CameraMotion(dx: k % 2 == 0 ? 4 : -4, dy: k % 3 == 0 ? 3 : -2)) }
    return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { fd30 * Int64($0) }, motions: motions)
}

@Suite struct StabilizeEffectTests {
    // MARK: Spec and options

    @Test func methodIsTheFirstRowAndDefaultsToStandard() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.stabilizeKind))
        let first = try #require(spec.params.first)
        #expect(first.key == ClipEffect.stabilizeMethodKey)
        #expect(first.kind == .choice(["Standard", "Gyroflow"]))
        #expect(first.defaultValue == 0)
        let e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        #expect(e.stabilizeMethod == .standard)
        #expect(StabilizerOptions(effect: e).method == .standard)
    }

    @Test func eachMethodShowsOnlyItsOwnRows() {
        #expect(StabilizerMethod.standard.visibleKeys == [ClipEffect.stabilizeMethodKey, ClipEffect.stabilizeModeKey,
                                                          ClipEffect.stabilizeStrengthKey, ClipEffect.stabilizeSmoothnessKey, ClipEffect.stabilizeMaxCropKey,
                                                          ClipEffect.stabilizeEdgeFillKey, ClipEffect.rollingShutterKey, ClipEffect.rollingShutterStrengthKey])
        #expect(StabilizerMethod.gyroflow.visibleKeys == [ClipEffect.stabilizeMethodKey, ClipEffect.gyroSmoothnessKey,
                                                          ClipEffect.gyroZoomLimitKey, ClipEffect.gyroFieldOfViewKey,
                                                          ClipEffect.gyroLensCorrectionKey, ClipEffect.gyroRollingShutterKey,
                                                          ClipEffect.gyroHorizonLockKey, ClipEffect.gyroSyncOffsetKey])
        // Every visible key is a spec row, and the spec has no row neither method shows.
        let specKeys = Set(EffectTransformStage.stabilizeSpec.params.map(\.key))
        let shown = Set(StabilizerMethod.allCases.flatMap(\.visibleKeys))
        #expect(specKeys == shown)
        // Gyroflow keys never collide with the stage keys the Standard analysis writes.
        let stage: Set<String> = [ClipEffect.stagePositionXKey, ClipEffect.stagePositionYKey, ClipEffect.stageRotationKey,
                                  ClipEffect.stageScaleKey, ClipEffect.stageScaleYKey, ClipEffect.stageAnchorXKey,
                                  ClipEffect.stageAnchorYKey, ClipEffect.stageOpacityKey]
        #expect(stage.isDisjoint(with: specKeys))
    }

    @Test func gyroflowOptionsReadAndClampTheStoredValues() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        let d = GyroflowOptions(effect: e)
        #expect(d == GyroflowOptions())
        #expect(d.smoothness == 50 && d.zoomLimit == 130 && d.rollingShutter && d.horizonLock == 0)
        #expect(d.fieldOfView == 100 && d.lensCorrection == 100 && d.syncOffsetMS == 0)
        #expect(!d.changesLensOrSync)
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1)
        e.parameters[ClipEffect.gyroSmoothnessKey] = AnimatedProperty(900)
        e.parameters[ClipEffect.gyroZoomLimitKey] = AnimatedProperty(20)
        e.parameters[ClipEffect.gyroRollingShutterKey] = AnimatedProperty(0)
        e.parameters[ClipEffect.gyroHorizonLockKey] = AnimatedProperty(-5)
        e.parameters[ClipEffect.gyroFieldOfViewKey] = AnimatedProperty(1)
        e.parameters[ClipEffect.gyroLensCorrectionKey] = AnimatedProperty(140)
        e.parameters[ClipEffect.gyroSyncOffsetKey] = AnimatedProperty(-99_999)
        let g = GyroflowOptions(effect: e)
        #expect(g.smoothness == 100 && g.zoomLimit == 100 && !g.rollingShutter && g.horizonLock == 0)
        #expect(g.fieldOfView == 10 && g.lensCorrection == 100 && g.syncOffsetMS == -5000)
        #expect(g.changesLensOrSync)
        e.parameters[ClipEffect.gyroSyncOffsetKey] = AnimatedProperty(.nan)
        #expect(GyroflowOptions(effect: e).syncOffsetMS == 0)
        #expect(e.stabilizeMethod == .gyroflow)
        #expect(StabilizerOptions(effect: e).method == .gyroflow)
        // An out-of-range stored method reads as Standard.
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(7)
        #expect(e.stabilizeMethod == .standard)
    }

    // MARK: Applying from the Effects panel

    @Test func addingStabilizeInsertsItBeforeTheFirstTransformStageOnce() throws {
        let blur = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        let transform = try #require(ClipEffect.make(kind: ClipEffect.transformKind))
        var c = videoClip(effects: [blur, transform])
        let added = c.addEffect(kind: ClipEffect.stabilizeKind)
        let id = try #require(added)
        #expect(c.effects.map(\.kind) == [ClipEffect.gaussianBlurKind, ClipEffect.stabilizeKind, ClipEffect.transformKind])
        #expect(c.effects[1].id == id)
        // One Stabilizer per clip: a second add changes nothing.
        let before = c
        let again = c.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(again == nil)
        #expect(c == before)
        #expect(c.stabilizerID == id)
    }

    @Test func stabilizeOnlyGoesOntoClipsWithMovingPictures() throws {
        var still = videoClip(); still.isStill = true
        let r_still = still.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(r_still == nil)
        var held = videoClip(); held.holdFrame = .zero
        let r_held = held.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(r_held == nil)
        var nested = videoClip(); nested.sequence = UUID()
        let r_nested = nested.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(r_nested == nil)
        var audio = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd30 * 30), start: .zero)
        let r_audio = audio.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(r_audio == nil)
        #expect(videoClip().canStabilize)
        #expect(!still.canStabilize)
    }

    @Test func aFreshStabilizerIsUnanalysedAndChangesNothing() throws {
        var c = videoClip()
        let added = c.addEffect(kind: ClipEffect.stabilizeKind)
        #expect(added != nil)
        let e = try #require(c.effect(ofKind: ClipEffect.stabilizeKind))
        #expect(!e.stabilizeIsAnalysed)
        #expect(e.stageTransform(atLocal: fd30 * 10, clipDuration: c.duration, frame: Vec2(1920, 1080)) == .identity)
    }

    @Test func anAnalysedStabilizerRecordsStandardAndItsRange() throws {
        let a = analysis()
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c = videoClip()
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        #expect(e.stabilizeIsAnalysed)
        #expect(e.parameters[ClipEffect.stabilizeMethodKey]?.value == 0)
        // A Stabilizer written before the range was recorded still counts as analyzed (it carries stage keys).
        var old = e
        old.parameters[ClipEffect.stabilizeFromKey] = nil; old.parameters[ClipEffect.stabilizeToKey] = nil
        #expect(old.stabilizeIsAnalysed)
    }

    @Test func gyroflowMethodIgnoresStandardStageKeys() throws {
        let a = analysis()
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c = videoClip()
        var e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        let t = fd30 * 7
        #expect(e.stageTransform(atLocal: t, clipDuration: c.duration, frame: Vec2(1920, 1080)) != .identity)
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1)
        // Gyroflow renders in its own pass (engine); the Standard keys must not move the picture as well.
        #expect(e.stageTransform(atLocal: t, clipDuration: c.duration, frame: Vec2(1920, 1080)) == .identity)
        #expect(!e.stabilizeIsAnalysed)
    }

    // MARK: File version v52

    @Test func aGyroflowStabilizerIsWrittenAsV52() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1)
        let p = try project(videoClip(effects: [e]))
        #expect(p.containsGyroflowStabilizers)
        #expect(ProjectFile.currentVersion >= 52)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.gyroflowStabilizeVersion)
        #expect(ProjectFile.gyroflowStabilizeVersion == 52)
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].effects == [e])
    }

    /// Field of View, Lens Correction and Sync Offset away from their defaults: v59 (a v58 build would ignore them and show
    /// a different picture). Defaults keep v52.
    @Test func gyroflowLensAndSyncOptionsAreWrittenAsV59() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1)
        #expect(ProjectFile.writtenVersion(for: try project(videoClip(effects: [e]))) == 52)
        for (key, value) in [(ClipEffect.gyroFieldOfViewKey, 120.0), (ClipEffect.gyroLensCorrectionKey, 50), (ClipEffect.gyroSyncOffsetKey, 12)] {
            var f = e
            f.parameters[key] = AnimatedProperty(value)
            let p = try project(videoClip(effects: [f]))
            #expect(p.containsV59Content)
            #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.v59Version)
            let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
            #expect(back.timelines[0].tracks[0].clips[0].effects == [f])
        }
        #expect(ProjectFile.v59Version == 59 && ProjectFile.currentVersion >= 59)
        // A Standard Stabilizer carrying the keys (switched back from Gyroflow) renders without them: no gate.
        var s = e
        s.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(0)
        s.parameters[ClipEffect.gyroSyncOffsetKey] = AnimatedProperty(12)
        #expect(!(try project(videoClip(effects: [s]))).containsV59Content)
    }

    @Test func aStandardStabilizerKeepsTheLowerVersion() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        let p = try project(videoClip(effects: [e]))
        #expect(!p.containsGyroflowStabilizers)
        #expect(ProjectFile.writtenVersion(for: p) < 52)
    }

    /// A v51 file's Stabilizer (written before Method existed) opens as a Standard Stabilizer with its settings and keys.
    @Test func v51StabilizerOpensAsStandard() throws {
        let a = analysis()
        var o = StabilizerOptions(); o.mode = .locked; o.smoothness = 1.5
        let plan = try #require(Stabilizer.plan(a, options: o))
        let c0 = videoClip()
        var e = Stabilizer.effect(plan: plan, analysis: a, clip: c0, frameDuration: fd30, options: o)
        e.parameters[ClipEffect.stabilizeMethodKey] = nil          // as a v51 build wrote it
        let p = try project(videoClip(effects: [e]))
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 51
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        let got = try #require(back.timelines[0].tracks[0].clips[0].effect(ofKind: ClipEffect.stabilizeKind))
        #expect(got == e)
        #expect(got.stabilizeMethod == .standard)
        let opts = StabilizerOptions(effect: got)
        #expect(opts.method == .standard && opts.mode == .locked && opts.smoothness == 1.5)
        #expect(got.stabilizeIsAnalysed)
    }

    @Test func v51StepIsIdentity() throws {
        let step = try #require(ProjectFile.migrations[51])
        #expect(try step(["a": 1])["a"] as? Int == 1)
        #expect(ProjectFile.realMigrations[51] != nil)
    }
}
