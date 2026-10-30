import Foundation
import Testing
@testable import SQCore

// F7.15 Rolling shutter without gyro data: the readout time comes out of the measured slopes, a shot that cannot be
// measured falls back to the typical value, the shear follows the velocity, the analysis fields are additive in the
// cache file, and the Stabilizer carries the correction only when the option is on.

private let fd30 = Time(1, 30)

/// A hand-held pan: x(t) = pan * t + sway * sin(2 pi f t), y(t) = bob * sin(2 pi g t); slopes as a sensor with
/// `readout` would give them, plus `noise` px on every slope.
private func analysis(frames n: Int = 120, readout: Double, pan: Double = 300, sway: Double = 40, bob: Double = 15,
                      noise: Double = 0, scan: Int = 0, cuts: [Int] = [], every fd: Time = fd30,
                      sourceInterval: Double = 0) -> StabilizationAnalysis {
    let dt = Double(fd.value) / Double(fd.timescale)
    func pos(_ t: Double) -> Vec2 { Vec2(pan * t + sway * sin(2 * .pi * 1.3 * t), bob * sin(2 * .pi * 2.1 * t)) }
    func vel(_ t: Double) -> Vec2 {
        Vec2(pan + sway * 2 * .pi * 1.3 * cos(2 * .pi * 1.3 * t), bob * 2 * .pi * 2.1 * cos(2 * .pi * 2.1 * t))
    }
    var seed: UInt64 = 7
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31) * 2 - 1
    }
    var rolling: [RollingShutterSample?] = [nil]
    for i in 1..<n {
        let t0 = Double(i - 1) * dt, t1 = Double(i) * dt
        let d = pos(t1) - pos(t0), dv = vel(t1) - vel(t0)
        rolling.append(RollingShutterSample(shiftX: d.x, shiftY: d.y, slopeX: readout * dv.x + noise * rnd(),
                                            slopeY: readout * dv.y + noise * rnd()))
    }
    return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { fd * Int64($0) },
                                 motions: [CameraMotion](repeating: .identity, count: n), cuts: cuts,
                                 rolling: rolling, rollingScan: scan, sourceFrameInterval: sourceInterval)
}

private func videoClip() -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero)
}

@Suite struct RollingShutterTests {
    @Test func theReadoutTimeComesOutOfTheSlopes() {
        for readout in [0.008, 0.02, -0.02, 0.03] {
            let e = RollingShutter.estimate(analysis(readout: readout, noise: 0.3))
            #expect(e.measured)
            #expect(abs(e.readout - readout) < 0.002, "readout \(readout): \(e.readout) +- \(e.error)")
        }
        // A global shutter measures as (almost) zero instead of getting the typical value.
        let global = RollingShutter.estimate(analysis(readout: 0, noise: 0.3))
        #expect(global.measured && abs(global.readout) < 0.002)
    }

    @Test func aSteadyPanCannotBeMeasuredAndTakesTheTypicalReadout() {
        let steady = analysis(readout: 0.02, sway: 0, bob: 0, noise: 0.3)
        let e = RollingShutter.estimate(steady)
        #expect(!e.measured)
        #expect(e.readout == RollingShutter.typicalReadout)
        // Stored upside down or turned so the rows are read against the axis: the fallback runs the other way.
        #expect(RollingShutter.estimate(analysis(readout: 0.02, sway: 0, bob: 0, scan: 2)).readout == -RollingShutter.typicalReadout)
        #expect(RollingShutter.estimate(analysis(readout: 0.02, sway: 0, bob: 0, scan: 1)).readout == -RollingShutter.typicalReadout)
        #expect(RollingShutter.estimate(analysis(readout: 0.02, sway: 0, bob: 0, scan: 3)).readout == RollingShutter.typicalReadout)
        // An analysis without the measurement, and one too short.
        let none = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: [.zero, fd30], motions: [.identity, .identity])
        #expect(!RollingShutter.estimate(none).measured)
        // Never more than the frame interval.
        let wild = RollingShutter.estimate(analysis(readout: 0.2))
        #expect(wild.measured && abs(wild.readout - 1.0 / 30) < 1e-9)
    }

    /// The analyzer skips frames closer than 24 ms: a 60 fps source is analyzed every second frame, a 120 fps one every
    /// third. A sensor still cannot read longer than one source frame lasts, so the cap and the fallback follow the
    /// source's interval, not the analyzed one.
    @Test func theCapFollowsTheSourceFrameRateNotTheAnalyzedOne() {
        for (fps, every, fallback) in [(60.0, Time(2, 60), 0.010), (120.0, Time(3, 120), 0.005)] {
            let steady = RollingShutter.estimate(analysis(readout: 0.02, sway: 0, bob: 0, noise: 0.3, every: every, sourceInterval: 1 / fps))
            #expect(!steady.measured)
            #expect(abs(steady.readout - fallback) < 1e-12, "\(fps) fps: fallback \(steady.readout)")
            let against = RollingShutter.estimate(analysis(readout: 0.02, sway: 0, bob: 0, scan: 2, every: every, sourceInterval: 1 / fps))
            #expect(abs(against.readout + fallback) < 1e-12)
            // A measurement beyond one source frame is held at it, in both scan directions.
            for sign in [1.0, -1.0] {
                let wild = RollingShutter.estimate(analysis(readout: sign * 0.03, every: every, sourceInterval: 1 / fps))
                #expect(wild.measured && abs(wild.readout - sign / fps) < 1e-12, "\(fps) fps: measured \(wild.readout)")
            }
            // One inside the cap comes out as measured.
            let fine = RollingShutter.estimate(analysis(readout: 0.004, noise: 0.05, every: every, sourceInterval: 1 / fps))
            #expect(fine.measured && abs(fine.readout - 0.004) < 0.001, "\(fps) fps: \(fine.readout)")
        }
        // Not known (an analysis without the field): the analyzed interval stands in.
        #expect(RollingShutter.readoutCap(analysis(readout: 0.02, every: Time(2, 60))) == 1.0 / 30)
        #expect(RollingShutter.readoutCap(analysis(readout: 0.02, every: Time(2, 60), sourceInterval: 1.0 / 60)) == 1.0 / 60)
    }

    /// Rolling Shutter Strength scales the stored shear when the frame is drawn: changing it needs no new plan.
    @Test func strengthAloneNeedsNoNewPlan() {
        var a = StabilizerOptions(), b = StabilizerOptions()
        a.rollingShutter = true; b.rollingShutter = true
        b.rollingShutterStrength = 40
        #expect(a != b && a.samePlan(as: b))
        b.rollingShutter = false
        #expect(!a.samePlan(as: b))
        b.rollingShutter = true; b.smoothness = 1
        #expect(!a.samePlan(as: b))
    }

    @Test func theShearIsReadoutTimesVelocity() {
        // 300 px/s at 20 ms readout: verticals lean 6 px over the 1080 rows.
        let a = analysis(readout: 0.02, sway: 0, bob: 0)
        let s = RollingShutter.shears(a, readout: 0.02)
        #expect(s.count == 120)
        for v in s { #expect(abs(v.x * 1080 - 6) < 1e-6 && abs(v.y) < 1e-9) }
        // Rows upright: the same shift counts against the width.
        let turned = RollingShutter.shears(analysis(readout: 0.02, sway: 0, bob: 0, scan: 3), readout: 0.02)
        #expect(abs(turned[10].x * 1920 - 6) < 1e-6)
        // Between two analyzed frames the shear is interpolated; outside it is held; a cut is not crossed.
        let swaying = analysis(readout: 0.02, cuts: [50])
        let sh = RollingShutter.shears(swaying, readout: 0.02)
        let mid = RollingShutter.shear(sh, swaying, at: Time(21, 60))
        #expect(abs(mid.x - (sh[10].x + sh[11].x) / 2) < 1e-12)
        #expect(RollingShutter.shear(sh, swaying, at: Time(-1, 1)) == sh[0])
        #expect(RollingShutter.shear(sh, swaying, at: Time(100, 1)) == sh[119])
        #expect(RollingShutter.shear(sh, swaying, at: Time(99, 60)) == sh[49])
        // Frame 49 ends its shot: only the pair into it counts (the pair across the cut is another picture).
        let pair = swaying.rolling[49]!
        #expect(abs(sh[49].x - pair.shiftX * 30 * 0.02 / 1080) < 1e-12)
    }

    @Test func theAnalysisFieldsAreAdditiveInTheCacheFile() throws {
        let plain = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: [.zero, fd30],
                                          motions: [.identity, CameraMotion(dx: 3, dy: 1)])
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("rolling"))
        let back = try JSONDecoder().decode(StabilizationAnalysis.self, from: Data(plainJSON.utf8))
        #expect(back == plain && back.rolling.isEmpty && back.rollingScan == 0 && back.sourceFrameInterval == 0)
        #expect(!plainJSON.contains("sourceFrameInterval"))
        var with = plain
        with.rolling = [nil, RollingShutterSample(shiftX: 3, shiftY: 1, slopeX: 0.5, slopeY: -0.25)]
        with.rollingScan = 3
        with.sourceFrameInterval = 1.0 / 60
        let again = try JSONDecoder().decode(StabilizationAnalysis.self, from: try JSONEncoder().encode(with))
        #expect(again == with && again.rollingScansAlongX)
    }

    @Test func theStabilizerCarriesTheCorrectionOnlyWhenTheOptionIsOn() throws {
        let a = analysis(readout: 0.02, noise: 0.2)
        var clip = videoClip()
        let off = StabilizerOptions()
        let plan = try #require(Stabilizer.plan(a, options: off))
        let plain = Stabilizer.effect(plan: plan, analysis: a, clip: clip, frameDuration: fd30, options: off)
        #expect(plain.parameters[ClipEffect.rollingShutterKey]?.value == 0 && plain.parameters[ClipEffect.rollingShearXKey] == nil)
        #expect(plain.rollingShutterFilter(atLocal: fd30 * 10) == nil)
        #expect(StabilizerOptions(effect: plain) == off)

        var on = off
        on.rollingShutter = true
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: clip, frameDuration: fd30, options: on)
        #expect(StabilizerOptions(effect: e) == on)
        guard case .rollingShutter(let shear, let alongX)? = e.rollingShutterFilter(atLocal: fd30 * 10) else {
            Issue.record("no rolling shutter pass"); return
        }
        // Frame 10 moves at 300 + 40 * 2 pi * 1.3 * cos(2 pi * 1.3 / 3) px/s; 20 ms of that over 1080 rows.
        let v = 300 + 40 * 2 * Double.pi * 1.3 * cos(2 * .pi * 1.3 / 3)
        #expect(!alongX)
        #expect(abs(shear.x * 1080 - v * 0.02) < 0.8, "shear \(shear.x * 1080) px, expected \(v * 0.02)")
        // The keys are decimated, never one per frame.
        #expect((e.parameters[ClipEffect.rollingShearXKey]?.track.keys.count ?? 99) < 60)
        // Strength scales it without a new plan; 0 plans no pass.
        var half = e
        half.parameters[ClipEffect.rollingShutterStrengthKey] = AnimatedProperty(50)
        guard case .rollingShutter(let halfShear, _)? = half.rollingShutterFilter(atLocal: fd30 * 10) else { Issue.record("no pass"); return }
        #expect(abs(halfShear.x - shear.x / 2) < 1e-12)
        half.parameters[ClipEffect.rollingShutterStrengthKey] = AnimatedProperty(0)
        #expect(half.rollingShutterFilter(atLocal: fd30 * 10) == nil)
        // Unchecked or Gyroflow: nothing.
        var unchecked = e
        unchecked.parameters[ClipEffect.rollingShutterKey] = AnimatedProperty(0)
        #expect(unchecked.rollingShutterFilter(atLocal: fd30 * 10) == nil)
        var gyro = e
        gyro.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(Double(StabilizerMethod.gyroflow.rawValue))
        #expect(gyro.rollingShutterFilter(atLocal: fd30 * 10) == nil)

        // The clip renders the row shift as a pass of its own; without the option there is none.
        clip.effects = [e]
        #expect(clip.effects(at: fd30 * 10).segments.first?.filter == .rollingShutter(shear: shear, alongX: false))
        clip.effects = [plain]
        #expect(clip.effects(at: fd30 * 10) == .none)
        // An analysis from before the option: the option is kept, no shear is written.
        var old = a
        old.rolling = []
        let waiting = Stabilizer.effect(plan: plan, analysis: old, clip: clip, frameDuration: fd30, options: on)
        #expect(StabilizerOptions(effect: waiting).rollingShutter && waiting.rollingShutterFilter(atLocal: fd30 * 10) == nil)
    }

    @Test func effectControlsShowsTheOptionForStandardOnly() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.stabilizeKind))
        let row = try #require(spec.params.first { $0.key == ClipEffect.rollingShutterKey })
        #expect(row.title == "Rolling Shutter" && row.defaultValue == 0)
        #expect(spec.params.first { $0.key == ClipEffect.rollingShutterStrengthKey }?.defaultValue == 100)
        #expect(StabilizerMethod.standard.visibleKeys.suffix(2) == [ClipEffect.rollingShutterKey, ClipEffect.rollingShutterStrengthKey])
        #expect(!StabilizerMethod.gyroflow.visibleKeys.contains(ClipEffect.rollingShutterKey))
    }
}
