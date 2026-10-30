import Foundation
import SQCore

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

public enum ProxyTranscodeError: Error, Equatable {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case invalidTime(String)
    /// An interlaced source whose pictures could not be deinterlaced: no proxy is written rather than a woven one.
    case deinterlaceFailed
}

extension ProxyTranscodeError: LocalizedError {
    /// English; the display sink translates through `SQL10n.errorText` (SQProxy cannot import SQUIKit).
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readerFailed(let s): "The media could not be read: \(s)"
        case .writerFailed(let s): "The proxy could not be written: \(s)"
        case .invalidTime(let s): "The time range is not valid: \(s)"
        case .deinterlaceFailed: "The interlaced pictures could not be deinterlaced, so no proxy was written."
        }
    }
}
