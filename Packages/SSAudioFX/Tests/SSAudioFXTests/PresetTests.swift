import Foundation
import Testing
@testable import SSAudioFX

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

    @Test func auParameterMapping() throws {
        var s = MultibandCompressorSettings.neutral
        s.crossoversHz = [100, 800, 4000]
        s.makeupGainDB = 3
        s.preGainDB = -2
        for i in 0..<4 {
            s.bands[i].thresholdDB = -20 - Double(i)
            s.bands[i].ratio = 4
            s.bands[i].attackMs = 10
            s.bands[i].releaseMs = 100
            s.bands[i].gainDB = Double(i)
        }
        let p = Dictionary(uniqueKeysWithValues: s.auParameters().map { ($0.id, $0.value) })
        #expect(p[AUParam.pregain] == -2)
        #expect(p[AUParam.postgain] == 3)
        #expect(p[AUParam.crossover1] == 100 && p[AUParam.crossover2] == 800 && p[AUParam.crossover3] == 4000)
        #expect(p[AUParam.threshold1] == -20 && p[AUParam.threshold4] == -23)
        #expect(abs(try #require(p[AUParam.headroom1]) - 18) < 1e-9)     // 24 * (1 - 1/4)
        #expect(abs(try #require(p[AUParam.attackTime]) - 0.010) < 1e-9)
        #expect(abs(try #require(p[AUParam.releaseTime]) - 0.100) < 1e-9)
        #expect(p[AUParam.eq1] == 0 && p[AUParam.eq4] == 3)
        #expect(s.auParameters().count == 19)
    }

    @Test func mappingClampsToAURanges() throws {
        var s = MultibandCompressorSettings.neutral
        s.bands[0].ratio = 1000; s.bands[0].thresholdDB = -500; s.bands[0].attackMs = 0.01
        s.bands[1].ratio = 1; s.bands[1].releaseMs = 99999; s.bands[1].gainDB = 99
        s.crossoversHz = [5, 10, 99999]
        let p = Dictionary(uniqueKeysWithValues: s.auParameters().map { ($0.id, $0.value) })
        #expect(p[AUParam.headroom1]! <= 40 && p[AUParam.headroom1]! >= 0.1)
        #expect(p[AUParam.headroom2] == 0.1)
        #expect(p[AUParam.threshold1] == -100)
        #expect(p[AUParam.eq2] == 20)
        #expect(p[AUParam.crossover1]! >= 20)
        #expect(p[AUParam.crossover3]! <= 24000)
        #expect(p[AUParam.crossover1]! < p[AUParam.crossover2]! && p[AUParam.crossover2]! < p[AUParam.crossover3]!)
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
