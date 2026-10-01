import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI

@MainActor
private func makeModel(_ n: Int = 3) -> ExportDialogModel {
    let items = (1...n).map {
        ExportDialogModel.SequenceItem(name: "Seq \($0)", duration: Time(seconds: 10),
                                       inOut: $0 == 2 ? TimeRange(start: Time(seconds: 2), duration: Time(seconds: 4)) : nil)
    }
    return ExportDialogModel(sequences: items) { _, _ in
        throw CancellationError()
    }
}

@MainActor @Suite struct ExportDialogModelTests {
    @Test func defaultsToTikTokH264AndFirstSelected() {
        let m = makeModel()
        #expect(m.settings == ExportPreset.default.settings)
        #expect(m.presetID == ExportPreset.default.id)
        #expect(m.checkedIDs.count == 1)
        #expect(m.selectedID == m.sequences[0].id)
    }

    @Test func presetSelectionAppliesSettings() {
        let m = makeModel()
        m.presetID = ExportPreset.preset(.reels, .hevc).id
        #expect(m.settings == ExportPreset.preset(.reels, .hevc).settings)
        #expect(m.codec == .hevc)
    }

    @Test func detailEditsSwitchToCustom() {
        let m = makeModel()
        m.codec = .hevc
        #expect(m.presetID == ExportDialogModel.customPresetID)
        m.fps = 60
        #expect(m.settings.video.frameDuration == Time(1, 60))
        m.bitrateMbps = 20
        #expect(m.settings.video.bitrate.averageBitsPerSecond == 20_000_000)
        #expect(m.settings.video.bitrate.maxBitsPerSecond == 30_000_000)
    }

    @Test func fractionalFps() {
        let m = makeModel()
        m.fps = 29.97
        #expect(m.settings.video.frameDuration == Time(1001, 30000))
        #expect(abs(m.fps - 29.97) < 0.01)
    }

    @Test func settingsArePerSequence() {
        let m = makeModel()
        m.codec = .hevc
        m.selectedID = m.sequences[1].id
        #expect(m.codec == .h264)
        m.selectedID = m.sequences[0].id
        #expect(m.codec == .hevc)
    }

    @Test func loudnessAndCaptions() {
        let m = makeModel()
        #expect(!m.normalizeLoudness)
        m.normalizeLoudness = true
        #expect(m.settings.audio.loudnessTarget == -14)
        m.normalizeLoudness = false
        #expect(m.settings.audio.loudnessTarget == nil)
        m.captions = .sidecarSRT
        #expect(m.settings.captions == .sidecarSRT)
    }

    @Test func rangeInOut() {
        let m = makeModel()
        #expect(!m.canUseInOut)
        m.useInOut = true   // ignored without In/Out
        #expect(m.settings.range == .entireSequence)
        m.selectedID = m.sequences[1].id
        #expect(m.canUseInOut)
        m.useInOut = true
        #expect(m.settings.range == .inOut(TimeRange(start: Time(seconds: 2), duration: Time(seconds: 4))))
        #expect(m.effectiveDuration(of: m.sequences[1].id) == Time(seconds: 4))
        m.useInOut = false
        #expect(m.effectiveDuration(of: m.sequences[1].id) == Time(seconds: 10))
    }

    @Test func validationMessages() {
        let m = makeModel()
        #expect(m.validationMessages.isEmpty)
        m.width = 1081
        #expect(m.validationMessages.contains { $0.contains("even") })
        m.width = 1080
        m.bitrateMbps = 0
        #expect(m.validationMessages.contains { $0.lowercased().contains("bitrate") })
        #expect(!m.canExport)
        m.bitrateMbps = 10
        #expect(m.canExport)
        m.checkedIDs = []
        #expect(!m.canExport)
        #expect(m.validationMessages.contains { $0.contains("Select at least one") })
    }

    @Test func sizeEstimate() {
        let m = makeModel()
        // 12 Mbit/s video + 192 kbit/s audio over 10 s
        #expect(m.estimatedBytes == 15_240_000)
        #expect(m.estimatedSizeText.isEmpty == false)
        m.checkedIDs = Set(m.sequences.map(\.id))
        #expect(m.estimatedBytes == 15_240_000 * 3)
    }

    @Test func buildsOneJobPerCheckedSequenceInOrder() {
        let m = makeModel()
        m.checkedIDs = [m.sequences[0].id, m.sequences[2].id]
        m.selectedID = m.sequences[2].id
        m.codec = .hevc
        let dir = URL(fileURLWithPath: "/tmp/out")
        let jobs = m.buildJobs(outputDirectory: dir)
        #expect(jobs.map(\.name) == ["Seq 1", "Seq 3"])
        #expect(jobs[0].settings.video.codec == .h264)
        #expect(jobs[1].settings.video.codec == .hevc)
        #expect(jobs.allSatisfy { $0.outputDirectory == dir })
    }

    @Test func jobSourcesCallInjectedClosure() async throws {
        actor Box { var ids: [UUID] = []; func add(_ i: UUID) { ids.append(i) } }
        let box = Box()
        let item = ExportDialogModel.SequenceItem(name: "A", duration: Time(seconds: 1))
        let m = ExportDialogModel(sequences: [item]) { id, _ in await box.add(id); throw CancellationError() }
        let job = m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp"))[0]
        _ = try? await job.makeSources()
        #expect(await box.ids == [item.id])
    }

    @Test func submitEnqueuesWithoutRunning() async {
        let m = makeModel(2)
        m.checkedIDs = Set(m.sequences.map(\.id))
        let queue = ExportQueue()
        let ids = await m.submit(to: queue, outputDirectory: FileManager.default.temporaryDirectory, run: false)
        #expect(ids.count == 2)
        #expect(await queue.allStatuses().count == 2)
    }
}

@MainActor @Suite struct ExportQueueModelTests {
    private func status(_ id: UUID, _ state: ExportJobState, _ p: Double = 0) -> ExportQueueModel.Row {
        ExportQueueModel.Row(id: id, name: "n", state: state, progress: p, outputURL: URL(fileURLWithPath: "/tmp/n.mp4"))
    }

    @Test func applyUpsertsKeepingOrder() {
        let m = ExportQueueModel(queue: ExportQueue())
        let a = UUID(), b = UUID()
        m.apply(status(a, .waiting)); m.apply(status(b, .waiting))
        m.apply(status(a, .running, 0.5))
        #expect(m.jobs.map(\.id) == [a, b])
        #expect(m.jobs[0].progress == 0.5)
    }

    @Test func aggregateProgressAndActiveCount() {
        let m = ExportQueueModel(queue: ExportQueue())
        let a = UUID(), b = UUID()
        m.apply(status(a, .done(URL(fileURLWithPath: "/tmp/n.mp4")), 1))
        m.apply(status(b, .running, 0.5))
        #expect(m.activeCount == 1)
        #expect(abs(m.overallProgress - 0.75) < 1e-9)
        #expect(m.hasActiveJobs)
    }

    @Test func clearFinishedRemovesTerminalJobs() {
        let m = ExportQueueModel(queue: ExportQueue())
        let a = UUID(), b = UUID(), c = UUID()
        m.apply(status(a, .done(URL(fileURLWithPath: "/tmp/n.mp4")), 1))
        m.apply(status(b, .failed("x"))); m.apply(status(c, .waiting))
        m.clearFinished()
        #expect(m.jobs.map(\.id) == [c])
    }

    @Test func receivesLiveUpdatesFromQueue() async throws {
        let queue = ExportQueue()
        let m = ExportQueueModel(queue: queue)
        m.start()
        try await Task.sleep(for: .milliseconds(50))
        let job = ExportJob(name: "Fail", settings: ExportPreset.default.settings,
                            outputDirectory: FileManager.default.temporaryDirectory) { throw CancellationError() }
        await queue.enqueue(job)
        await queue.runAll()
        for _ in 0..<100 where !(m.jobs.first?.state == .cancelled) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.jobs.count == 1)
        #expect(m.jobs.first?.state == .cancelled)
        m.stop()
    }

    @Test func stateDescriptions() {
        #expect(ExportQueueModel.stateText(.waiting) == "Waiting")
        #expect(ExportQueueModel.stateText(.running) == "Exporting")
        #expect(ExportQueueModel.stateText(.cancelled) == "Stopped")
        #expect(ExportQueueModel.stateText(.failed("Disk full")) == "Failed: Disk full")
        #expect(ExportQueueModel.stateText(.done(URL(fileURLWithPath: "/a.mp4"))) == "Done")
    }
}
