import Testing
import Foundation
@testable import SQExport

@Suite struct LoudnessDefaultsTests {
    @Test func defaultCeilingIsMinusOneDBTP() {
        #expect(LoudnessNormalization().truePeakCeilingDB == -1)
        for p in ExportPreset.all { #expect(p.loudness.truePeakCeilingDB == -1) }
    }

    @Test func platformTargets() {
        #expect(ExportPreset.preset(.tiktok, .h264).loudness.targetLUFS == -14)
        #expect(ExportPreset.preset(.reels, .hevc).loudness.targetLUFS == -14)
        #expect(ExportPreset.preset(.shorts, .h264).loudness.targetLUFS == -14)
        #expect(ExportPreset.youtube1080.loudness.targetLUFS == -14)
        #expect(ExportPreset.youtube4K.loudness.targetLUFS == -14)
        #expect(ExportPreset.proRes.loudness.targetLUFS == -23)
    }

    @Test func presetSettingsStayWithoutNormalisation() {
        #expect(ExportPreset.default.settings.audio.loudness == nil)
    }

    @Test func reportQuietSource() {
        let m = LoudnessMeasurement(integratedLUFS: -20, truePeakDB: -12)
        let r = LoudnessReport(measurement: m, settings: LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))
        #expect(r.gainDB == 6)
        #expect(r.outputLUFS == -14)
        #expect(r.outputTruePeakDB == -6)
        #expect(!r.limitedByCeiling)
    }

    @Test func reportLimitedByCeiling() {
        let m = LoudnessMeasurement(integratedLUFS: -20, truePeakDB: -4)
        let r = LoudnessReport(measurement: m, settings: LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))
        #expect(r.gainDB == 3)
        #expect(r.outputLUFS == -17)
        #expect(r.outputTruePeakDB == -1)
        #expect(r.limitedByCeiling)
        #expect(r.summary.contains("-17.0 LUFS"))
        #expect(r.summary.contains("-1.0 dBTP"))
    }

    @Test func reportSilence() {
        let m = LoudnessMeasurement(integratedLUFS: -.infinity, truePeakDB: -.infinity)
        let r = LoudnessReport(measurement: m, settings: LoudnessNormalization())
        #expect(r.gainDB == 0)
        #expect(r.summary.contains("silent"))
    }
}
