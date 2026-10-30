import Foundation
import SQCore
import SQMedia

/// The waveform of a tone clip: a constant signal, so the peaks are made from the spec (no file, no cache). One bucket per
/// second at a 1 kHz nominal rate, which keeps the data tiny for any clip length; the outline is a flat band at the tone's level.
public enum ToneWaveform {
    public static func data(for spec: ToneSpec, sourceEnd: Time) -> WaveformData {
        let seconds = max(Double(sourceEnd.value) / Double(sourceEnd.timescale), 1)
        let buckets = Int(seconds.rounded(.up)) + 1
        let peak = Float(pow(10, Double(spec.levelCentiDB) / 2000))
        var levels = [Float](repeating: 0, count: buckets * 2)
        for i in 0..<buckets { levels[2 * i] = -peak; levels[2 * i + 1] = peak }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: buckets * 1000, baseBucketSize: 1000, levels: [levels])
    }
}
