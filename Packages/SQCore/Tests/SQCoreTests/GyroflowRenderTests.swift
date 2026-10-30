import Foundation
import Testing
@testable import SQCore

// Gyroflow render request (docs/GYROFLOW.md (g) step 2): a clip whose Stabilizer uses Gyroflow carries its options on
// the layer request, so playback and export warp the decoded frame the same way before every other effect.

private let fd30 = Time(1, 30)

private func clip(_ effects: [ClipEffect]) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero, effects: effects)
}

private func timeline(_ c: Clip) throws -> Timeline {
    var tr = Track(kind: .video)
    try tr.overwrite(c)
    return Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30), tracks: [tr])
}

private func gyroStabilizer(smoothness: Double = 80, zoom: Double = 150, rs: Bool = false, horizon: Double = 40) throws -> ClipEffect {
    var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
    e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(Double(StabilizerMethod.gyroflow.rawValue))
    e.parameters[ClipEffect.gyroSmoothnessKey] = AnimatedProperty(smoothness)
    e.parameters[ClipEffect.gyroZoomLimitKey] = AnimatedProperty(zoom)
    e.parameters[ClipEffect.gyroRollingShutterKey] = AnimatedProperty(rs ? 1 : 0)
    e.parameters[ClipEffect.gyroHorizonLockKey] = AnimatedProperty(horizon)
    return e
}

@Suite struct GyroflowRenderTests {
    @Test func gyroflowStabilizerPutsItsOptionsOnTheLayer() throws {
        let e = try gyroStabilizer()
        let tl = try timeline(clip([e]))
        let r = try #require(tl.videoLayers(at: fd30 * 10).first)
        let g = try #require(r.gyro)
        #expect(g == GyroflowOptions(effect: e))
        #expect(g.smoothness == 80 && g.zoomLimit == 150 && g.rollingShutter == false && g.horizonLock == 40)
    }

    @Test func standardDisabledOrNoStabilizerHasNoGyro() throws {
        var standard = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
        standard.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(0)
        #expect(try timeline(clip([standard])).videoLayers(at: fd30).first?.gyro == nil)
        var off = try gyroStabilizer()
        off.enabled = false
        #expect(try timeline(clip([off])).videoLayers(at: fd30).first?.gyro == nil)
        #expect(try timeline(clip([])).videoLayers(at: fd30).first?.gyro == nil)
    }

    @Test func gyroflowStabilizerDoesNotMoveTheTransformStage() throws {
        // The warp is the whole correction: the request's transform equals a clip without any Stabilizer.
        let with = try #require(try timeline(clip([try gyroStabilizer()])).videoLayers(at: fd30 * 5).first)
        let without = try #require(try timeline(clip([])).videoLayers(at: fd30 * 5).first)
        #expect(with.transform == without.transform)
    }

    @Test func timestampIsTheFrameTimeInMicroseconds() {
        #expect(GyroflowOptions.timestampMicroseconds(.zero) == 0)
        #expect(GyroflowOptions.timestampMicroseconds(fd30 * 3) == 100_000)
        #expect(GyroflowOptions.timestampMicroseconds(Time(1001, 30000)) == 33_367)          // 33366.67 rounds up
        #expect(GyroflowOptions.timestampMicroseconds(Time(1001, 30000) * 1575) == 52_552_500)
        #expect(GyroflowOptions.timestampMicroseconds(Time(1, 3)) == 333_333)
        #expect(GyroflowOptions.timestampMicroseconds(Time(-1, 25)) == -40_000)
    }

    @Test func optionsAreClampedToThePluginRanges() throws {
        let e = try gyroStabilizer(smoothness: 0, zoom: 900, horizon: -5)
        let g = GyroflowOptions(effect: e)
        #expect(g.smoothness == 1 && g.zoomLimit == 300 && g.horizonLock == 0)
    }
}
