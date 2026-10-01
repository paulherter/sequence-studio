import CoreVideo
import Foundation
import SQCore

public enum FrameSourceError: Error, Sendable { case indexOutOfRange(Int), bufferCreationFailed(Int32) }

/// Supplies rendered video frames (BGRA, Rec.709 display-referred) for export.
public protocol FrameSource: Sendable {
    var frameCount: Int { get }
    var frameDuration: Time { get }
    func frame(at index: Int) async throws -> CVPixelBuffer
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

/// Colour bars plus a frame-counter bar, BGRA.
public struct TestPatternSource: FrameSource {
    public let width: Int, height: Int
    public let frameCount: Int
    public let frameDuration: Time

    public init(width: Int, height: Int, frameCount: Int, frameDuration: Time) {
        self.width = width; self.height = height; self.frameCount = frameCount; self.frameDuration = frameDuration
    }

    public func frame(at index: Int) async throws -> CVPixelBuffer {
        guard index >= 0, index < frameCount else { throw FrameSourceError.indexOutOfRange(index) }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { throw FrameSourceError.bufferCreationFailed(st) }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        // 7 bars (BGRA order), bottom 12% is a counter bar whose fill grows with the index.
        let bars: [(UInt8, UInt8, UInt8)] = [(235,235,235),(16,235,235),(235,235,16),(16,235,16),(235,16,235),(16,16,235),(235,16,16)]
        let counterTop = height - max(1, height / 8)
        let fill = frameCount > 0 ? width * (index + 1) / frameCount : 0
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let (b, g, r): (UInt8, UInt8, UInt8)
                if y >= counterTop { (b, g, r) = x < fill ? (255, 255, 255) : (20, 20, 20) }
                else { (b, g, r) = bars[min(6, x * 7 / max(1, width))] }
                let p = row + x * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        return buf
    }
}
