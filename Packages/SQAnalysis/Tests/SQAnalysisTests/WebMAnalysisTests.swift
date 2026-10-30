import Foundation
import SQCore
import Testing
@testable import SQAnalysis

private let webm = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SequenceStudio/TestMedia/sample-vp9-vorbis.webm")

extension VisionSuites {
@Suite struct WebMAnalysisTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func stabilizationReadsWebMFrames() async throws {
        let a = try await VisionStabilizationAnalyzer(url: webm, cache: nil)
            .analyze(sourceRange: TimeRange(start: .zero, duration: Time(1, 1)), pictureWidth: 640, pictureHeight: 360, progress: nil)
        #expect(a.frameTimes.count > 5)
        #expect(a.frameTimes.count == a.motions.count)
        #expect(zip(a.frameTimes, a.frameTimes.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func subjectDetectionReadsAWebMFrame() async throws {
        _ = try await VisionSubjectDetector(url: webm).subjects(atSourceTime: Time(1, 2))   // must not throw
    }
}
}
