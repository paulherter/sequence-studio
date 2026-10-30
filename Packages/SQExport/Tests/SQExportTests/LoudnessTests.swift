import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct LoudnessTests {
    private func sine(_ amp: Float) -> SineAudioSource {
        SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(4, 1), frequency: 1000, amplitude: amp)
    }

    @Test(.serialized, arguments: [-14.0, -16.0, -23.0])
    func endsWithinHalfLUOfTarget(target: Double) async throws {
        let n = try await NormalizedAudioSource.make(sine(0.05), settings: LoudnessNormalization(targetLUFS: target, truePeakCeilingDB: -1))
        let m = try await LoudnessNormalizer.measure(n)
        #expect(abs(m.integratedLUFS - target) < 0.5)
        #expect(m.truePeakDB <= -1 + 0.05)
    }

    @Test func loudSourceIsAttenuated() async throws {
        let n = try await NormalizedAudioSource.make(sine(0.9), settings: LoudnessNormalization())
        #expect(n.gainDB < 0)
        let m = try await LoudnessNormalizer.measure(n)
        #expect(abs(m.integratedLUFS - -14) < 0.5)
    }

    @Test func ceilingLimitsGain() async throws {
        // amplitude 0.25 = -12 dBFS; target -14 needs about +1.7 dB, but ceiling -20 dBTP allows only -8 dB.
        let n = try await NormalizedAudioSource.make(sine(0.25), settings: LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -20))
        let m = try await LoudnessNormalizer.measure(n)
        #expect(m.truePeakDB <= -20 + 0.05)
        #expect(m.truePeakDB > -20 - 0.3)       // limited exactly by the ceiling, not more
        #expect(m.integratedLUFS < -14 - 3)     // target not reached
    }

    @Test func gainMath() {
        let s = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)
        #expect(LoudnessNormalizer.gainDB(for: .init(integratedLUFS: -20, truePeakDB: -10), settings: s) == 6)
        #expect(LoudnessNormalizer.gainDB(for: .init(integratedLUFS: -20, truePeakDB: -4), settings: s) == 3)
        #expect(LoudnessNormalizer.gainDB(for: .init(integratedLUFS: -10, truePeakDB: -0.5), settings: s) == -4)
        #expect(LoudnessNormalizer.gainDB(for: .init(integratedLUFS: -.infinity, truePeakDB: -.infinity), settings: s) == 0)
    }

    @Test func settingsRoundTripAndLegacyDecode() throws {
        var a = AudioSettings()
        a.loudness = LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -2)
        #expect(try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(a)) == a)
        #expect(LoudnessNormalization() == LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))

        let legacy = #"{"enabled":true,"codec":"aac","sampleRate":44100,"channels":2,"bitrate":128000,"loudnessTarget":-14}"#
        let d = try JSONDecoder().decode(AudioSettings.self, from: Data(legacy.utf8))
        #expect(d.sampleRate == 44_100)
        #expect(d.loudness == LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))
        let none = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"enabled":true,"codec":"aac","sampleRate":48000,"channels":2,"bitrate":192000}"#.utf8))
        #expect(none.loudness == nil)
    }

    @Test func exportAppliesNormalisation() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264)
        s.audio.enabled = true
        s.audio.loudness = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)
        let v = TestPatternSource(width: 64, height: 112, frameCount: 60, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(2, 1), frequency: 1000, amplitude: 0.05)
        try await ExportWriter.export(video: v, audio: a, settings: s, to: dir.appendingPathComponent("n.mp4"), progress: { _ in })
        // Source was rewound after measuring and fully consumed by the writer.
        #expect(try await a.nextChunk(maxFrames: 10) == nil)
    }
}
