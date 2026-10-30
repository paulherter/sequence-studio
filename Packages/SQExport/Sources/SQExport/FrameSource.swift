import Foundation
import SQCore
#if canImport(CoreVideo)
import CoreVideo

/// A rendered export frame. Mac: the CVPixelBuffer the encoder takes as is.
// shortcut: platform alias instead of `SQFrame` on the Mac too; switch when SQExport's `ProvidedFrame`/`FrameSource`
// move to SQFrame (WINDOWS-PLAN seam 1 "next").
public typealias ExportFrame = CVPixelBuffer
#else
import SQFrame

/// A rendered export frame. Off the Mac: the neutral `SQFrame` (CPU bytes or a GPU texture).
public typealias ExportFrame = SQFrame
#endif

public enum FrameSourceError: Error, Sendable { case indexOutOfRange(Int), bufferCreationFailed(Int32) }

/// Supplies rendered video frames (BGRA, Rec.709 display-referred) for export.
public protocol FrameSource: Sendable {
    var frameCount: Int { get }
    var frameDuration: Time { get }
    func frame(at index: Int) async throws -> ExportFrame
}

/// A frame source that can be split into independent sources over sub-ranges of its frames (W9.4 parallel segments):
/// each segment renders and decodes on its own, frame 0 of a segment is frame `range.lowerBound` of the whole.
public protocol SegmentableFrameSource: FrameSource {
    /// False when segments would share state that serializes them (then the writer exports in one piece).
    var isSegmentable: Bool { get }
    func segment(_ range: Range<Int>) throws -> any FrameSource
}

public extension SegmentableFrameSource {
    var isSegmentable: Bool { true }
}

/// Interleaved Float32 PCM.
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var channels: Int
    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
    public init(samples: [Float], channels: Int) { self.samples = samples; self.channels = channels }
}

public protocol AudioSource: Sendable {
    var sampleRate: Int { get }
    var channels: Int { get }
    /// Next chunk of at most `maxFrames` frames, or nil at the end.
    func nextChunk(maxFrames: Int) async throws -> AudioChunk?
}

/// An audio source that can be read again from the start (needed for two-pass processing).
public protocol RewindableAudioSource: AudioSource {
    func rewind() async throws
}

/// Generated sine tone (tests).
public final class SineAudioSource: RewindableAudioSource, @unchecked Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let totalFrames: Int
    private let frequency: Int
    private let amplitude: Float
    private let lock = NSLock()
    private var position = 0

    public init(sampleRate: Int, channels: Int, duration: Time, frequency: Int = 440, amplitude: Float = 0.25) {
        self.sampleRate = sampleRate; self.channels = channels; self.frequency = frequency; self.amplitude = amplitude
        self.totalFrames = Int((Int128(duration.value) * Int128(sampleRate)) / Int128(duration.timescale))
    }

    public func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        next(maxFrames)
    }

    public func rewind() async throws { reset() }
    private func reset() { lock.lock(); position = 0; lock.unlock() }

    private func next(_ maxFrames: Int) -> AudioChunk? {
        lock.lock(); defer { lock.unlock() }
        let n = min(maxFrames, totalFrames - position)
        guard n > 0 else { return nil }
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n {
            // Phase from integer arithmetic: (position * frequency) mod sampleRate.
            let phase = Double((position + i) * frequency % sampleRate) / Double(sampleRate)
            let v = Float(sin(2 * Double.pi * phase)) * amplitude
            for c in 0..<channels { out[i * channels + c] = v }
        }
        position += n
        return AudioChunk(samples: out, channels: channels)
    }
}
