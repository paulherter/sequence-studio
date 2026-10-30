import Foundation
import Testing
import SQCore
import SQRender
@testable import SQEditorSession

private let fd = Time(1, 25)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ name: String, _ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), mediaDuration: s(60))
}
private func track(_ clips: [Clip]) -> Track {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func session(_ clips: [Clip]) -> EditorSession {
    EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: [track(clips)])]),
                  engine: StubProgramEngine())
}
/// A display-valued luma ramp with mild noise, scaled per channel.
private func ramp(_ scale: SIMD3<Float> = .one) -> [SIMD3<Float>] {
    var seed: UInt32 = 777
    func r() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) }
    return (0..<2400).map { i in
        let y = 0.04 + 0.9 * Float(i) / 2400
        let c = SIMD3<Float>(repeating: y) + SIMD3<Float>(0.06 * (r() - 0.5), 0.06 * (r() - 0.5), 0.06 * (r() - 0.5))
        let v = c * scale
        return SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
    }
}
private func linear(_ display: [SIMD3<Float>]) -> [SIMD3<Float>] {
    display.map { SIMD3(TransferFunctions.bt709InverseOETF($0.x), TransferFunctions.bt709InverseOETF($0.y), TransferFunctions.bt709InverseOETF($0.z)) }
}

/// Answers the captures in order: a first (settling) one and the settled one per clip.
@MainActor private final class FakeSampler: ProgramFrameSampling {
    var frames: [[SIMD3<Float>]?]
    var asked = 0
    var silent = false
    init(_ frames: [[SIMD3<Float>]?]) { self.frames = frames }
    func sampleLinear(width: Int, key: String, done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) {
        asked += 1
        guard !silent else { return }
        done(frames.isEmpty ? nil : frames.removeFirst())
    }
}
@MainActor private final class Lines {
    var jobs: [String?] = [], flashes: [String] = []
    var ui: AnalysisFlowUI { AnalysisFlowUI(setJob: { self.jobs.append($0) }, flash: { t, _ in self.flashes.append(t) }) }
}

@MainActor @Suite struct ColorMatchFlowTests {
    private func make() -> (EditorSession, Clip, Clip) {
        let a = clip("A", 0, 4), b = clip("B", 4, 4)
        let ses = session([a, b])
        ses.select(clips: [b.id], captions: [])
        return (ses, a, b)
    }

    @Test func aFlowWithoutSamplerSaysUnavailable() {
        let (ses, _, _) = make(), l = Lines()
        let flows = AnalysisFlows(session: ses, backend: nil, ui: l.ui)
        flows.requestColorMatchToClip()
        #expect(l.flashes == [AnalysisFlows.unavailable("Match Color to Clip")])
        #expect(!flows.isMatchingColor)
    }

    @Test func blockedPlanFlashesItsReason() {
        let ses = session([clip("A", 0, 4)]), l = Lines()
        let flows = AnalysisFlows(session: ses, backend: nil, ui: l.ui)
        flows.frameSampler = FakeSampler([])
        flows.requestColorMatchToClip()
        #expect(l.flashes == [EditorSession.colorMatchNoReference])
    }

    @Test func fourCapturesSolveAndWriteOneUndoStep() {
        let (ses, _, _) = make(), l = Lines()
        let flows = AnalysisFlows(session: ses, backend: nil, ui: l.ui)
        let ref = linear(ramp()), tgt = linear(ramp(SIMD3(0.7, 0.62, 0.5)))
        let sampler = FakeSampler([ref, ref, tgt, tgt])
        flows.frameSampler = sampler
        flows.requestColorMatchToClip()
        #expect(sampler.asked == 4)
        #expect(!flows.isMatchingColor)
        #expect(ses.undoName == "Match Color to Clip")
        #expect(l.flashes.last?.hasPrefix("Matched") == true)
    }

    @Test func aMissingPictureEndsTheRunWithTheReadError() {
        let (ses, _, _) = make(), l = Lines()
        let flows = AnalysisFlows(session: ses, backend: nil, ui: l.ui)
        flows.frameSampler = FakeSampler([nil])
        flows.requestColorMatchToClip()
        #expect(l.flashes == ["Could not read the clips' frames."])
        #expect(!ses.canUndo)
    }

    @Test func aCaptureThatNeverArrivesTimesOutAndFreesTheCommand() async throws {
        let (ses, _, _) = make(), l = Lines()
        let flows = AnalysisFlows(session: ses, backend: nil, ui: l.ui)
        flows.colorMatchTimeout = .milliseconds(50)
        let sampler = FakeSampler([])
        sampler.silent = true
        flows.frameSampler = sampler
        flows.requestColorMatchToClip()
        #expect(flows.isMatchingColor)
        flows.requestColorMatchToClip()      // waits for the first run
        #expect(sampler.asked == 1)
        for _ in 0..<200 where flows.isMatchingColor { try await Task.sleep(for: .milliseconds(50)) }   // loaded machines
        #expect(!flows.isMatchingColor)
        #expect(l.flashes.last == "Could not read the clips' frames.")
    }
}
