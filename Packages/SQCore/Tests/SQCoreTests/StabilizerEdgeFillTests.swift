import Foundation
import Testing
@testable import SQCore

// Stabilizer Edge Fill (2026-10-18): what the crop limit leaves uncovered is zoomed away (default), mirrored or blurred.

private let fd30 = Time(1, 30)

private func clipWith(fill: StabilizerEdgeFill?) -> Clip {
    var e = ClipEffect.make(kind: ClipEffect.stabilizeKind)!
    e.parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(12)
    e.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(104)
    if let fill { e.parameters[ClipEffect.stabilizeEdgeFillKey] = AnimatedProperty(Double(fill.rawValue)) }
    return Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero, effects: [e])
}

@Suite struct StabilizerEdgeFillTests {
    @Test func rowIsAChoiceDefaultingToZoomAndSitsAfterCropLimit() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.stabilizeKind))
        let row = try #require(spec.params.first { $0.key == ClipEffect.stabilizeEdgeFillKey })
        #expect(row.kind == .choice(["Zoom", "Mirror Edge", "Blur Edge"]))
        #expect(row.defaultValue == 0)
        let keys = StabilizerMethod.standard.visibleKeys
        #expect(keys.firstIndex(of: ClipEffect.stabilizeEdgeFillKey) == keys.firstIndex(of: ClipEffect.stabilizeMaxCropKey)! + 1)
        #expect(!StabilizerMethod.gyroflow.visibleKeys.contains(ClipEffect.stabilizeEdgeFillKey))
    }

    @Test func optionsReadTheFillAndItReplansBecauseTheZoomDependsOnIt() {
        var e = ClipEffect.make(kind: ClipEffect.stabilizeKind)!
        #expect(StabilizerOptions(effect: e).edgeFill == .zoom)
        e.parameters[ClipEffect.stabilizeEdgeFillKey] = AnimatedProperty(2)
        #expect(StabilizerOptions(effect: e).edgeFill == .blur)
        e.parameters[ClipEffect.stabilizeEdgeFillKey] = AnimatedProperty(9)      // out of range: Zoom
        #expect(StabilizerOptions(effect: e).edgeFill == .zoom)
        let a = StabilizerOptions()
        var b = StabilizerOptions()
        b.edgeFill = .mirror
        #expect(a != b && !a.samePlan(as: b))
    }

    @Test func zoomKeepsTheStageOnTheClipTransform() {
        let c = clipWith(fill: nil)
        let t = c.renderTransform(at: .zero, frame: Vec2(1920, 1080))
        #expect(abs(t.scale.x - 1.04) < 1e-9)
        #expect(c.effects(at: .zero).segments.allSatisfy { $0.filter == nil })
    }

    @Test(arguments: [StabilizerEdgeFill.mirror, .blur])
    func fillMovesTheStageIntoAPictureWarp(fill: StabilizerEdgeFill) throws {
        let c = clipWith(fill: fill)
        let t = c.renderTransform(at: .zero, frame: Vec2(1920, 1080))
        #expect(t.scale.x == 1 && t.position == c.transform(at: .zero).position)
        let seg = try #require(c.effects(at: .zero).segments.first)
        guard case .stageFill(let a, _, _, let d, let tx, _, let f)? = seg.filter else {
            Issue.record("no stage fill: \(String(describing: seg.filter))"); return
        }
        #expect(f == fill)
        #expect(abs(a - 1 / 1.04) < 1e-9 && abs(d - 1 / 1.04) < 1e-9)
        #expect(abs(tx + 12 / 1.04) < 1e-9)       // output x reads the picture 12 / 1.04 px to the left
    }

    @Test func aDisabledOrGyroflowStabilizerAddsNoWarp() {
        var c = clipWith(fill: .mirror)
        c.effects[0].enabled = false
        #expect(c.effects(at: .zero).segments.allSatisfy { $0.filter == nil })
        c = clipWith(fill: .mirror)
        c.effects[0].parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(1)
        #expect(c.effects(at: .zero).segments.allSatisfy { $0.filter == nil })
    }

    // MARK: uncovered area and the lowered zoom (slice 3)

    @Test func uncoveredAreaOfASimpleShift() {
        // Picture shifted 96 px right of 1920x1080 output: 96 / 1920 = 5% of the output is open.
        let u = Stabilizer.uncoveredFraction(CameraPose(translation: Vec2(96, 0)), zoom: 1, hw: 960, hh: 540)
        #expect(abs(u - 0.05) < 1e-9)
        #expect(Stabilizer.uncoveredFraction(.identity, zoom: 1, hw: 960, hh: 540) < 1e-12)
        #expect(Stabilizer.uncoveredFraction(CameraPose(translation: Vec2(96, 40), rotation: 2), zoom: 1.5, hw: 960, hh: 540) < 1e-12)
        // Fully off the frame: everything is open.
        #expect(abs(Stabilizer.uncoveredFraction(CameraPose(translation: Vec2(5000, 0)), zoom: 1, hw: 960, hh: 540) - 1) < 1e-9)
    }

    private func shaky() -> StabilizationAnalysis {
        var s: UInt64 = 11
        func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 }
        var poses: [CameraPose] = []
        for _ in 0..<300 { poses.append(CameraPose(translation: Vec2(45 * next(), 30 * next()), rotation: 1.2 * next())) }
        var ms = [CameraMotion.identity]
        for k in 1..<poses.count { ms.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
        return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<300).map { fd30 * Int64($0) }, motions: ms)
    }

    @Test func zoomFillPlanIsUnchangedAndFullyCovered() throws {
        let a = shaky()
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.uncovered.count == plan.corrections.count)
        #expect(plan.uncovered.max()! < 1e-6)
    }

    @Test(arguments: [StabilizerEdgeFill.mirror, .blur])
    func fillLowersTheZoomWithinTheTolerance(fill: StabilizerEdgeFill) throws {
        let a = shaky()
        let zoomPlan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        var o = StabilizerOptions()
        o.edgeFill = fill
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(zoomPlan.zoom > 1.02)
        #expect(plan.zoom < zoomPlan.zoom && plan.zoom >= 1)
        #expect(plan.uncovered.max()! <= Stabilizer.edgeFillTolerance + 1e-6)
        #expect(plan.uncovered.max()! > 0)
        // The smoothed path and its jitter are the same.
        #expect(plan.models == zoomPlan.models)
    }

    @Test func aStillShotKeepsZoomOne() throws {
        var o = StabilizerOptions()
        o.edgeFill = .mirror
        let ms = Array(repeating: CameraMotion.identity, count: 30)
        let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<30).map { fd30 * Int64($0) }, motions: ms)
        #expect(try #require(Stabilizer.plan(a, options: o)).zoom == 1)
    }
}
