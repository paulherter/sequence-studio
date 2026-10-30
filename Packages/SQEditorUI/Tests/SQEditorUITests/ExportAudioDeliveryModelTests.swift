import CoreVideo
import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI

@MainActor @Suite struct ExportAudioDeliveryModelTests {
    private func model(target: DeliveryTarget? = nil, unsynced: Int = 0,
                       audio: (any AudioSource)? = nil) -> ExportDialogModel {
        let item = ExportDialogModel.SequenceItem(name: "Seq", duration: Time(seconds: 4),
                                                  format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                                                  deliveryTarget: target, unsyncedAudioClips: unsynced)
        return ExportDialogModel(sequences: [item], initialPreset: nil) { _, _ in
            ExportSources(video: TestFrames(), audio: audio)
        }
    }

    private struct TestFrames: FrameSource {
        let width = 64, height = 64, frameCount = 1, frameDuration = Time(1, 30)
        func frame(at index: Int) async throws -> CVPixelBuffer { throw CancellationError() }
    }

    @Test func audioOnlyPresetShowsAsAudioOnlyOutput() {
        let m = model()
        m.presetID = ExportPreset.audioM4A.id
        #expect(m.settings.audioOnly == .m4a)
        #expect(m.fileExtension == "m4a")
        #expect(m.formatLabel(m.selectedFormat) == "Audio only · M4A")
        #expect(m.outputRows.first?.sizeText == "M4A")
        #expect(m.canExport)
    }

    @Test func switchingToAudioOnlyDropsBurnIn() {
        let m = model()
        #expect(m.captions == .burnIn)
        m.presetID = ExportPreset.audioWAV.id
        #expect(m.captions == .none)
        let jobs = m.buildJobs(outputDirectory: FileManager.default.temporaryDirectory)
        #expect(jobs.first?.settings.audioOnly == .wav && jobs.first?.settings.coverImage == nil)
    }

    @Test func preferencesRestoreChoicesAndKeepDeliveryTarget() {
        var s = ExportPreset.youtube1080.settings
        s.captions = .sidecarSRT; s.coverImage = .jpg
        s.audio.loudness = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)
        let p = ExportPreferences(presetID: ExportPreset.youtube1080.id, settings: s)

        let plain = model()
        plain.applyPreferences(p)
        #expect(plain.presetID == ExportPreset.youtube1080.id)
        #expect(plain.captions == .sidecarSRT && plain.coverImage == .jpg && plain.normalizeLoudness)

        // A sequence with its own platform keeps that preset and loudness target.
        let tiktok = model(target: DeliveryTarget(platform: .tiktok))
        tiktok.applyPreferences(p)
        #expect(tiktok.presetID == ExportPreset.preset(.tiktok, .h264).id)
        #expect(tiktok.captions == .sidecarSRT && tiktok.normalizeLoudness)
    }

    @Test func preferencesOfTheModelRoundTrip() {
        let m = model()
        m.presetID = ExportPreset.audioM4A.id
        m.captions = .sidecarSRT
        let other = model()
        other.applyPreferences(m.preferences)
        #expect(other.settings.audioOnly == .m4a && other.captions == .sidecarSRT)
    }

    @Test func audioCheckJudgesTheMixAndWarnsAboutUnsyncedClips() async throws {
        let quiet = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(2, 1), amplitude: 0.05)
        let m = model(unsynced: 2, audio: quiet)
        #expect(m.audioFindings.isEmpty && !m.hasAudioCheck)
        m.runAudioCheck()
        for _ in 0..<100 where !m.hasAudioCheck { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(m.hasAudioCheck)
        let f = m.audioFindings
        #expect(f.first { $0.kind == .unsynced }?.severity == .warning)
        // Not normalizing: a quiet mix is off the -14 LUFS target.
        #expect(f.first { $0.kind == .loudness }?.severity == .fail)
        m.normalizeLoudness = true
        #expect(m.audioFindings.first { $0.kind == .loudness }?.severity == .pass)
        // Another range invalidates the result.
        m.rangeMode = 2
        #expect(!m.hasAudioCheck)
    }
}
