import Foundation
import SSCore

public struct TranscodeOutput: Sendable, Hashable {
    public var dimensions: ProxyDimensions
    public var sourceDuration: Time
    public init(dimensions: ProxyDimensions, sourceDuration: Time) {
        self.dimensions = dimensions; self.sourceDuration = sourceDuration
    }
}

public protocol ProxyTranscoding: Sendable {
    /// Writes a proxy of `source` to `destination` (a `.partial` path; the caller moves it into place).
    /// Reports progress in 0...1. Must honor task cancellation (throw, and leave no file at `destination`).
    func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput
}
