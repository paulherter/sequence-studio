import Foundation
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
@Suite struct JobCenterTests {
    final class Source: BackgroundJobSource {
        var list: [BackgroundJob]
        init(_ l: [BackgroundJob]) { list = l }
        func currentJobs() async -> [BackgroundJob] { list }
    }

    private func job(_ id: String, _ p: Double?, kind: BackgroundJob.Kind = .proxy,
                     cancel: @escaping @MainActor @Sendable () -> Void = {}) -> BackgroundJob {
        BackgroundJob(id: id, kind: kind, title: id, progress: p, cancel: cancel)
    }

    @Test func refreshGathersJobsFromAllSources() async {
        let c = JobCenter()
        c.register(Source([job("a", 0.2)]))
        c.register(Source([job("b", nil, kind: .transcription)]))
        await c.refresh()
        #expect(c.jobs.map(\.id) == ["a", "b"])
        #expect(c.hasActiveJobs)
    }

    @Test func overallProgressAveragesKnownProgressAndIsNilWhenNothingRuns() async {
        let c = JobCenter()
        let s = Source([job("a", 0.2), job("b", 0.6), job("c", nil)])
        c.register(s)
        await c.refresh()
        #expect(abs((c.overallProgress ?? -1) - 0.4) < 1e-9)
        s.list = []
        await c.refresh()
        #expect(c.overallProgress == nil && !c.hasActiveJobs)
    }

    @Test func cancelCallsTheJobsClosure() async {
        final class Log: @unchecked Sendable { var ids: [String] = [] }
        let log = Log()
        let c = JobCenter()
        c.register(Source([job("a", 0.1, cancel: { log.ids.append("a") })]))
        await c.refresh()
        c.cancel("a")
        #expect(log.ids == ["a"])
        c.cancel("missing")
        #expect(log.ids == ["a"])
    }

    @Test func otherJobsExcludeExports() async {
        let c = JobCenter()
        c.register(Source([job("e", 0.5, kind: .export), job("p", 0.5)]))
        await c.refresh()
        #expect(c.otherJobs.map(\.id) == ["p"])
    }
}
