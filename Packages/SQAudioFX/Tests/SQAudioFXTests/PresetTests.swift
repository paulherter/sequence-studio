import Foundation
import Testing
@testable import SQAudioFX

@Suite struct PresetTests {
    @Test func builtIns() {
        let ids = TrackAudioPreset.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(TrackAudioPreset.off.compressor.bypass)
        #expect(TrackAudioPreset.off.noiseReduction == 0)
        #expect(TrackAudioPreset.voice.noiseReduction > 0)
        #expect(!TrackAudioPreset.voice.compressor.bypass)
        #expect(TrackAudioPreset.voice.compressor.bands.count == 4)
        #expect(TrackAudioPreset.voice.compressor.crossoversHz.count == 3)
    }

    @Test func denoiseMixDefaultsToHalf() {
        let p = TrackAudioPreset(id: "x", name: "x", compressor: .neutral)
        #expect(p.noiseReduction == 0.5)
        #expect(TrackAudioPreset(id: "x", name: "x", compressor: .neutral, noiseReduction: 7).noiseReduction == 1)
    }

    @Test func settingsAreValidated() {
        var s = MultibandCompressorSettings.neutral
        s.crossoversHz = [5, 10, 99999]
        let n = s.normalized(sampleRate: 48000)
        #expect(n.crossoversHz[0] >= 20 && n.crossoversHz[2] <= 24000 * 0.95)
        #expect(n.crossoversHz[0] < n.crossoversHz[1] && n.crossoversHz[1] < n.crossoversHz[2])
        s.bands[0].ratio = 0.2
        #expect(s.normalized(sampleRate: 48000).bands[0].ratio == 1)
    }

    @Test func libraryUserPresets() throws {
        var lib = PresetLibrary()
        #expect(lib.all.count == TrackAudioPreset.builtIns.count)
        var mine = TrackAudioPreset.voice
        mine.name = "Podcast"
        let saved = lib.saveUser(mine)
        #expect(!saved.isBuiltIn)
        #expect(saved.id != TrackAudioPreset.voice.id)
        #expect(lib.preset(id: saved.id)?.name == "Podcast")
        lib.rename(saved.id, to: "Podcast 2")
        #expect(lib.preset(id: saved.id)?.name == "Podcast 2")
        let data = try JSONEncoder().encode(lib)
        #expect(try JSONDecoder().decode(PresetLibrary.self, from: data) == lib)
        lib.rename(TrackAudioPreset.voice.id, to: "x")          // built-ins immutable
        #expect(lib.preset(id: TrackAudioPreset.voice.id)?.name == "Voice")
        lib.remove(saved.id); lib.remove(TrackAudioPreset.voice.id)
        #expect(lib.all.count == TrackAudioPreset.builtIns.count)
    }
}
