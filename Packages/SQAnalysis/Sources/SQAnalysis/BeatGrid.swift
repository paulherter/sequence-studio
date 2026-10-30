import Foundation
import SQCore

/// Beats and downbeats of a piece of music, for cut-to-beat and snapping.
/// `beats` are ascending; `downbeatBeatIndices` index into `beats` (every `beatsPerBar`-th beat from the detected bar phase).
public struct BeatGrid: Sendable, Equatable {
    public var beats: [Time]
    public var downbeatBeatIndices: [Int]
    public var beatsPerBar: Int
    /// Estimated tempo in beats per minute (informational; the beat times are the truth, they follow tempo drift).
    public var bpm: Double
    public init(beats: [Time], downbeatBeatIndices: [Int], beatsPerBar: Int, bpm: Double) {
        self.beats = beats; self.downbeatBeatIndices = downbeatBeatIndices
        self.beatsPerBar = beatsPerBar; self.bpm = bpm
    }
    public var downbeats: [Time] { downbeatBeatIndices.map { beats[$0] } }
}
