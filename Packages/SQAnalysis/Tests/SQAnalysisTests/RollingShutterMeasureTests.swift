import Foundation
import SQCore
import Testing
@testable import SQAnalysis

// F7.15 Rolling shutter without gyro data, measured on synthesized frames: a textured scene filmed hand-held by a
// sensor that reads its rows one after the other (every row sees the scene where the camera was when that row was read).
// The readout time must come back out of the frames, a global shutter must measure as none, and the shear that is left
// after the correction is reported in source pixels.

/// A scene with detail at several sizes, gray levels around 128.
private func scene(_ x: Double, _ y: Double) -> Double {
    128 + 34 * sin(x / 5.3 + y / 9.1) + 28 * cos(x / 11.7 - y / 6.3) + 22 * sin(x / 3.1) * cos(y / 4.3)
        + 18 * sin((x + 2 * y) / 17.9) + 14 * cos((3 * x - y) / 23.3)
}

/// Where the scene stands in the picture at time `t` (analysis px): a pan with sway, and a bob.
private struct Camera {
    var pan = 40.0, sway = 6.0, bob = 2.5
    func shift(_ t: Double) -> Vec2 { Vec2(pan * t + sway * sin(2 * .pi * 1.3 * t), bob * sin(2 * .pi * 2.1 * t + 0.4)) }
    func velocity(_ t: Double) -> Vec2 {
        Vec2(pan + sway * 2 * .pi * 1.3 * cos(2 * .pi * 1.3 * t), bob * 2 * .pi * 2.1 * cos(2 * .pi * 2.1 * t + 0.4))
    }
}

/// Frame `i` at 30 fps as a sensor with `readout` seconds from the first to the last row (scan position along y, or
/// along x when `alongX`) records it, with `noise` gray levels of sensor noise.
private func frame(_ i: Int, readout: Double, camera: Camera, w: Int = 256, h: Int = 144, noise: Double = 1,
                   alongX: Bool = false) -> GrayFrame {
    var seed = UInt64(i) &* 7919 &+ 13
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31) * 2 - 1
    }
    var px = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let v = alongX ? (Double(x) + 0.5 - Double(w) / 2) / Double(w) : (Double(y) + 0.5 - Double(h) / 2) / Double(h)
            let c = camera.shift(Double(i) / 30 + readout * v)
            px[y * w + x] = Float(scene(Double(x) - c.x, Double(y) - c.y) + noise * rnd())
        }
    }
    return GrayFrame(width: w, height: h, pixels: px)
}

/// The analysis the Stabilizer pass would store for the frames (source picture 1920 x 1080 over 256 x 144).
private func analyze(frames n: Int, readout: Double, camera: Camera = Camera(), scan: Int = 0) -> (StabilizationAnalysis, Double) {
    let factor = 1920.0 / 256
    var rolling: [RollingShutterSample?] = [nil]
    var previous = frame(0, readout: readout, camera: camera, alongX: scan % 2 != 0)
    var spent = 0.0
    for i in 1..<n {
        let current = frame(i, readout: readout, camera: camera, alongX: scan % 2 != 0)
        let check = PhotometricRegistration.register(previous: previous, current: current)
        let began = Date()
        rolling.append(check.flatMap { c in
            c.converged ? RollingShutterMeasure.sample(previous: previous, current: current, around: c.motion, alongX: scan % 2 != 0)
                .map { RollingShutterMeasure.scaled($0, by: factor) } : nil
        })
        spent += Date().timeIntervalSince(began)
        previous = current
    }
    let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { Time(Int64($0), 30) },
                                  motions: [CameraMotion](repeating: .identity, count: n), rolling: rolling, rollingScan: scan)
    return (a, spent / Double(n - 1) * 1000)
}

private func report(_ line: String) {
    print(line)
    guard let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

@Suite(.serialized) struct RollingShutterMeasureTests {
    @Test func aPlaneGoesThroughItsPoints() throws {
        let p = [Vec2(-3, -2), Vec2(4, -2), Vec2(-3, 5), Vec2(4, 5), Vec2(0, 1)]
        let c = try #require(RollingShutterMeasure.plane(p, p.map { 2 - 0.5 * $0.x + 0.25 * $0.y }))
        #expect(abs(c[0] - 2) < 1e-9 && abs(c[1] + 0.5) < 1e-9 && abs(c[2] - 0.25) < 1e-9)
        #expect(RollingShutterMeasure.plane([Vec2(0, 0), Vec2(1, 1), Vec2(2, 2)], [1, 2, 3]) == nil)
    }

    @Test func aPairGivesShiftAndSlope() throws {
        // Speeding up from 30 to 120 px/s between two frames at 20 ms readout: the last row runs ahead of the first one
        // by 0.02 * 90 = 1.8 px, on top of the shift.
        func shot(_ t: Double, _ v: Double) -> GrayFrame {
            var px = [Float](repeating: 0, count: 256 * 144)
            for y in 0..<144 { for x in 0..<256 {
                let row = (Double(y) + 0.5 - 72) / 144
                px[y * 256 + x] = Float(scene(Double(x) - (t + v * 0.02 * row), Double(y)))
            } }
            return GrayFrame(width: 256, height: 144, pixels: px)
        }
        let a = shot(0, 30), b = shot(2.5, 120)
        let check = try #require(PhotometricRegistration.register(previous: a, current: b))
        let s = try #require(RollingShutterMeasure.sample(previous: a, current: b, around: check.motion, alongX: false))
        #expect(abs(s.shiftX - 2.5) < 0.1 && abs(s.shiftY) < 0.1, "shift \(s.shiftX), \(s.shiftY)")
        #expect(abs(s.slopeX - 1.8) < 0.3 && abs(s.slopeY) < 0.3, "slope \(s.slopeX), \(s.slopeY)")
    }

    /// Non-square pixels (anamorphic, pixel aspect 1.33): the analysis frame has the stored pixels, the picture is the
    /// displayed one (1920 x 1080 over 192 x 144: 10 across, 7.5 down). A camera that shifts and rolls about its axis
    /// is a similarity in the displayed picture only; the sample must report the shift per axis in source pixels and
    /// no slope (one factor for both axes gave shiftY 1.33 times too large and read the roll as a shear).
    @Test func nonSquarePixelsAreMeasuredInTheDisplayedPicture() throws {
        let w = 192, h = 144, fx = 10.0, fy = 7.5, roll = 0.012
        func shot(_ dx: Double, _ dy: Double, _ angle: Double) -> GrayFrame {
            var px = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                // Displayed position of the texel about the center, rolled back, in stored pixels again.
                let X = (Double(x) - Double(w - 1) / 2) * fx, Y = (Double(y) - Double(h - 1) / 2) * fy
                let sx = (X + angle * Y) / fx + Double(w - 1) / 2 - dx, sy = (Y - angle * X) / fy + Double(h - 1) / 2 - dy
                px[y * w + x] = Float(scene(sx, sy))
            } }
            return GrayFrame(width: w, height: h, pixels: px)
        }
        let a = shot(0, 0, 0), b = shot(2, 1.5, roll)
        let check = try #require(PhotometricRegistration.register(previous: a, current: b))
        let s = try #require(RollingShutterMeasure.sample(previous: a, current: b, around: check.motion, alongX: false,
                                                          factorX: fx, factorY: fy))
        #expect(abs(s.shiftX - 20) < 1 && abs(s.shiftY - 11.25) < 1, "shift \(s.shiftX), \(s.shiftY)")
        #expect(abs(s.slopeX) < 2.5 && abs(s.slopeY) < 2.5, "slope \(s.slopeX), \(s.slopeY)")
        // One factor for both axes, as before: the roll comes out as a shear of about 10 px.
        let one = try #require(RollingShutterMeasure.sample(previous: a, current: b, around: check.motion, alongX: false))
        #expect(abs(RollingShutterMeasure.scaled(one, by: fx).slopeX) > 6)
        // Square pixels: both factors equal is the old scaling.
        let square = try #require(RollingShutterMeasure.sample(previous: a, current: b, around: check.motion, alongX: false,
                                                               factorX: 7.5, factorY: 7.5))
        let scaled = RollingShutterMeasure.scaled(one, by: 7.5)
        #expect(abs(square.shiftX - scaled.shiftX) < 1e-9 && abs(square.shiftY - scaled.shiftY) < 1e-9)
        #expect(abs(square.slopeX - scaled.slopeX) < 1e-9 && abs(square.slopeY - scaled.slopeY) < 1e-9)
    }

    @Test func theReadoutTimeComesBackOutOfTheFrames() {
        var lines: [String] = []
        for readout in [0.02, 0.01, -0.02, 0.0] {
            let (a, cost) = analyze(frames: 90, readout: readout)
            let e = RollingShutter.estimate(a)
            // What is left after the correction: the worst lean in source px over the picture height.
            let camera = Camera(), factor = 1920.0 / 256
            let shears = RollingShutter.shears(a, readout: e.readout)
            var left = 0.0, was = 0.0
            for i in 2..<88 {
                let truth = camera.velocity(Double(i) / 30).x * factor * readout
                left = max(left, abs(shears[i].x * 1080 - truth)); was = max(was, abs(truth))
            }
            lines.append("readout \(Int(readout * 1000)) ms: measured \(String(format: "%.1f", e.readout * 1000)) ms"
                + " (+-\(String(format: "%.1f", e.error * 1000)), \(e.measured ? "measured" : "typical"), \(e.observations) obs),"
                + " lean \(String(format: "%.1f", was)) -> \(String(format: "%.1f", left)) px, \(String(format: "%.1f", cost)) ms/frame")
            #expect(e.measured, "readout \(readout): \(e)")
            #expect(abs(e.readout - readout) < max(0.004, abs(readout) * 0.25), "readout \(readout): \(e.readout)")
            if readout != 0 { #expect(left < was / 2, "readout \(readout): \(left) of \(was) px left") }
        }
        report("SQROLLINGMEASURE " + lines.joined(separator: "\nSQROLLINGMEASURE "))
    }

    @Test func sensorRowsStandingUprightAreMeasuredAlongX() {
        let (a, _) = analyze(frames: 90, readout: 0.02, scan: 3)
        let e = RollingShutter.estimate(a)
        report("SQROLLINGMEASURE along x, readout 20 ms: measured \(String(format: "%.1f", e.readout * 1000)) ms (+-\(String(format: "%.1f", e.error * 1000)))")
        #expect(e.measured && abs(e.readout - 0.02) < 0.006, "\(e)")
    }

    @Test func aSteadyPanTakesTheTypicalReadout() {
        let (a, _) = analyze(frames: 40, readout: 0.02, camera: Camera(pan: 40, sway: 0, bob: 0))
        let e = RollingShutter.estimate(a)
        #expect(!e.measured && e.readout == RollingShutter.typicalReadout, "\(e)")
        // The shear still follows the pan: 300 px/s * 16 ms.
        let s = RollingShutter.shears(a, readout: e.readout)
        #expect(abs(s[20].x * 1080 - 4.8) < 0.3)
    }
}
