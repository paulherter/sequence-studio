import Foundation
import SQAnalysis
import SQCore
import SQEditorSession

/// The Mac's analysis commands: AVFoundation scene reading and Vision subject finding / registration (SQAnalysis). The
/// AppKit window and the shared window both hand it to `AnalysisFlows`.
struct MacAnalysisBackend: AnalysisBackend {
    var offersReframe: Bool { true }
    var offersStabilize: Bool { true }

    func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? {
        try await SceneCutAnalyzer.detect(url: url, range: range, progress: progress)
    }

    func subjectDetector(for media: MediaRef) -> (any SubjectDetecting)? {
        VisionSubjectDetector(url: URL(fileURLWithPath: media.path), deinterlace: media.info?.video?.deinterlaceFieldOrder,
                              pixelAspect: media.info?.video?.displayPixelAspect)
    }

    func stabilizationAnalyzer(for media: MediaRef) -> (any StabilizationAnalyzing)? {
        VisionStabilizationAnalyzer(url: URL(fileURLWithPath: media.path), deinterlace: media.info?.video?.deinterlaceFieldOrder)
    }
}
