import Testing
import SQAudioFX
@testable import SQEditorUI

@MainActor
@Suite struct TrackAudioInspectorModelTests {
    @Test func selectsBuiltInPreset() {
        let m = TrackAudioInspectorModel()
        m.selectPreset(id: TrackAudioPreset.voice.id)
        #expect(m.compressor == TrackAudioPreset.voice.compressor)
        #expect(m.noiseReductionPercent == 80)
        #expect(!m.isModified)
        #expect(m.presets.map(\.id) == ["builtin.off", "builtin.voice", "builtin.music"])
    }

    @Test func noiseReductionClampsAndMarksModified() {
        let m = TrackAudioInspectorModel()
        m.selectPreset(id: TrackAudioPreset.voice.id)
        m.setNoiseReductionPercent(140)
        #expect(m.noiseReductionPercent == 100)
        #expect(m.isModified)
        m.setNoiseReductionPercent(-5)
        #expect(m.noiseReduction == 0)
    }

    @Test func crossoversStayOrderedAndClamped() {
        let m = TrackAudioInspectorModel()
        m.selectPreset(id: TrackAudioPreset.music.id) // 150, 1000, 6000
        m.setCrossover(0, hz: 5000)
        #expect(m.compressor.crossoversHz[0] < m.compressor.crossoversHz[1])
        #expect(m.compressor.crossoversHz[1] == 1000)
        m.setCrossover(2, hz: 10)
        #expect(m.compressor.crossoversHz[2] > m.compressor.crossoversHz[1])
        m.setCrossover(1, hz: 1_000_000)
        #expect(m.compressor.crossoversHz[1] < m.compressor.crossoversHz[2])
        m.setCrossover(0, hz: 1)
        #expect(m.compressor.crossoversHz[0] == CrossoverRules.minHz)
    }

    @Test func bandParametersClamp() {
        let m = TrackAudioInspectorModel()
        m.setBand(1) { $0.ratio = 99; $0.thresholdDB = 10; $0.attackMs = 0; $0.releaseMs = 1e6; $0.gainDB = -99 }
        let b = m.compressor.bands[1]
        #expect(b.ratio == 20 && b.thresholdDB == 0 && b.attackMs == BandLimits.attackMs.lowerBound)
        #expect(b.releaseMs == BandLimits.releaseMs.upperBound && b.gainDB == -24)
        m.setPreGainDB(50); m.setMakeupGainDB(-50)
        #expect(m.compressor.preGainDB == 24 && m.compressor.makeupGainDB == -24)
        m.setBypass(false)
        #expect(!m.compressor.bypass)
    }

    @Test func userPresetSaveRenameDelete() {
        let m = TrackAudioInspectorModel()
        m.selectPreset(id: TrackAudioPreset.voice.id)
        m.setNoiseReductionPercent(30)
        m.saveAsUserPreset(named: "Podcast")
        #expect(m.presets.count == 4)
        let id = m.selectedPresetID!
        #expect(id.hasPrefix("user."))
        #expect(!m.isModified)
        #expect(m.noiseReductionPercent == 30)
        m.renameSelectedPreset(to: "Podcast 2")
        #expect(m.presets.last?.name == "Podcast 2")
        m.deleteSelectedPreset()
        #expect(m.presets.count == 3)
        #expect(m.selectedPresetID == nil)
        #expect(m.noiseReductionPercent == 30) // values kept
    }

    @Test func builtInsCannotBeRenamedOrDeleted() {
        let m = TrackAudioInspectorModel()
        m.selectPreset(id: TrackAudioPreset.voice.id)
        #expect(!m.canEditSelectedPreset)
        m.renameSelectedPreset(to: "X")
        m.deleteSelectedPreset()
        #expect(m.presets.count == 3)
        #expect(m.selectedPresetID == TrackAudioPreset.voice.id)
    }

    @Test func discreteChangesAreBracketed() {
        let m = TrackAudioInspectorModel()
        var log: [String] = []
        m.onBeginChange = { log.append("begin") }
        m.onEndChange = { log.append("end") }
        m.onChange = { _ in log.append("change") }
        m.setBypass(false)
        #expect(log == ["begin", "change", "end"])
    }

    @Test func dragCoalescesIntoOneBracket() {
        let m = TrackAudioInspectorModel()
        var log: [String] = []
        m.onBeginChange = { log.append("begin") }
        m.onEndChange = { log.append("end") }
        m.onChange = { _ in log.append("change") }
        m.beginChange()
        m.setCrossover(0, hz: 200); m.setCrossover(0, hz: 210); m.setCrossover(0, hz: 220)
        m.endChange()
        #expect(log == ["begin", "change", "change", "change", "end"])
    }

    @Test func unchangedValueDoesNotNotify() {
        let m = TrackAudioInspectorModel()
        var n = 0
        m.onChange = { _ in n += 1 }
        m.setNoiseReductionPercent(m.noiseReductionPercent)
        #expect(n == 0)
    }
}
