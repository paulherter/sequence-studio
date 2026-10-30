import Foundation
import SQAnalysis
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

// Mask tracks and Stabilizer analysis show in the background-jobs list with progress and Cancel.

private struct FakeGyroEngine: GyroStabilizationEngine {
    var availability: GyroEngineAvailability { .available }
    var running: [GyroRunningAnalysis]
    func runningAnalyses() -> [GyroRunningAnalysis] { running }
}

@MainActor
@Suite struct TrackJobSourcesTests {
    final class Flag: @unchecked Sendable { var hit = false }

    @Test func maskTrackShowsWhileRunningAndCancels() async {
        let a = MaskTrackActivity()
        let flag = Flag()
        let src = MaskTrackJobSource(activity: a) { flag.hit = true }
        #expect(await src.currentJobs().isEmpty)
        a.run = .init(mask: UUID(), forward: true)
        var jobs = await src.currentJobs()
        #expect(jobs.count == 1 && jobs[0].progress == nil)
        a.run?.percent = 40
        jobs = await src.currentJobs()
        #expect(jobs[0].progress == 0.4)
        jobs[0].cancel()
        #expect(flag.hit)
    }

    @Test func gyroflowAnalysisShowsWhileRunningAndCancels() async {
        let run = GyroRunningAnalysis(path: "/m/clip.mp4", options: GyroflowOptions(), progress: 0.25)
        let flag = Flag()
        let src = GyroflowJobSource(engine: FakeGyroEngine(running: [run])) { r in flag.hit = r == run }
        let jobs = await src.currentJobs()
        #expect(jobs.count == 1 && jobs[0].progress == 0.25 && jobs[0].title.contains("clip.mp4"))
        jobs[0].cancel()
        #expect(flag.hit)
        #expect(await GyroflowJobSource(engine: FakeGyroEngine(running: [])) { _ in }.currentJobs().isEmpty)
    }
}
