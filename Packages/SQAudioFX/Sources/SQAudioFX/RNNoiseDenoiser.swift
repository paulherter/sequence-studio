import Foundation
import CRNNoise

/// RNNoise (Xiph/Mozilla, BSD-3-Clause) noise suppression, 48 kHz only.
///
/// Streaming, any buffer length. Output is delayed by `latencySamples` (one frame): sample n of the
/// output is sample n - 480 of the processed input, so every call returns exactly as many samples
/// as it received and the result never depends on chunking. `flush()` returns the delayed tail.
/// Not thread-safe; use one instance per stream.
public final class RNNoiseDenoiser {
    public static let sampleRate = 48000
    public static let frameSize = 480
    public static let latencySamples = 480

    /// Wet/dry: 1 = fully denoised, 0 = delayed dry signal.
    public var mix: Float = 1

    private struct Channel {
        var state: OpaquePointer
        var inFIFO: [Float] = []        // not yet processed, int16 scale
        var outFIFO: [Float]            // processed, int16 scale
        var dryOut: [Float]         // dry samples matching outFIFO positions
    }
    private var channels: [Channel]

    public init(channelCount: Int, sampleRate: Int) throws {
        guard sampleRate == Self.sampleRate else { throw AudioFXError.unsupportedSampleRate(sampleRate) }
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        channels = (0..<channelCount).map { _ in
            Channel(state: rnnoise_create(nil)!,
                    outFIFO: [Float](repeating: 0, count: Self.latencySamples),
                    dryOut: [Float](repeating: 0, count: Self.latencySamples))
        }
    }

    deinit { for c in channels { rnnoise_destroy(c.state) } }

    public var channelCount: Int { channels.count }

    /// Feeds `input` (one array per channel, +-1.0 floats) and returns the same number of samples.
    public func process(_ input: [[Float]]) -> [[Float]] {
        precondition(input.count == channels.count, "channel count mismatch")
        let n = input.first?.count ?? 0
        let mix = min(1, max(0, self.mix))
        var result: [[Float]] = []
        for c in 0..<channels.count {
            precondition(input[c].count == n, "channels must have equal length")
            feed(&channels[c], input[c])
            result.append(take(&channels[c], count: n, mix: mix))
        }
        return result
    }

    /// Returns the `latencySamples` still held back, and resets the FIFOs (pads the last partial frame with silence).
    public func flush() -> [[Float]] {
        let mix = min(1, max(0, self.mix))
        var result: [[Float]] = []
        for c in 0..<channels.count {
            let pending = channels[c].inFIFO.count
            let pad = pending % Self.frameSize == 0 ? 0 : Self.frameSize - pending % Self.frameSize
            feed(&channels[c], [Float](repeating: 0, count: pad))
            // samples owed: everything real that has not been returned yet
            let owed = channels[c].outFIFO.count - pad
            result.append(take(&channels[c], count: owed, mix: mix))
            channels[c].outFIFO.removeAll(); channels[c].dryOut.removeAll(); channels[c].inFIFO.removeAll()
        }
        return result
    }

    private func feed(_ ch: inout Channel, _ samples: [Float]) {
        let scale: Float = 32768
        ch.inFIFO.reserveCapacity(ch.inFIFO.count + samples.count)
        for s in samples { ch.inFIFO.append(s * scale) }
        let fs = Self.frameSize
        var pos = 0
        var frameOut = [Float](repeating: 0, count: fs)
        while ch.inFIFO.count - pos >= fs {
            ch.inFIFO.withUnsafeBufferPointer { src in
                frameOut.withUnsafeMutableBufferPointer { dst in
                    _ = rnnoise_process_frame(ch.state, dst.baseAddress, src.baseAddress! + pos)
                }
            }
            ch.dryOut.append(contentsOf: ch.inFIFO[pos..<pos + fs])
            ch.outFIFO.append(contentsOf: frameOut)
            pos += fs
        }
        ch.inFIFO.removeFirst(pos)
    }

    private func take(_ ch: inout Channel, count n: Int, mix: Float) -> [Float] {
        precondition(ch.outFIFO.count >= n)
        let inv: Float = 1 / 32768
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = (ch.outFIFO[i] * mix + ch.dryOut[i] * (1 - mix)) * inv }
        ch.outFIFO.removeFirst(n)
        ch.dryOut.removeFirst(n)
        return out
    }
}
