import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)

private struct FakeBackend: AnalysisBackend {
    var scene: [Time]?
    var reframe = false
    func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? {
        progress(0.5)
        return scene
    }
    var offersReframe: Bool { reframe }
    func subjectDetector(for media: MediaRef) -> (any SubjectDetecting)? { reframe ? Walker() : nil }
}

private struct Walker: SubjectDetecting {
    func subjects(atSourceTime t: Time) async throws -> [SubjectBox] {
        let x = 0.3 + 0.4 * min(max(Double(t.value) / Double(t.timescale) / 4, 0), 1)
        return [SubjectBox(kind: .face, rect: NormalizedRect(x: x - 0.05, y: 0.45, width: 0.1, height: 0.1), confidence: 0.9)]
    }
}

@MainActor private final class Lines {
    var jobs: [String?] = []
    var flashes: [String] = []
    var ui: AnalysisFlowUI { AnalysisFlowUI(setJob: { self.jobs.append($0) }, flash: { t, _ in self.flashes.append(t) }) }
}

@MainActor @Suite struct AnalysisFlowsTests {
    private func make(width: Int = 1080, height: Int = 1920) -> (EditorSession, Clip) {
        let info = MediaInfo(duration: Time(4, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
                                                                         chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false))
        let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1), info: info)
        let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var track = Track(kind: .video)
        try! track.overwrite(c)
        let t = Timeline(name: "T", format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: [track])
        return (EditorSession(project: Project(name: "P", media: [m], timelines: [t])), c)
    }

    private func until(_ ok: () -> Bool) async throws {
        for _ in 0..<500 where !ok() { try await Task.sleep(for: .milliseconds(4)) }
        #expect(ok())
    }

    @Test func sceneChangesMarkTheCutsAndClearTheJobLine() async throws {
        let (session, _) = make()
        let log = Lines()
        let flows = AnalysisFlows(session: session, backend: FakeBackend(scene: [Time(2, 1)]), ui: log.ui)
        flows.requestFindSceneChanges()
        #expect(flows.isFindingSceneChanges)
        #expect(log.jobs.first == "Find Scene Changes: reading “c”…")
        try await until { !flows.isFindingSceneChanges }
        #expect(session.activeTimeline!.proposedCuts.count == 1)
        #expect(log.jobs.last! == nil)
        #expect(log.flashes.last?.hasPrefix("1 scene change marked") == true || log.flashes.last?.contains("scene change") == true)
    }

    @Test func sceneChangesWithoutAClipOrABackendSaySo() {
        let log = Lines()
        let empty = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [Track(kind: .video)])]))
        AnalysisFlows(session: empty, backend: FakeBackend(), ui: log.ui).requestFindSceneChanges()
        #expect(log.flashes == ["Select a video clip to look through."])
        let (session, _) = make()
        let log2 = Lines()
        AnalysisFlows(session: session, backend: nil, ui: log2.ui).requestFindSceneChanges()
        #expect(log2.flashes == ["Find Scene Changes is not available on this computer yet."])
    }

    @Test func aBackendWithoutASceneDetectorEndsWithTheUnavailableLine() async throws {
        let (session, _) = make()
        let log = Lines()
        let flows = AnalysisFlows(session: session, backend: FakeBackend(scene: nil), ui: log.ui)
        flows.requestFindSceneChanges()
        try await until { !flows.isFindingSceneChanges }
        #expect(log.flashes.last == "Find Scene Changes is not available on this computer yet.")
        #expect(session.activeTimeline!.proposedCuts.isEmpty)
    }

    @Test func choosingSceneChangesAgainWhileItRunsCancelsIt() async throws {
        let (session, _) = make()
        let log = Lines()
        struct Slow: AnalysisBackend {
            func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? {
                try await Task.sleep(for: .seconds(30))
                return []
            }
        }
        let flows = AnalysisFlows(session: session, backend: Slow(), ui: log.ui)
        flows.requestFindSceneChanges()
        flows.requestFindSceneChanges()
        #expect(!flows.isFindingSceneChanges)
        #expect(log.flashes.last == "Find Scene Changes canceled.")
    }

    @Test func autoReframeNeedsABackendThatOffersIt() {
        let (session, _) = make()
        let log = Lines()
        #expect(AnalysisFlows(session: session, backend: FakeBackend(), ui: log.ui).reframeSubject() == nil)
        #expect(log.flashes == ["Auto Reframe is not available on this computer yet."])
        let ok = AnalysisFlows(session: session, backend: FakeBackend(reframe: true), ui: log.ui)
        #expect(ok.reframeSubject() == "“c”")
    }

    @Test func autoReframeWritesTheKeysAndReportsTheOutcome() async throws {
        let (session, clip) = make()
        let log = Lines()
        let flows = AnalysisFlows(session: session, backend: FakeBackend(reframe: true), ui: log.ui)
        flows.runAutoReframe(options: ReframeOptions(), what: "“c”")
        try await until { !flows.isReframing }
        let live = session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == clip.id }!
        #expect(live.effect(ofKind: ClipEffect.reframeKind) != nil)
        #expect(log.flashes.last == "Reframed 1 clip(s); the Position keys are in Effect Controls.")
    }

    @Test func stabilizeWithoutAnalyzerSaysUnavailable() {
        let (session, _) = make()
        let log = Lines()
        AnalysisFlows(session: session, backend: FakeBackend(), ui: log.ui).requestStabilize()
        #expect(log.flashes == ["Stabilize is not available on this computer yet."])
    }

    @Test func outcomeMessagesMatchTheMacWording() {
        #expect(AnalysisFlows.reframeMessage(ReframeOutcome(reframed: 0, noSubject: 0, failed: 0)) == "Nothing to reframe.")
        #expect(AnalysisFlows.stabilizeMessage(StabilizeOutcome(stabilized: 0, failed: 2)) == "2 clip(s) could not be read.")
    }

    @Test func theReframePickIsRememberedAndMapsToTheSheetOptions() {
        let d = UserDefaults(suiteName: "sq.test.reframe.\(UUID().uuidString)")!
        #expect(AnalysisFlows.rememberedReframePick(d) == (1, 0))
        let o = AnalysisFlows.reframeOptions(motion: 2, framing: 2, remember: d)
        #expect(o == ReframeOptions(smoothness: .smooth, tightness: .tight))
        #expect(AnalysisFlows.rememberedReframePick(d) == (2, 2))
        #expect(AnalysisFlows.reframeOptions(motion: 9, framing: -1, remember: d) == ReframeOptions(smoothness: .smooth, tightness: .fill))
    }
}
