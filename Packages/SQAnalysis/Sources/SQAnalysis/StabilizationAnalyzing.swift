import Foundation
import SQCore

/// Measures the camera motion of a media file over a source range. `VisionStabilizationAnalyzer` is the real one; tests
/// script their own.
public protocol StabilizationAnalyzing: Sendable {
    /// `pictureWidth/Height`: the upright source picture size the motions are measured in (the clip's own frame).
    /// `progress` gets 0...1. Throws `CancellationError` when the task is canceled.
    func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int,
                 progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis
    /// The same for a Stabilizer whose Rolling Shutter option is on (`rolling`): the result must carry the per-row
    /// motion (`StabilizationAnalysis.rolling`), so a stored result from before it was measured does not do.
    func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int, rolling: Bool,
                 progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis
}

extension StabilizationAnalyzing {
    public func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int, rolling: Bool,
                        progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        try await analyze(sourceRange: sourceRange, pictureWidth: pictureWidth, pictureHeight: pictureHeight, progress: progress)
    }
}

public enum StabilizationError: Error, Sendable {
    case noVideoTrack
    case unreadable
}
