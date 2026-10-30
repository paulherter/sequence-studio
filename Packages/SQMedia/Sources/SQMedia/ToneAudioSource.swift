import Foundation
import SQCore

/// The sound of a Tone generator clip (`ToneSpec`): an endless mono sine at the mixer rate. Pure function of the source
/// frame, so any split of a read into blocks, a seek or a reversed read gives identical samples and the phase never jumps.
public final class ToneAudioSource: AudioSource {
    public let spec: ToneSpec
    public let sampleRate: Int
    public var isMono: Bool { true }
    private let amplitude: Double

    public init(_ spec: ToneSpec, sampleRate: Int = 48_000) {
        self.spec = spec; self.sampleRate = sampleRate; amplitude = spec.amplitude
    }

    /// The tone behind a media ID, nil when the ID is an ordinary media UUID.
    public static func source(for media: UUID, sampleRate: Int = 48_000) -> ToneAudioSource? {
        ToneSpec(mediaID: media).map { ToneAudioSource($0, sampleRate: sampleRate) }
    }

    /// Sample at `frame`. The phase is computed in integers (millihertz x frame modulo one cycle), so it stays exact for hours.
    public func sample(at frame: Int64) -> Float {
        let cycle = Int64(sampleRate) * 1000
        let phase = Int64((Int128(spec.frequencyMilliHz) * Int128(frame)) % Int128(cycle))
        let p = phase < 0 ? phase + cycle : phase
        return Float(amplitude * sin(2 * Double.pi * Double(p) / Double(cycle)))
    }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard count > 0 else { return 0 }
        for k in 0..<count { buffer[k] = sample(at: sourceFrame + Int64(k)) }
        return count
    }
}
