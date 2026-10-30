import Foundation
import Testing
@testable import SQCore

// W9.7 Stabilizer: camera path from inter-frame motions, smoothing (smooth / locked), auto scale, per-frame stage keys.

private struct LCG {
    var s: UInt64
    mutating func next() -> Double {          // -1...1
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private let fd30 = Time(1, 30)

/// A hand-held clip: per-frame camera poses = optional slow pan + jitter (px, degrees), as inter-frame motions.
private func analysis(frames n: Int = 300, pan: Double = 0, jitter: Double = 6, rotJitter: Double = 0.3,
                      scaleJitter: Double = 0, width: Int = 1920, height: Int = 1080, seed: UInt64 = 7) -> StabilizationAnalysis {
    var r = LCG(s: seed)
    var poses: [CameraPose] = []
    for k in 0..<n {
        poses.append(CameraPose(translation: Vec2(pan * Double(k) + jitter * r.next(), jitter * r.next()),
                                rotation: rotJitter * r.next(), logScale: scaleJitter * r.next()))
    }
    var motions = [CameraMotion.identity]
    for k in 1..<n { motions.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
    return StabilizationAnalysis(pictureWidth: width, pictureHeight: height,
                                 frameTimes: (0..<n).map { fd30 * Int64($0) }, motions: motions)
}

/// Where a world point sits in each frame after the stage (what the viewer sees, before Motion).
private func rendered(_ a: StabilizationAnalysis, _ plan: StabilizationPlan, world w: Vec2 = Vec2(100, -50)) -> [Vec2] {
    let path = Stabilizer.path(a.motions)
    return path.indices.map { k in Affine2(plan.corrections[k]).apply(path[k].apply(w)) }
}

private func raw(_ a: StabilizationAnalysis, world w: Vec2 = Vec2(100, -50)) -> [Vec2] {
    Stabilizer.path(a.motions).map { $0.apply(w) }
}

@Suite struct StabilizerTests {
    @Test func motionsComposeIntoThePath() {
        let p0 = CameraPose(translation: Vec2(3, -2), rotation: 1.5, logScale: 0.01)
        let p1 = CameraPose(translation: Vec2(-4, 7), rotation: -0.5, logScale: -0.02)
        let m = CameraMotion(from: p0, to: p1)
        let path = Stabilizer.path([CameraMotion(from: .identity, to: p0), m])
        let w = Vec2(250, -120)
        #expect((path[1].apply(w) - p1.apply(w)).length < 1e-9)
        #expect((path[0].apply(w) - p0.apply(w)).length < 1e-9)
    }

    @Test func gaussianKeepsStraightLinesAndEnds() {
        let line = (0..<50).map { 3 + 2 * Double($0) }
        let s = Stabilizer.gaussianSmooth(line, sigma: 6)
        for (a, b) in zip(line, s) { #expect(abs(a - b) < 1e-9) }
    }

    @Test func smoothModeRemovesJitterWithLessThanTenPercentCrop() throws {
        let a = analysis(pan: 2)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let before = Stabilizer.jitter(raw(a)), after = Stabilizer.jitter(rendered(a, plan))
        #expect(after < before * 0.2, "jitter \(before) -> \(after)")
        #expect(plan.crop < 0.10, "crop \(plan.crop)")
        #expect(plan.crop > 0)
        #expect(plan.fullyCovered)
        // The pan survives: the rendered picture still moves ~2 px per frame on average.
        let r = rendered(a, plan)
        let drift = (r.last! - r.first!).x / Double(r.count - 1)
        #expect(abs(drift - 2 * plan.zoom) < 0.3, "drift \(drift)")
    }

    @Test func smoothModeKeepsCropUnderTheLimitForStrongShake() throws {
        let a = analysis(pan: 0, jitter: 60, rotJitter: 2)
        var o = StabilizerOptions()
        o.maxCrop = 0.08
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(plan.crop <= 0.08 + 1e-6, "crop \(plan.crop)")
        #expect(plan.fullyCovered)
        #expect(Stabilizer.jitter(rendered(a, plan)) < Stabilizer.jitter(raw(a)) * 0.6)
    }

    @Test func everyFrameStaysCovered() throws {
        let a = analysis(pan: 1, jitter: 15, rotJitter: 1, scaleJitter: 0.01)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let hw = Double(a.pictureWidth) / 2, hh = Double(a.pictureHeight) / 2
        for c in plan.corrections {
            let m = Affine2(c)
            let det = m.a * m.d - m.b * m.c
            for q in [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)] {
                let d = q - m.t
                let src = Vec2((m.d * d.x - m.b * d.y) / det, (-m.c * d.x + m.a * d.y) / det)
                #expect(abs(src.x) <= hw + 1e-6 && abs(src.y) <= hh + 1e-6)
            }
        }
    }

    @Test func lockedModeHoldsTheShotStill() throws {
        let a = analysis(pan: 0, jitter: 8, rotJitter: 0.4)
        var o = StabilizerOptions()
        o.mode = .locked
        let plan = try #require(Stabilizer.plan(a, options: o))
        let r = rendered(a, plan)
        let maxDev = r.map { ($0 - r[0]).length }.max()!
        #expect(maxDev < 1e-6, "locked moved \(maxDev) px")
        #expect(plan.fullyCovered)
        #expect(plan.crop < 0.10)
    }

    @Test func lockedModeCapsTheZoomOnAPan() throws {
        let a = analysis(pan: 10, jitter: 2)      // 3000 px of pan: cannot be held
        var o = StabilizerOptions()
        o.mode = .locked
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(plan.fullyCovered)   // the lock gives way locally instead of leaving the frame edge short
        #expect(plan.crop <= o.maxLockedCrop + 1e-9)
    }

    @Test func stillShotNeedsNoCorrection() throws {
        let a = analysis(jitter: 0, rotJitter: 0)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.zoom == 1)
        #expect(plan.corrections.allSatisfy { $0.isIdentity || ($0.position.length < 1e-9 && abs($0.scale - 1) < 1e-9) })
    }

    @Test func tooFewFramesHasNoPlan() {
        #expect(Stabilizer.plan(analysis(frames: 1), options: StabilizerOptions()) == nil)
    }

    @Test func nearestFrameIndex() {
        let a = analysis(frames: 10)
        #expect(a.index(nearest: Time(-1, 1)) == 0)
        #expect(a.index(nearest: fd30 * 3) == 3)
        #expect(a.index(nearest: Time(7, 60)) == 4)   // 3.5 frames rounds up
        #expect(a.index(nearest: Time(100, 1)) == 9)
    }

    @Test func effectKeysEveryClipFrameThroughTheSourceTime() throws {
        let a = analysis(frames: 120, pan: 1)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        // Clip shows source 1 s ... 3 s at 2x speed would need speed; use a plain trim: source starts at frame 30.
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: fd30 * 30, duration: fd30 * 60),
                     start: Time(10, 1))
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        #expect(e.kind == ClipEffect.stabilizeKind)
        #expect(e.isTransformStage)
        let x = try #require(e.parameters[ClipEffect.stagePositionXKey])
        #expect(x.track.keys.count <= 60 && x.track.keys.first?.time == .zero && x.track.keys.last?.time == fd30 * 59)
        let s0 = e.stageTransform(atLocal: .zero, clipDuration: c.duration, frame: Vec2(1920, 1080))
        #expect((s0.position - plan.corrections[30].position).length < 1e-9)
        #expect(abs(s0.rotation - plan.corrections[30].rotation) < 1e-9)
        #expect(abs(s0.scale - plan.corrections[30].scale) < 1e-9)
        let s9 = e.stageTransform(atLocal: fd30 * 9, clipDuration: c.duration, frame: Vec2(1920, 1080))
        #expect(abs(s9.position.x - plan.corrections[39].position.x) <= Stabilizer.positionTolerance + 1e-9)
        #expect(e.parameters[ClipEffect.stabilizeModeKey]?.value == 0)
    }

    @Test func stageRendersBeforeMotion() throws {
        let a = analysis(frames: 60, pan: 0, jitter: 10, rotJitter: 0)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 60), start: .zero)
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.effects = [Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())]
        let t = c.renderTransform(at: fd30 * 5, frame: Vec2(1920, 1080))
        // Motion (2x) scales the stage's shift: the frame center lands at 2 * correction position.
        let k = c.effects[0].stageTransform(atLocal: fd30 * 5, clipDuration: c.duration, frame: Vec2(1920, 1080))
        #expect(abs(k.position.x - plan.corrections[5].position.x) <= Stabilizer.positionTolerance + 1e-9)
        #expect((t.map(.zero) - k.position * 2).length < 1e-6)
        #expect(abs(t.scale.x - 2 * k.scale) < 1e-9)
    }

    @Test func catalogKnowsTheKindButThePanelDoesNotOfferIt() {
        #expect(EffectCatalog.spec(for: ClipEffect.stabilizeKind)?.title == "Stabilizer")
        #expect(!EffectCatalog.all.contains { $0.kind == ClipEffect.stabilizeKind })
    }

    @Test func sceneCutsAreSmoothedSeparately() throws {
        // Steady camera, then a cut where the analysis could not match (its motion is garbage and flagged).
        var a = analysis(frames: 200, jitter: 0, rotJitter: 0)
        a.motions[100] = CameraMotion(dx: 400, dy: 0)
        let blind = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        a.cuts = [100]
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.fullyCovered && plan.zoom == 1)
        #expect(plan.corrections.allSatisfy { $0 == .identity })
        #expect(blind.fullyCovered)   // the bilateral smoothing follows a jump instead of averaging across it
        var locked = StabilizerOptions(); locked.mode = .locked
        let l = try #require(Stabilizer.plan(a, options: locked))
        #expect(l.fullyCovered && l.zoom == 1)
    }

    @Test func eachSegmentOfACutShotIsSteadiedOnItsOwn() throws {
        var a = analysis(frames: 200, jitter: 6, rotJitter: 0.2)
        a.motions[100] = .identity
        a.cuts = [100]
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.corrections.count == 200)
        // Per segment, a world point is steadier than unstabilised.
        var segA = a; segA.motions = Array(a.motions[0..<100]); segA.frameTimes = Array(a.frameTimes[0..<100])
        var segB = a; segB.motions = Array(a.motions[100..<200]); segB.motions[0] = .identity; segB.frameTimes = Array(a.frameTimes[100..<200])
        let r = rendered(a, plan)
        let pathB = Stabilizer.path(segB.motions)
        let renderedB = (0..<100).map { k in Affine2(plan.corrections[100 + k]).apply(pathB[k].apply(Vec2(100, -50))) }
        #expect(Stabilizer.jitter(Array(r[0..<100])) < Stabilizer.jitter(raw(segA)) * 0.5)
        #expect(Stabilizer.jitter(renderedB) < Stabilizer.jitter(raw(segB)) * 0.5)
    }

    @Test func cutsRoundTripAndOldAnalysesDecodeWithoutThem() throws {
        var a = analysis(frames: 5)
        a.cuts = [3]
        #expect(try JSONDecoder().decode(StabilizationAnalysis.self, from: JSONEncoder().encode(a)) == a)
        a.cuts = []
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!json.contains("cuts"))
        #expect(try JSONDecoder().decode(StabilizationAnalysis.self, from: Data(json.utf8)).cuts == [])
    }

    @Test func effectControlsListOnlyTheSettings() {
        let keys = EffectTransformStage.stabilizeSpec.params.map(\.key)
        // Method, then the settings of both methods (Effect Controls shows the chosen method's, StabilizeEffectTests).
        #expect(keys == [ClipEffect.stabilizeMethodKey, ClipEffect.stabilizeModeKey, ClipEffect.stabilizeStrengthKey, ClipEffect.stabilizeSmoothnessKey,
                         ClipEffect.stabilizeMaxCropKey, ClipEffect.stabilizeEdgeFillKey, ClipEffect.rollingShutterKey, ClipEffect.rollingShutterStrengthKey,
                         ClipEffect.gyroSmoothnessKey, ClipEffect.gyroZoomLimitKey,
                         ClipEffect.gyroFieldOfViewKey, ClipEffect.gyroLensCorrectionKey, ClipEffect.gyroRollingShutterKey,
                         ClipEffect.gyroHorizonLockKey, ClipEffect.gyroSyncOffsetKey])
        // The stage still reads the generated keys.
        let a = analysis(frames: 60, jitter: 10, rotJitter: 0)
        let plan = Stabilizer.plan(a, options: StabilizerOptions())!
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 60), start: .zero)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        let s = e.stageTransform(atLocal: fd30 * 3, clipDuration: c.duration, frame: Vec2(1920, 1080))
        #expect((s.position - plan.corrections[3].position).length <= Stabilizer.positionTolerance + 1e-9)
    }

    @Test func theEffectRemembersTheAnalysedRangeAndNoticesALongerTrim() throws {
        let a = analysis(frames: 60)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 60), start: .zero)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        let shown = TimeRange(start: .zero, end: fd30 * 60)     // one frame past the last analyzed (59)
        #expect(!e.stabilizeNeedsAnalysis(of: shown, frameDuration: fd30))
        #expect(!e.stabilizeNeedsAnalysis(of: TimeRange(start: fd30 * 10, end: fd30 * 40), frameDuration: fd30))
        #expect(e.stabilizeNeedsAnalysis(of: TimeRange(start: .zero, end: fd30 * 90), frameDuration: fd30))
        #expect(e.stabilizeNeedsAnalysis(of: TimeRange(start: Time(-1, 1), end: fd30 * 60), frameDuration: fd30))
        var old = e; old.parameters[ClipEffect.stabilizeToKey] = nil; old.parameters[ClipEffect.stabilizeFromKey] = nil
        #expect(!old.stabilizeNeedsAnalysis(of: TimeRange(start: .zero, end: fd30 * 90), frameDuration: fd30))
    }

    @Test func analysisRoundTripsAsJSON() throws {
        let a = analysis(frames: 5)
        let back = try JSONDecoder().decode(StabilizationAnalysis.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }
    // MARK: Review fixes

    @Test func filesWithAStabilizerAreRefusedByV35Builds() throws {
        #expect(ProjectFile.currentVersion >= 36)
        #expect(ProjectFile.stabilizeVersion == 36)
        let a = analysis(frames: 30)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 30), start: .zero)
        c.effects = [Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())]
        var track = Track(kind: .video)
        try track.overwrite(c)
        let p = Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                        tracks: [track])])
        let data = try ProjectFile.encode(p)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try #require(obj["formatVersion"] as? Int)
        // A v35 build refuses anything newer than 35 (ProjectFile.decode: version > currentVersion).
        #expect(written > 35)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].effects == c.effects)
    }

    @Test func v35FilesStillOpen() throws {
        let p = Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                        tracks: [Track(kind: .video)])])
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 35
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines.count == 1)
    }

    @Test func decimationKeepsEveryValueWithinTolerance() {
        let times = (0..<200).map(Double.init)
        let vals = times.map { sin($0 / 9) * 5 + $0 * 0.1 }
        let kept = Stabilizer.decimate(times: times, values: vals, tolerance: 0.05)
        #expect(kept.first == 0 && kept.last == 199)
        #expect(kept.count < 100)
        for i in times.indices {
            let j = kept.lastIndex { $0 <= i }!
            let a = kept[j], b = kept[min(j + 1, kept.count - 1)]
            let f = b > a ? (times[i] - times[a]) / (times[b] - times[a]) : 0
            #expect(abs(vals[a] + (vals[b] - vals[a]) * f - vals[i]) <= 0.05 + 1e-12)
        }
        #expect(Stabilizer.decimate(times: [0, 1, 2, 3], values: [1, 1, 1, 1], tolerance: 0.05) == [0, 3])
    }

    /// Ten minutes at 30 fps of hand-held motion (smooth wobble 0.3-1.5 Hz, slow pan): keys stay within tolerance of the
    /// full per-frame correction, and far fewer than one per frame.
    @Test func tenMinuteClipStoresDecimatedKeys() throws {
        let n = 18_000
        var poses: [CameraPose] = []
        for k in 0..<n {
            let t = Double(k) / 30
            poses.append(CameraPose(translation: Vec2(0.5 * Double(k) + 4 * sin(2 * .pi * 0.7 * t) + 2 * sin(2 * .pi * 1.3 * t + 1),
                                                      3 * sin(2 * .pi * 0.4 * t + 2) + 1.5 * sin(2 * .pi * 1.1 * t)),
                                    rotation: 0.3 * sin(2 * .pi * 0.5 * t), logScale: 0))
        }
        var motions = [CameraMotion.identity]
        for k in 1..<n { motions.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
        let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { fd30 * Int64($0) }, motions: motions)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * Int64(n)), start: .zero)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        let keys = [ClipEffect.stagePositionXKey, ClipEffect.stagePositionYKey, ClipEffect.stageRotationKey, ClipEffect.stageScaleKey]
            .map { e.parameters[$0]?.track.keys.count ?? 0 }
        let total = keys.reduce(0, +)
        // The correction is the removed wobble itself (0.4-1.3 Hz here), so linear keys within 0.1 px land every ~3.4
        // frames: 21180 of the 72000 per-frame samples. Broadband real shake needs nearly every frame; slow drift needs few.
        #expect(total < 25_000, "keys \(keys)")
        let bytes = try ProjectFile.encoder().encode(e).count
        #expect(bytes < 5_500_000, "\(bytes) bytes, keys \(keys)")   // ~4.7 MB as the project file writes it (pretty-printed)
        var worst = (pos: 0.0, rot: 0.0, scale: 0.0)
        for i in stride(from: 0, to: n, by: 7) {
            let s = e.stageTransform(atLocal: fd30 * Int64(i), clipDuration: c.duration, frame: Vec2(1920, 1080))
            let full = plan.corrections[i]
            worst.pos = max(worst.pos, abs(s.position.x - full.position.x), abs(s.position.y - full.position.y))
            worst.rot = max(worst.rot, abs(s.rotation - full.rotation))
            worst.scale = max(worst.scale, abs(s.scale - full.scale))
        }
        #expect(worst.pos <= Stabilizer.positionTolerance + 1e-9)
        #expect(worst.rot <= Stabilizer.rotationTolerance + 1e-9)
        #expect(worst.scale <= Stabilizer.scaleTolerance + 1e-9)
    }

    @Test func keyframesCodeCompactlyAndReadFullLegacyKeys() throws {
        let plain = Keyframe(time: Time(3, 30), value: 1.5)
        let compact = ProjectFile.encoder()
        let json = String(decoding: try compact.encode(plain), as: UTF8.self)
        #expect(!json.contains("Handle") && !json.contains("Tangent") && !json.contains("interpolation"))
        #expect(try JSONDecoder().decode(Keyframe<Double>.self, from: Data(json.utf8)) == plain)
        let eased = Keyframe(time: Time(3, 30), value: Vec2(1, 2), interpolation: .bezier, inHandle: EaseHandle(dx: 0.5, dy: 0),
                             outHandle: EaseHandle(dx: 0.2, dy: 0.9), inTangent: Vec2(1, 0), outTangent: Vec2(0, -1))
        #expect(try JSONDecoder().decode(Keyframe<Vec2>.self, from: compact.encode(eased)) == eased)
        // Any other encoder (presets, templates, payloads older builds read) writes every field.
        let full = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        for field in ["interpolation", "inHandle", "outHandle", "inTangent", "outTangent"] { #expect(full.contains(field)) }
        let legacy = """
        {"id":"\(plain.id.uuidString)","time":{"value":1,"timescale":10},"value":1.5,"interpolation":"hold",
         "inHandle":{"dx":0.25,"dy":0.5},"outHandle":{"dx":0.3333333333333333,"dy":0.3333333333333333},
         "inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}}
        """
        let k = try JSONDecoder().decode(Keyframe<Double>.self, from: Data(legacy.utf8))
        #expect(k.interpolation == .hold && k.inHandle == EaseHandle(dx: 0.25, dy: 0.5) && k.outHandle == .linear && k.time == Time(3, 30))
    }

    @Test func slowDriftNeedsFewKeys() throws {
        let n = 18_000
        var motions = [CameraMotion.identity]
        for _ in 1..<n { motions.append(CameraMotion(dx: 0.3, dy: 0.1)) }
        let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { fd30 * Int64($0) }, motions: motions)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * Int64(n)), start: .zero)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        let total = [ClipEffect.stagePositionXKey, ClipEffect.stagePositionYKey, ClipEffect.stageRotationKey, ClipEffect.stageScaleKey]
            .map { e.parameters[$0]?.track.keys.count ?? 0 }.reduce(0, +)
        #expect(total <= 8, "\(total)")
    }

    /// Worst inset (px, > 0 = the picture edge shows) of the stage `s` at the four output corners of a hw x hh frame.
    private func edgeInset(_ s: StageTransform, hw: Double, hh: Double) -> Double {
        let m = Affine2(s), det = m.a * m.d - m.b * m.c
        var worst = -Double.infinity
        for q in [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)] {
            let v = q - m.t
            let p = Vec2((m.d * v.x - m.b * v.y) / det, (-m.c * v.x + m.a * v.y) / det)
            worst = max(worst, abs(p.x) - hw, abs(p.y) - hh)
        }
        return worst
    }

    @Test func decimatedKeysStillCoverTheFrame() throws {
        // Strong shake: the plan sits at the crop limit, so the exact zoom leaves no slack for key tolerances.
        for (seed, mode) in [(UInt64(7), StabilizerMode.smooth), (11, .smooth), (5, .locked)] {
            let a = analysis(frames: 300, jitter: mode == .locked ? 20 : 60, rotJitter: 2, scaleJitter: 0.01, seed: seed)
            var o = StabilizerOptions(); o.mode = mode
            let plan = try #require(Stabilizer.plan(a, options: o))
            #expect(plan.fullyCovered)
            let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 300), start: .zero)
            let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: o)
            var worst = -Double.infinity
            for i in 0..<300 {
                let st = e.stageTransform(atLocal: fd30 * Int64(i), clipDuration: c.duration, frame: Vec2(1920, 1080))
                worst = max(worst, edgeInset(st, hw: 960, hh: 540))
            }
            let full = plan.corrections.map { edgeInset($0, hw: 960, hh: 540) }.max()!
            #expect(full < 0, "the exact path keeps a margin: \(full) px")
            #expect(worst <= 1e-6, "seed \(seed) \(mode): edge shows by \(worst) px")
            if mode == .smooth { #expect(plan.crop <= o.maxCrop + 1e-9, "crop \(plan.crop)") }
        }
    }

    @Test func effectPresetPayloadsKeepFullKeysForOlderBuilds() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        e.parameters[ClipEffect.stagePositionXKey] = Stabilizer.decimatedProperty([0, 4, -3, 2], frameDuration: fd30, tolerance: 0.1)
        let preset = EffectPreset(referenceDuration: fd30 * 4, effects: [e])
        let obj = try #require(try JSONSerialization.jsonObject(with: preset.payload()) as? [String: Any])
        let effects = try #require(obj["effects"] as? [[String: Any]])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: effects), as: UTF8.self)
        #expect(json.contains("\"inHandle\"") && json.contains("\"interpolation\""))
        #expect(EffectPreset.payloadVersion == 1)
        #expect(try EffectPreset(payload: preset.payload(), version: 1) == preset)
    }

    @Test func aTrackCollapsesToAConstantOnlyWithinTolerance() {
        let wobble = Stabilizer.decimatedProperty([0, 0.15, 0.1], frameDuration: fd30, tolerance: 0.1)
        #expect(wobble.track.keys.count >= 2)
        for (i, v) in [0, 0.15, 0.1].enumerated() {
            #expect(abs(wobble.value(atLocal: fd30 * Int64(i)) - v) <= 0.1 + 1e-12)
        }
        let flat = Stabilizer.decimatedProperty([0.02, -0.05, 0.08, 0.01], frameDuration: fd30, tolerance: 0.1)
        #expect(flat.track.isEmpty && flat.value == 0.02)
    }
}
