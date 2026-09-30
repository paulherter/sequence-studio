import Foundation
import AVFoundation

/// RNNoise at any sample rate: converts to 48 kHz with AVAudioConverter, denoises, converts back.
///
/// `process` returns exactly as many samples as it is given. The output is delayed by `latencySamples`
/// (at the caller's rate); at 48 kHz that is the denoiser's 480 samples, otherwise it is measured once
/// at init by pushing an impulse through the whole stage, so it includes both converters.
/// Streaming-safe (state is kept between calls). Not thread-safe.
final class DenoiseStage {
    let sampleRate: Int
    let channelCount: Int
    private(set) var latencySamples: Int
    var mix: Float {
        get { denoiser.mix }
        set { denoiser.mix = newValue }
    }

    private let denoiser: RNNoiseDenoiser
    private let up: AVAudioConverter?
    private let down: AVAudioConverter?
    private var fifo: [[Float]]

    /// Zero samples queued ahead of the converter output so a short converter call never starves `process`.
    private static let safetyPad = 256

    convenience init(sampleRate: Int, channelCount: Int) throws {
        try self.init(sampleRate: sampleRate, channelCount: channelCount, calibrate: true)
    }

    private init(sampleRate: Int, channelCount: Int, calibrate: Bool) throws {
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        guard sampleRate > 0 else { throw AudioFXError.unsupportedSampleRate(sampleRate) }
        self.sampleRate = sampleRate; self.channelCount = channelCount
        denoiser = try RNNoiseDenoiser(channelCount: channelCount, sampleRate: RNNoiseDenoiser.sampleRate)
        if sampleRate == RNNoiseDenoiser.sampleRate {
            up = nil; down = nil
            fifo = []
            latencySamples = RNNoiseDenoiser.latencySamples
        } else {
            func format(_ r: Int) -> AVAudioFormat {
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(r),
                              channels: AVAudioChannelCount(channelCount), interleaved: false)!
            }
            guard let u = AVAudioConverter(from: format(sampleRate), to: format(RNNoiseDenoiser.sampleRate)),
                  let d = AVAudioConverter(from: format(RNNoiseDenoiser.sampleRate), to: format(sampleRate))
            else { throw AudioFXError.unsupportedSampleRate(sampleRate) }
            up = u; down = d
            fifo = Array(repeating: [Float](repeating: 0, count: Self.safetyPad), count: channelCount)
            latencySamples = 0
            if calibrate { latencySamples = try Self.measureLatency(sampleRate: sampleRate, channelCount: channelCount) }
        }
    }

    /// Impulse through a dry (mix 0) copy of the stage; the peak position is the latency.
    private static func measureLatency(sampleRate: Int, channelCount: Int) throws -> Int {
        let probe = try DenoiseStage(sampleRate: sampleRate, channelCount: channelCount, calibrate: false)
        probe.mix = 0
        let total = 8192
        var impulse = [Float](repeating: 0, count: total)
        impulse[0] = 1
        var out: [Float] = []
        var pos = 0
        while pos < total {
            let len = min(512, total - pos)
            out += probe.process([Array(impulse[pos..<pos + len])] + Array(repeating: [Float](repeating: 0, count: len), count: channelCount - 1))[0]
            pos += len
        }
        var best = 0, bestV: Float = 0
        for (i, v) in out.enumerated() where abs(v) > bestV { bestV = abs(v); best = i }
        return best
    }

    func process(_ input: [[Float]]) -> [[Float]] {
        precondition(input.count == channelCount, "channel count mismatch")
        let n = input.first?.count ?? 0
        guard let up, let down else { return denoiser.process(input) }
        guard n > 0 else { return input }
        let wet = denoiser.process(Self.convert(up, input, ratio: Double(RNNoiseDenoiser.sampleRate) / Double(sampleRate)))
        let back = Self.convert(down, wet, ratio: Double(sampleRate) / Double(RNNoiseDenoiser.sampleRate))
        var out: [[Float]] = []
        for c in 0..<channelCount {
            fifo[c].append(contentsOf: back[c])
            if fifo[c].count < n { fifo[c].append(contentsOf: [Float](repeating: 0, count: n - fifo[c].count)) }
            out.append(Array(fifo[c].prefix(n)))
            fifo[c].removeFirst(n)
        }
        return out
    }

    /// The `latencySamples` still inside the stage (feeds silence through it).
    func flush() -> [[Float]] {
        process(Array(repeating: [Float](repeating: 0, count: latencySamples), count: channelCount))
    }

    private static func convert(_ conv: AVAudioConverter, _ input: [[Float]], ratio: Double) -> [[Float]] {
        let n = input[0].count
        guard n > 0 else { return input }
        let inBuf = AVAudioPCMBuffer(pcmFormat: conv.inputFormat, frameCapacity: AVAudioFrameCount(n))!
        inBuf.frameLength = AVAudioFrameCount(n)
        for c in 0..<input.count { input[c].withUnsafeBufferPointer { inBuf.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
        let cap = AVAudioFrameCount(Double(n) * ratio) + 4096
        let outBuf = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap)!
        let feed = Feed(buffer: inBuf)
        var result = Array(repeating: [Float](), count: input.count)
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in feed.next(st) }
            let got = Int(outBuf.frameLength)
            for c in 0..<input.count {
                result[c].append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![c], count: got))
            }
            if status != .haveData || got == 0 { break }
        }
        return result
    }

    /// Hands the input buffer to the converter once, then reports "no data now".
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .noDataNow; return nil }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }
}
