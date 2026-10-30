import CoreVideo
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

private let webm = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SequenceStudio/TestMedia/sample-vp9-vorbis.webm")

/// The dispatch queue labels a piece of work ran on. A lane's threads carry the lane's label; a thread of Swift's
/// cooperative pool carries the pool's.
private final class Threads: Sendable {
    private let seen = Mutex<[String]>([])
    func mark() { let l = String(cString: __dispatch_queue_get_label(nil)); seen.withLock { $0.append(l) } }
    var labels: [String] { seen.withLock { $0 } }
}

private struct MarkingSegmenter: InstanceSegmenting {
    let threads: Threads
    func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
        threads.mark()
        return try MagicMaskTests.PatchSegmenter().segment(pb)
    }
}

private struct MarkingDetector: PersonDetecting {
    let threads: Threads
    func detect(_ pb: CVPixelBuffer, bodies: Bool) throws -> (bodies: [AnonymizeBox], faces: [AnonymizeFace]) {
        threads.mark()
        return ([], [])
    }
}

/// Blocking Vision calls reached from `async` code run on a lane's own threads, never on the cooperative pool: with one
/// pool thread per core, enough callers inside `VNImageRequestHandler.perform` at once leave no thread for any other
/// task (2026-10-08: 10 of 10 pool threads inside Vision). Proven by the queue the work ran on, not by timing.
extension VisionSuites {
@Suite struct VisionOffThePoolTests {
    private static let frames = "sq.lane.frames", analysis = "sq.lane.analysis"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func theStabilizerRegistersWebMFramesOnTheAnalysisLane() async throws {
        let threads = Threads()
        let a = try await VisionStabilizationAnalyzer(url: webm, cache: nil)
            .analyze(sourceRange: TimeRange(start: .zero, duration: Time(1, 1)), pictureWidth: 640, pictureHeight: 360) { p in
                if p < 1 { threads.mark() }       // per frame, from the thread that registered it (1 = `finish`)
            }
        #expect(a.frameTimes.count > 5)
        #expect(threads.labels.count > 5)
        #expect(threads.labels.allSatisfy { $0 == Self.analysis }, "ran on \(Set(threads.labels))")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func aCanceledWebMAnalysisEnds() async throws {
        // The first frame's registration waits (on its own thread) until the task is canceled: the pass must end there,
        // whatever the machine's speed.
        let started = Threads()
        let canceled = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await VisionStabilizationAnalyzer(url: webm, cache: nil)
                .analyze(sourceRange: TimeRange(start: .zero, duration: Time(4, 1)), pictureWidth: 640, pictureHeight: 360) { _ in
                    if started.labels.isEmpty { started.mark(); _ = canceled.wait(timeout: .now() + 60) }
                }
        }
        for _ in 0..<SQTiming.polls(2_000) where started.labels.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        canceled.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func subjectDetectionOfAWebMFrameRunsOnTheFrameLane() async throws {
        let threads = Threads()
        try await VisionSubjectDetector.$onDetect.withValue({ threads.mark() }) {
            _ = try await VisionSubjectDetector(url: webm).subjects(atSourceTime: Time(1, 2))
        }
        #expect(threads.labels == [Self.frames])
    }

    @Test func subjectDetectionOfAMovieFrameRunsOnTheFrameLane() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        for fields in [FieldOrder?.none, .topFirst] {       // the image generator's frame and the deinterlaced one
            let threads = Threads()
            try await VisionSubjectDetector.$onDetect.withValue({ threads.mark() }) {
                _ = try await VisionSubjectDetector(url: url, maxDimension: 320, deinterlace: fields).subjects(atSourceTime: Time(1, 2))
            }
            #expect(threads.labels == [Self.frames], "deinterlace \(String(describing: fields))")
        }
    }

    @Test func aCanceledSubjectDetectionMakesNoVisionRequest() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let threads = Threads()
        let task = Task.detached {
            try await VisionSubjectDetector.$onDetect.withValue({ threads.mark() }) {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await VisionSubjectDetector(url: url, maxDimension: 320).subjects(atSourceTime: Time(1, 2))
            }
        }
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(threads.labels.isEmpty)
    }

    @Test func peopleAreSearchedOnTheFrameLane() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let threads = Threads()
        let a = Anonymizer(url: url, limits: .current, segmenter: MarkingSegmenter(threads: threads),
                           detector: MarkingDetector(threads: threads))
        let found = try #require(try await a.findPeople(at: 0.52))
        #expect(abs(found.pts - 0.5) < 1e-3)
        #expect(threads.labels == [Self.frames, Self.frames])       // the segmentation and the detection
    }
}
}
