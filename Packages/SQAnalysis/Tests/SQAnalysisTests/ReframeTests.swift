import Foundation
import Testing
import SQCore
@testable import SQAnalysis

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }
private func near(_ a: Vec2, _ b: Vec2, _ eps: Double = 1e-6) -> Bool { near(a.x, b.x, eps) && near(a.y, b.y, eps) }
private func face(_ cx: Double, _ cy: Double, size: Double = 0.1, confidence: Double = 0.9) -> SubjectBox {
    SubjectBox(kind: .face, rect: NormalizedRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size), confidence: confidence)
}

/// 16:9 landscape picture into a 9:16 portrait frame.
private let landscapeToPortrait = ReframeGeometry(pictureWidth: 1920, pictureHeight: 1080, frameWidth: 1080, frameHeight: 1920)

@Suite struct ReframeGeometryTests {
    @Test func samePictureShapeIsAlreadyFramed() {
        #expect(ReframeGeometry(pictureWidth: 3840, pictureHeight: 2160, frameWidth: 1920, frameHeight: 1080).isAlreadyFramed)
        #expect(!ReframeGeometry(pictureWidth: 3840, pictureHeight: 2160, frameWidth: 1920, frameHeight: 1080, zoom: 1.5).isAlreadyFramed)
        #expect(!landscapeToPortrait.isAlreadyFramed)
    }

    @Test func coverScaleFillsTheFrameOnBothAxes() {
        #expect(near(landscapeToPortrait.scale, 1920.0 / 1080.0))
        let same = ReframeGeometry(pictureWidth: 3840, pictureHeight: 2160, frameWidth: 1920, frameHeight: 1080)
        #expect(near(same.scale, 0.5))
        let zoomed = ReframeGeometry(pictureWidth: 3840, pictureHeight: 2160, frameWidth: 1920, frameHeight: 1080, zoom: 1.5)
        #expect(near(zoomed.scale, 0.75))
        // A zoom below 1 would show bars: clamped to 1.
        let out = ReframeGeometry(pictureWidth: 3840, pictureHeight: 2160, frameWidth: 1920, frameHeight: 1080, zoom: 0.5)
        #expect(near(out.scale, 0.5))
    }

    @Test func centredSubjectNeedsNoOffset() {
        #expect(near(landscapeToPortrait.position(centering: Vec2(0.5, 0.5)), .zero))
    }

    @Test func offCentreSubjectMovesThePictureTheOtherWay() {
        let s = 1920.0 / 1080.0
        // Subject a quarter of the width right of center: 480 source px, so the picture moves 480 * s left.
        #expect(near(landscapeToPortrait.position(centering: Vec2(0.75, 0.5)), Vec2(-480 * s, 0)))
        #expect(near(landscapeToPortrait.position(centering: Vec2(0.25, 0.5)), Vec2(480 * s, 0)))
    }

    @Test func positionIsClampedSoThePictureAlwaysCoversTheFrame() {
        let s = 1920.0 / 1080.0
        let limit = (1920 * s - 1080) / 2
        #expect(near(landscapeToPortrait.maxOffset, Vec2(limit, 0)))
        #expect(near(landscapeToPortrait.position(centering: Vec2(1, 0)), Vec2(-limit, 0)))
        #expect(near(landscapeToPortrait.position(centering: Vec2(0, 1)), Vec2(limit, 0)))
    }

    @Test func anchorIsTakenIntoAccount() {
        var g = landscapeToPortrait
        g.anchor = Vec2(100, 0)
        let s = g.scale
        // Point p lands at center + position + s * (p - anchor).
        #expect(near(g.position(centering: Vec2(0.75, 0.5)), Vec2(-(480 - 100) * s, 0)))
        #expect(near(g.position(centering: Vec2(0.5, 0.5)), Vec2(100 * s, 0)))
    }

    @Test func zoomOpensTheVerticalAxis() {
        let g = ReframeGeometry(pictureWidth: 1920, pictureHeight: 1080, frameWidth: 1080, frameHeight: 1920, zoom: 2)
        #expect(g.maxOffset.y > 0)
        #expect(g.position(centering: Vec2(0.5, 0.25)).y > 0)
    }
}

@Suite struct ReframeFocusTests {
    @Test func facesWinOverBodiesAndSaliency() {
        let boxes = [
            SubjectBox(kind: .saliency, rect: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2), confidence: 1),
            SubjectBox(kind: .body, rect: NormalizedRect(x: 0.7, y: 0.2, width: 0.2, height: 0.6), confidence: 1),
            face(0.3, 0.4),
        ]
        #expect(near(ReframeFocus.focus(of: boxes, minConfidence: 0.3)!, Vec2(0.3, 0.4)))
    }

    @Test func severalFacesGiveTheirWeightedCentre() {
        // Same size and confidence: plain midpoint.
        #expect(near(ReframeFocus.focus(of: [face(0.2, 0.5), face(0.6, 0.3)], minConfidence: 0.3)!, Vec2(0.4, 0.4)))
        // Larger face pulls harder (area weight 4:1).
        let f = ReframeFocus.focus(of: [face(0.2, 0.5, size: 0.2), face(0.7, 0.5, size: 0.1)], minConfidence: 0.3)!
        #expect(near(f, Vec2(0.3, 0.5)))
    }

    @Test func bodyFocusesOnTheUpperPart() {
        let b = SubjectBox(kind: .body, rect: NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6), confidence: 0.8)
        let f = ReframeFocus.focus(of: [b], minConfidence: 0.3)!
        #expect(near(f, Vec2(0.5, 0.2 + 0.6 * ReframeFocus.bodyHeadFraction)))
    }

    @Test func saliencyUsesTheBoxCentre() {
        let b = SubjectBox(kind: .saliency, rect: NormalizedRect(x: 0.6, y: 0.2, width: 0.2, height: 0.4), confidence: 1)
        #expect(near(ReframeFocus.focus(of: [b], minConfidence: 0.3)!, Vec2(0.7, 0.4)))
    }

    @Test func weakDetectionsAreIgnored() {
        #expect(ReframeFocus.focus(of: [face(0.2, 0.2, confidence: 0.1)], minConfidence: 0.3) == nil)
        #expect(ReframeFocus.focus(of: [], minConfidence: 0.3) == nil)
        // A weak face does not hide a confident body.
        let b = SubjectBox(kind: .body, rect: NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6), confidence: 0.9)
        #expect(ReframeFocus.focus(of: [face(0.1, 0.1, confidence: 0.1), b], minConfidence: 0.3)!.x == 0.5)
    }
}

@Suite struct ReframeSmoothingTests {
    @Test func gapsHoldTheLastKnownPointAndTheStartTakesTheFirst() {
        let a = Vec2(1, 1), b = Vec2(5, 5)
        #expect(ReframeSmoothing.fillGaps([nil, a, nil, nil, b, nil]) == [a, a, a, a, b, b])
        #expect(ReframeSmoothing.fillGaps([nil, nil]) == nil)
        #expect(ReframeSmoothing.fillGaps([]) == nil)
    }

    @Test func deadZoneSwallowsJitter() {
        let pts = [Vec2(0, 0), Vec2(3, -2), Vec2(-4, 1), Vec2(2, 3), Vec2(-1, -4)]
        let out = ReframeSmoothing.deadZone(pts, radius: Vec2(5, 5))
        #expect(out.allSatisfy { $0 == Vec2(0, 0) })
    }

    @Test func deadZoneFollowsALargeMoveLazily() {
        let out = ReframeSmoothing.deadZone([Vec2(0, 0), Vec2(20, 0), Vec2(20, 0)], radius: Vec2(5, 5))
        // The camera moves just enough to keep the target on the edge of the zone.
        #expect(out == [Vec2(0, 0), Vec2(15, 0), Vec2(15, 0)])
    }

    @Test func movingAverageKeepsConstantsAndSoftensASte() {
        let flat = Array(repeating: Vec2(7, -3), count: 9)
        #expect(ReframeSmoothing.movingAverage(flat, radius: 2) == flat)
        let step = (0..<10).map { Vec2($0 < 5 ? 0 : 10, 0) }
        let out = ReframeSmoothing.movingAverage(step, radius: 2)
        #expect(out.first == Vec2(0, 0) && out.last == Vec2(10, 0))
        for i in 1..<out.count { #expect(out[i].x >= out[i - 1].x) }
        #expect(out[4].x > 0 && out[4].x < 10)
        #expect(ReframeSmoothing.movingAverage(step, radius: 0) == step)
    }

    @Test func simplifyDropsPointsOnAStraightLine() {
        let times = (0..<10).map(Double.init)
        let line = times.map { Vec2($0 * 3, -$0) }
        #expect(ReframeSmoothing.simplify(times: times, points: line, tolerance: 0.5) == [0, 9])
    }

    @Test func simplifyKeepsACorner() {
        let times = (0..<9).map(Double.init)
        let v = times.map { Vec2($0 <= 4 ? $0 * 10 : (8 - $0) * 10, 0) }
        #expect(ReframeSmoothing.simplify(times: times, points: v, tolerance: 0.5) == [0, 4, 8])
        #expect(ReframeSmoothing.simplify(times: [0], points: [Vec2(1, 1)], tolerance: 1) == [0])
        #expect(ReframeSmoothing.simplify(times: [], points: [], tolerance: 1) == [])
    }

    @Test func simplifyHonoursTheTolerance() {
        let times = (0..<5).map(Double.init)
        let bump = [Vec2(0, 0), Vec2(1, 0), Vec2(2, 1), Vec2(3, 0), Vec2(4, 0)]
        #expect(ReframeSmoothing.simplify(times: times, points: bump, tolerance: 2) == [0, 4])
        #expect(ReframeSmoothing.simplify(times: times, points: bump, tolerance: 0.5).contains(2))
    }
}

@Suite struct ReframeSamplingTests {
    private let fd = Time(1, 30)

    @Test func samplesEveryFewFramesAndTheLastFrame() {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: Time(10, 1), duration: Time(2, 1)), start: Time(5, 1))
        let s = ReframeSampling.samples(for: c, frameDuration: fd, interval: 0.2)
        #expect(s.first == ReframeSample(local: .zero, source: Time(10, 1)))
        #expect(s[1].local == Time(6, 30) && s[1].source == Time(10, 1) + Time(6, 30))
        #expect(s.last!.local == Time(59, 30))
        #expect(s.count == 11)     // 0, 6, ..., 54 and 59
        #expect(zip(s, s.dropFirst()).allSatisfy { $0.local < $1.local })
    }

    @Test func shortClipStillGetsASample() {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 30)), start: .zero)
        #expect(ReframeSampling.samples(for: c, frameDuration: fd, interval: 0.2) == [ReframeSample(local: .zero, source: .zero)])
    }

    @Test func intervalBelowOneFrameSamplesEveryFrame() {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 30)), start: .zero)
        #expect(ReframeSampling.samples(for: c, frameDuration: fd, interval: 0.001).count == 5)
    }

    @Test func followsTheClipSpeed() {
        var c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.speed = ClipSpeed(num: 2, den: 1)
        let s = ReframeSampling.samples(for: c, frameDuration: fd, interval: 0.2)
        #expect(s[1].local == Time(6, 30) && s[1].source == Time(12, 30))
    }
}

@Suite struct ReframePlannerTests {
    private func detections(_ points: [Vec2?], step: Time = Time(6, 30)) -> [FrameDetections] {
        points.enumerated().map { i, p in FrameDetections(time: step * Int64(i), boxes: p.map { [face($0.x, $0.y)] } ?? []) }
    }

    @Test func nothingDetectedGivesNoPlan() {
        #expect(ReframePlanner.plan(detections: detections([nil, nil, nil]), geometry: landscapeToPortrait) == nil)
        #expect(ReframePlanner.plan(detections: [], geometry: landscapeToPortrait) == nil)
    }

    @Test func stillSubjectGivesAStaticPosition() throws {
        let plan = try #require(ReframePlanner.plan(detections: detections(Array(repeating: Vec2(0.7, 0.5), count: 20)),
                                                    geometry: landscapeToPortrait))
        #expect(!plan.position.isAnimated)
        #expect(near(plan.position.value, landscapeToPortrait.position(centering: Vec2(0.7, 0.5)), 1e-6))
        #expect(near(plan.scale, landscapeToPortrait.scale))
        #expect(plan.detectedSamples == 20 && plan.samples == 20)
    }

    @Test func jitterInsideTheDeadZoneDoesNotAnimate() throws {
        let jitter = (0..<30).map { i in Vec2(0.6 + (i % 2 == 0 ? 0.004 : -0.004), 0.5) }
        let plan = try #require(ReframePlanner.plan(detections: detections(jitter), geometry: landscapeToPortrait))
        #expect(!plan.position.isAnimated)
    }

    @Test func movingSubjectIsFollowedWithFewSmoothKeys() throws {
        // Subject walks from 30 % to 70 % of the width over 40 samples (8 s).
        let walk = (0..<40).map { Vec2(0.3 + 0.4 * Double($0) / 39, 0.5) }
        let plan = try #require(ReframePlanner.plan(detections: detections(walk), geometry: landscapeToPortrait))
        let keys = plan.position.track.keys
        #expect(plan.position.isAnimated)
        #expect(keys.count >= 2 && keys.count < 20)
        #expect(keys.first!.time == .zero && keys.last!.time == Time(6, 30) * 39)
        // The picture moves left as the subject walks right; never leaves the clamp.
        #expect(keys.first!.value.x > keys.last!.value.x)
        for k in keys { #expect(abs(k.value.x) <= landscapeToPortrait.maxOffset.x + 1e-9 && k.value.y == 0) }
        for (a, b) in zip(keys, keys.dropFirst()) { #expect(b.value.x <= a.value.x + 1e-9) }
        // The camera keeps the subject in frame: at the end it is within the dead zone of the target.
        let target = landscapeToPortrait.position(centering: walk.last!)
        #expect(abs(keys.last!.value.x - target.x) <= ReframeOptions().deadZone * 1080 + 1)
    }

    @Test func missingDetectionsHoldTheCamera() throws {
        let pts: [Vec2?] = [Vec2(0.7, 0.5)] + Array(repeating: nil, count: 10)
        let plan = try #require(ReframePlanner.plan(detections: detections(pts), geometry: landscapeToPortrait))
        #expect(!plan.position.isAnimated)
        #expect(plan.detectedSamples == 1 && plan.samples == 11)
    }

    @Test func keysAreSortedOnSampleTimes() throws {
        let walk = (0..<20).map { Vec2($0 < 10 ? 0.2 : 0.8, 0.5) }
        let plan = try #require(ReframePlanner.plan(detections: detections(walk), geometry: landscapeToPortrait))
        let times = Set(detections(walk).map(\.time))
        for k in plan.position.track.keys { #expect(times.contains(k.time)) }
        #expect(plan.position.value == plan.position.track.keys.first!.value)
    }
}

/// Scripted detector: boxes per source time.
private actor FakeDetector: SubjectDetecting {
    var calls: [Time] = []
    let script: @Sendable (Time) -> [SubjectBox]
    init(_ script: @escaping @Sendable (Time) -> [SubjectBox]) { self.script = script }
    func subjects(atSourceTime t: Time) async throws -> [SubjectBox] { calls.append(t); return script(t) }
}

@Suite struct ReframeAnalyzerTests {
    @Test func detectsEverySampleInOrderAndReportsProgress() async throws {
        let samples = (0..<5).map { ReframeSample(local: Time(Int64($0), 10), source: Time(Int64($0) + 100, 10)) }
        let fake = FakeDetector { t in t == Time(102, 10) ? [] : [face(0.5, 0.5)] }
        let progress = ProgressBox()
        let out = try await ReframeAnalyzer.detect(samples: samples, using: fake) { progress.add($0) }
        #expect(out.map(\.time) == samples.map(\.local))
        #expect(out[2].boxes.isEmpty && out[0].boxes.count == 1)
        #expect(await fake.calls == samples.map(\.source))
        #expect(progress.values.last == 1)
    }

    @Test func cancellationStops() async {
        let samples = (0..<50).map { ReframeSample(local: Time(Int64($0), 10), source: Time(Int64($0), 10)) }
        let fake = FakeDetector { _ in [] }
        let task = Task { try await ReframeAnalyzer.detect(samples: samples, using: fake) }
        task.cancel()
        let r = await task.result
        #expect(throws: CancellationError.self) { try r.get() }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double] = []
    func add(_ x: Double) { lock.withLock { v.append(x) } }
    var values: [Double] { lock.withLock { v } }
}

@Suite struct ReframeSheetOptionsTests {
    @Test func defaultsAreUnchanged() {
        #expect(ReframeOptions(smoothness: .steady, tightness: .fill) == ReframeOptions())
    }

    @Test func smoothnessWidensTheWindowAndTightnessZooms() {
        let quick = ReframeOptions(smoothness: .quick, tightness: .fill), smooth = ReframeOptions(smoothness: .smooth, tightness: .tight)
        #expect(quick.smoothingWindow < ReframeOptions().smoothingWindow)
        #expect(smooth.smoothingWindow > ReframeOptions().smoothingWindow && smooth.deadZone > ReframeOptions().deadZone)
        #expect(smooth.zoom > ReframeOptions(smoothness: .smooth, tightness: .closer).zoom)
        #expect(ReframeOptions(smoothness: .steady, tightness: .closer).zoom > 1)
    }
}
