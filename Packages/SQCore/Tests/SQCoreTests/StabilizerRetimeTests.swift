import Foundation
import Testing
@testable import SQCore

// The analysis and the smoothing are keyed to SOURCE frames (window = Smoothness x fps of the source); the effect maps each
// timeline frame to its source time through speed and time remapping, so a speed change never changes the smoothing.

private let fd30 = Time(1, 30)

private func shaky(_ n: Int) -> StabilizationAnalysis {
    var s: UInt64 = 11
    func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 }
    var poses: [CameraPose] = []
    for k in 0..<n { poses.append(CameraPose(translation: Vec2(0.8 * Double(k) + 6 * rnd(), 6 * rnd()), rotation: 0.3 * rnd(), logScale: 0)) }
    var motions = [CameraMotion.identity]
    for k in 1..<n { motions.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
    return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { fd30 * Int64($0) }, motions: motions)
}

@Suite struct StabilizerRetimeTests {
    @Test func doubleSpeedClipUsesEverySecondSourceCorrection() throws {
        let a = shaky(120)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 60), start: .zero)
        c.speed = ClipSpeed(num: 2, den: 1)
        #expect(c.duration == fd30 * 30)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        for i in [0, 7, 15, 29] {
            let s = e.stageTransform(atLocal: fd30 * Int64(i), clipDuration: c.duration, frame: Vec2(1920, 1080))
            #expect(abs(s.position.x - plan.corrections[2 * i].position.x) <= Stabilizer.positionTolerance + 1e-9)
            #expect(abs(s.rotation - plan.corrections[2 * i].rotation) <= Stabilizer.rotationTolerance + 1e-9)
        }
        // The plan itself does not depend on the clip: same smoothing window in source frames at any speed.
        #expect(Stabilizer.plan(a, options: StabilizerOptions())?.corrections == plan.corrections)
    }

    @Test func speedRampFollowsTheSourceTimeNotTheTimelineTime() throws {
        let a = shaky(240)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 10), start: Time(5, 1))
        let keys = SpeedKeys(segments: [SpeedSegment(duration: fd30 * 30, from: ClipSpeed(num: 1, den: 1)),
                                        SpeedSegment(duration: fd30 * 30, from: ClipSpeed(num: 1, den: 1), to: ClipSpeed(num: 4, den: 1)),
                                        SpeedSegment(duration: fd30 * 30, from: ClipSpeed(num: 4, den: 1))], origin: .zero)
        c.setSpeedKeys(keys)
        let frames = Int(c.duration.frameIndex(frameDuration: fd30))
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: c, frameDuration: fd30, options: StabilizerOptions())
        var jumps: [Int] = []
        var last = -1
        for i in 0..<frames {
            let src = c.sourceTime(at: c.start + fd30 * Int64(i), frameDuration: fd30)
            let want = Stabilizer.correction(plan, a, at: src)
            let got = e.stageTransform(atLocal: fd30 * Int64(i), clipDuration: c.duration, frame: Vec2(1920, 1080))
            #expect(abs(got.position.x - want.position.x) <= Stabilizer.positionTolerance + 1e-6)
            #expect(abs(got.position.y - want.position.y) <= Stabilizer.positionTolerance + 1e-6)
            let idx = a.index(nearest: src)
            if last >= 0 { jumps.append(idx - last) }
            last = idx
        }
        // The ramp really skips source frames (1x, then up to 4x, then 4x): the lookup is not timeline-linear.
        #expect(jumps.max() ?? 0 >= 3)
    }
}
