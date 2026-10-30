import Foundation

/// Timeline-rate PCM access: Float32, non-interleaved, stereo, at the sample rate the source was opened with
/// (`SequenceFormat.audioSampleRate`, 48 kHz). Frame numbers are in that rate, relative to the media start.
public protocol AudioSource: Sendable {
    /// Copies up to `count` frames of `channel` (0 = left, 1 = right) starting at `sourceFrame` into `buffer`.
    /// Returns the number of frames written; fewer than `count` only at the end of the media (0 past the end).
    /// The caller zero-fills the rest. Blocking; call from the feeder thread, never from the render thread.
    func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int
    /// The media itself has one channel (it is delivered as identical left and right). Decides the pan law.
    var isMono: Bool { get }
}

extension AudioSource {
    public var isMono: Bool { false }
}

/// In-memory stereo PCM. Used for tests and for short generated sources.
public final class MemoryAudioSource: AudioSource {
    public let left: [Float], right: [Float]
    public let isMono: Bool
    public init(left: [Float], right: [Float]) { self.left = left; self.right = right; isMono = false }
    public init(mono: [Float]) { left = mono; right = mono; isMono = true }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        let data = channel == 0 ? left : right
        guard sourceFrame >= 0, sourceFrame < Int64(data.count), count > 0 else { return 0 }
        let n = min(count, data.count - Int(sourceFrame))
        data.withUnsafeBufferPointer { src in
            buffer.update(from: src.baseAddress! + Int(sourceFrame), count: n)
        }
        return n
    }
}
