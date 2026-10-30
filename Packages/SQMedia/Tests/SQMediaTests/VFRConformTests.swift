import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

@Suite struct VFRConformPlanTests {
    private let fd = Time(1, 30)

    @Test func slotIsTheNearestFrame() {
        #expect(VFRConformPlan.slot(of: .zero, frameDuration: fd) == 0)
        #expect(VFRConformPlan.slot(of: Time(1, 30), frameDuration: fd) == 1)
        let jitter = Time(3003, 30000)                                                     // 3 frames of 29.97
        #expect(VFRConformPlan.slot(of: jitter, frameDuration: fd) == 3)                  // lands on its frame
        #expect(VFRConformPlan.slot(of: Time(5, 60), frameDuration: fd) == 3)             // half a frame rounds up
        #expect(VFRConformPlan.slot(of: Time(-1, 30), frameDuration: fd) == 0)
    }

    @Test func gapRepeatsAndDenseFramesDrop() {
        // 0, 1/30, a 4-frame gap, 5.4 slots (same slot as 5: dropped), 7.
        let pts = [Time(0, 30), Time(1, 30), Time(5, 30), Time(9, 50), Time(7, 30)]
        let plan = VFRConformPlan.plan(pts: pts, end: Time(8, 30), frameDuration: fd)
        #expect(plan[0] == 0..<1)
        #expect(plan[1] == 1..<5)            // held through the gap
        #expect(plan[2] == 5..<5)            // slot 5 is taken by the later frame: dropped
        #expect(plan[3] == 5..<7)
        #expect(plan[4] == 7..<8)
        let total: Int = plan.map { Int($0.count) }.reduce(0, +)
        #expect(total == 8)   // one slot per 1/30 up to the clip end
    }

    @Test func firstFrameStartsAtZero() {
        let plan = VFRConformPlan.plan(pts: [Time(2, 30), Time(3, 30)], end: Time(4, 30), frameDuration: fd)
        #expect(plan[0] == 0..<3 && plan[1] == 3..<4)
    }
}

@Suite(.serialized) struct VFRConformFileTests {
    @Test func conformedCopyHasConstantRateAndSameLength() async throws {
        var s = TestClipSpec(); s.width = 320; s.height = 180
        var t: Int64 = 0
        let gaps: [Int64] = [100, 100, 300, 100, 1200, 100, 100, 500, 100, 100, 2000, 100, 100, 100, 700, 100]
        s.presentationTimes = gaps.map { g in defer { t += g }; return CMTime(value: t, timescale: 6000) }
        s.frameDuration = CMTime(value: 100, timescale: 6000)
        let src: URL
        do { src = try await TestClipWriter.write(s) }
        catch TestClipError.encoderUnavailable(let why) { Issue.record("encoder unavailable: \(why)"); return }
        let before = try await MediaRobustness.check(src)
        #expect(before.info.video?.isVariableFrameRate == true)

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("vfr-conform-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        let fd = Time(1, 30)
        let out = try await VFRConform.conform(source: src, destination: dest, frameDuration: fd)
        #expect(out.frameCount > 0)
        let after = try await MediaRobustness.check(dest)
        #expect(after.problems.isEmpty, "\(after.problems)")
        let v = try #require(after.info.video)
        #expect(!v.isVariableFrameRate)
        #expect(v.nominalFrameDuration == fd)
        #expect(v.width == 320 && v.height == 180)
        let length: Double = Double(after.info.duration.value) / Double(after.info.duration.timescale)
        let expected: Double = Double(out.frameCount) / 30.0
        #expect(abs(length - expected) < 0.04)
    }
}
