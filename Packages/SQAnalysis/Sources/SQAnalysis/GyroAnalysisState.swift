import Foundation

// Portable (Windows too): the Stabilizer's Analyze row reads it on every platform; the engine is Mac-only.

/// Where the engine is with one clip file and one set of options (shown in the Stabilizer's Analyze row).
public enum GyroAnalysisState: Sendable, Equatable {
    /// Nothing asked for yet.
    case idle
    /// Reading the gyro data / smoothing, 0...1.
    case analysing(Double)
    case ready
    case failed(String)
}
