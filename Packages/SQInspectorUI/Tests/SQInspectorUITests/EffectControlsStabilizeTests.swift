import Foundation
import Observation
import Synchronization
import Testing
import SQAnalysis
import SQCore
@testable import SQInspectorUI

/// Stabilize as an effect: Method row, the Analyze row under it, and only the chosen method's parameter rows.
@MainActor @Suite struct EffectControlsStabilizeTests {
    func rig(method: StabilizerMethod = .standard) -> (EffectControlsModel, Clip, ClipEffect.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.stabilizeKind)!
        if method != .standard { clip.setParameter(id, ClipEffect.stabilizeMethodKey, to: Double(method.rawValue)) }
        let m = EffectControlsModel()
        m.setClip(clip)
        return (m, clip, id)
    }

    private func keys(_ rows: [EffectRow], _ id: ClipEffect.ID) -> [String] {
        rows.compactMap { if case .property(.fx(id, _, let key)) = $0.kind { key } else { nil } }
    }

    @Test func standardShowsMethodAnalyzeThenItsOwnRows() {
        let (m, _, id) = rig()
        #expect(m.stabilizerMethods == [id: .standard])
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], stabilizers: m.stabilizerMethods)
        #expect(keys(rows, id) == StabilizerMethod.standard.visibleKeys)
        // The Analyze row sits right under Method.
        let methodRow = rows.firstIndex { $0.kind == .property(.fx(id, kind: ClipEffect.stabilizeKind, key: ClipEffect.stabilizeMethodKey)) }!
        #expect(rows[methodRow + 1].kind == .stabilizeAnalyze(id))
        // Rows are contiguous; a section starts one section gap below the one before it.
        for (a, b) in zip(rows, rows.dropFirst()) {
            var gap: CGFloat = 0
            if case .section = b.kind { gap = ControlsMetrics.sectionGap }
            #expect(a.y + a.height + gap == b.y)
        }
    }

    @Test func gyroflowShowsItsOwnRows() {
        let (m, _, id) = rig(method: .gyroflow)
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], stabilizers: m.stabilizerMethods)
        #expect(keys(rows, id) == StabilizerMethod.gyroflow.visibleKeys)
        #expect(rows.contains { $0.kind == .stabilizeAnalyze(id) })
    }

    @Test func statusFollowsTheRunAndTheAnalysis() {
        let (m, clip, id) = rig()
        #expect(m.stabilizeStatus(id) == .notAnalysed)
        m.stabilizeRun = StabilizeRunState(clips: [clip.id], progress: 0)
        #expect(m.stabilizeStatus(id) == .working(EffectControlsModel.startingText))
        m.stabilizeRun = StabilizeRunState(clips: [clip.id], progress: 0.42)
        #expect(m.stabilizeStatus(id) == .analysing(0.42))
        m.stabilizeRun = StabilizeRunState(clips: [UUID()], progress: 0.1)
        #expect(m.stabilizeStatus(id) == .notAnalysed)
        m.stabilizeRun = nil
        var analysed = clip
        analysed.setParameter(id, ClipEffect.stabilizeFromKey, to: 0)
        analysed.setParameter(id, ClipEffect.stabilizeToKey, to: 10)
        m.setClip(analysed)
        #expect(m.stabilizeStatus(id) == .analysed)
    }

    @Test func gyroflowIsBlockedWithTheHostsReason() {
        let (m, clip, id) = rig(method: .gyroflow)
        #expect(m.gyroflowBlock == nil)
        m.gyroflowBlockOf = { _ in "No gyro data in this file." }
        #expect(m.gyroflowBlock == "No gyro data in this file.")
        #expect(m.stabilizeStatus(id) == .blocked("No gyro data in this file."))
        #expect(m.disabledChoices(.fx(id, kind: ClipEffect.stabilizeKind, key: ClipEffect.stabilizeMethodKey)) == [1: "No gyro data in this file."])
        #expect(m.disabledChoices(.opacity).isEmpty)
        _ = clip
    }

    @Test func gyroflowStatusFollowsTheEngineAnalysis() {
        let (m, clip, id) = rig(method: .gyroflow)
        var state = GyroAnalysisState.idle
        var askedFor: [GyroflowOptions] = []
        m.gyroflowStateOf = { c, o in #expect(c.id == clip.id); askedFor.append(o); return state }
        #expect(m.stabilizeStatus(id) == .notAnalysed)
        #expect(askedFor.last == clip.gyroflowOptions)
        // The engine has no share while it reads the gyro data: the step is named, never a frozen "0 %".
        state = .analysing(0)
        #expect(m.stabilizeStatus(id) == .working(EffectControlsModel.gyroReadingText))
        state = .analysing(0.6)
        #expect(m.stabilizeStatus(id) == .working(EffectControlsModel.gyroSmoothingText))
        state = .ready
        #expect(m.stabilizeStatus(id) == .analysed)
        // A failure shows its reason and can be tried again (it used to disable the row).
        state = .failed("Gyroflow could not read this file.")
        #expect(m.stabilizeStatus(id) == .failed("Gyroflow could not read this file."))
        // A host block (no gyro data) wins over the engine state.
        m.gyroflowBlockOf = { _ in "No gyro data in this file." }
        state = .ready
        #expect(m.stabilizeStatus(id) == .blocked("No gyro data in this file."))
        // A Standard Stabilizer never asks the engine.
        let (s, _, sid) = rig()
        s.gyroflowStateOf = { _, _ in Issue.record("asked"); return .ready }
        #expect(s.stabilizeStatus(sid) == .notAnalysed)
    }

    @Test func analyzeAndCancelGoToTheHost() {
        let (m, clip, id) = rig()
        var asked: [Clip.ID] = []
        var cancelled = 0
        m.onStabilizeAnalyze = { asked.append($0) }
        m.onStabilizeCancel = { cancelled += 1 }
        m.analyzeOrCancelStabilizer(id)
        #expect(asked == [clip.id] && cancelled == 0)
        m.stabilizeRun = StabilizeRunState(clips: [clip.id], progress: 0.2)
        m.analyzeOrCancelStabilizer(id)
        #expect(asked == [clip.id] && cancelled == 1)
        // Blocked (Gyroflow without engine): nothing happens.
        let (g, _, gid) = rig(method: .gyroflow)
        g.gyroflowBlockOf = { _ in "not built" }
        var gAsked = 0
        g.onStabilizeAnalyze = { _ in gAsked += 1 }
        g.analyzeOrCancelStabilizer(gid)
        #expect(gAsked == 0)
    }

    /// 2026-10-07 bug: the view tracked only `stabilizeRun`, so a Gyroflow analysis (which bumps `gyroflowRevision`)
    /// never refreshed the row: it stayed at its first "0 %".
    @Test func theRowsTrackedStateIncludesTheGyroflowRevision() {
        let (m, _, _) = rig(method: .gyroflow)
        let fired = Mutex(0)
        withObservationTracking { m.observeStabilize() } onChange: { fired.withLock { $0 += 1 } }
        m.gyroflowRevision &+= 1
        #expect(fired.withLock { $0 } == 1)
        withObservationTracking { m.observeStabilize() } onChange: { fired.withLock { $0 += 1 } }
        m.stabilizeRun = StabilizeRunState(clips: [], progress: 0.5)
        #expect(fired.withLock { $0 } == 2)
    }

    @Test func cancelOnAGyroflowRowStopsTheEngineNotThePictureRun() {
        let (m, clip, id) = rig(method: .gyroflow)
        var state = GyroAnalysisState.idle
        m.gyroflowStateOf = { _, _ in state }
        var analyzed: [Clip.ID] = [], gyroCancelled: [Clip.ID] = [], runCancelled = 0
        m.onStabilizeAnalyze = { analyzed.append($0); state = .analysing(0) }
        m.onGyroflowCancel = { c, o in
            #expect(o == clip.gyroflowOptions)
            gyroCancelled.append(c.id); state = .idle
        }
        m.onStabilizeCancel = { runCancelled += 1 }
        let rev = m.gyroflowRevision
        m.analyzeOrCancelStabilizer(id)
        #expect(analyzed == [clip.id] && m.gyroflowRevision != rev)
        #expect(m.stabilizeStatus(id).isRunning)
        m.analyzeOrCancelStabilizer(id)                  // Cancel
        #expect(gyroCancelled == [clip.id] && runCancelled == 0)
        #expect(m.stabilizeStatus(id) == .notAnalysed)
        // A failed analysis: Analyze tries again.
        state = .failed("Gyroflow could not read this file.")
        m.analyzeOrCancelStabilizer(id)
        #expect(analyzed == [clip.id, clip.id])
    }

    /// A picture analysis still running on the clip when the method is switched to Gyroflow is not shown as Gyroflow's.
    @Test func aPictureRunDoesNotShowOnAGyroflowRow() {
        let (m, clip, id) = rig(method: .gyroflow)
        m.gyroflowStateOf = { _, _ in .idle }
        m.stabilizeRun = StabilizeRunState(clips: [clip.id], progress: 0.3)
        #expect(m.stabilizeStatus(id) == .notAnalysed)
    }
}
