import Foundation
import Testing
import SQCore
import SQAudioFX
@testable import SQInspectorUI

@MainActor @Suite struct MultibandEditorTests {
    func rig() -> (EffectControlsModel, ClipEffect.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .audio,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.audioMultibandKind)!
        let m = EffectControlsModel()
        m.setClip(clip)
        return (m, id)
    }

    @Test func broadcastPresetAppliesAndMatches() {
        let (m, id) = rig()
        m.applyMultibandPreset(id, index: 1)
        #expect(m.multibandValue(id, ClipEffect.mbThresholdKey(1)) == -15)
        #expect(m.multibandValue(id, ClipEffect.mbGainKey(1)) == 4)
        #expect(m.multibandValue(id, ClipEffect.mbCrossoverKey(3)) == 6910)
        #expect(MultibandEditor.matchingPreset(m.multibandSnapshot(id)) == 1)
    }

    @Test func crossoverKeepsOrder() {
        let (m, id) = rig()
        m.setCrossover(id, index: 0, hz: 5000)
        let x = m.crossovers(id)
        #expect(x[0] < x[1])
    }

    @Test func layoutHasEditorRow() {
        let (m, id) = rig()
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [])
        #expect(rows.contains { if case .multiband(let r) = $0.kind { r == id } else { false } })
    }

    /// Edits the model emits: (undo name, coalescing).
    final class Log { var edits: [(String, Bool)] = [] }
    func logged(_ m: EffectControlsModel) -> Log {
        let log = Log()
        m.onEdit = { [weak m] c, name, coalescing in log.edits.append((name, coalescing)); m?.setClip(c) }
        return log
    }

    @Test func broadcastPresetCarriesPaulsLimiter() {
        let (m, id) = rig()
        let log = logged(m)
        m.applyMultibandPreset(id, index: 1)
        #expect(log.edits.count == 1)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterOnKey) == 1)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterThresholdKey) == -9)
        #expect(abs(m.multibandValue(id, ClipEffect.mbLimiterMarginKey) - (-0.1)) < 1e-9)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterAttackKey) == 4)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterReleaseKey) == 500)
    }

    @Test func everyPresetSetsTheWholeSetupSoTheLimiterDoesNotLinger() {
        let (m, id) = rig()
        m.onEdit = { [weak m] c, _, _ in m?.setClip(c) }
        m.applyMultibandPreset(id, index: 1)
        m.applyMultibandPreset(id, index: 2)                                   // a role voicing
        #expect(m.multibandValue(id, ClipEffect.mbLimiterOnKey) == 0)
        #expect(MultibandEditor.matchingPreset(m.multibandSnapshot(id)) == 2)
        m.applyMultibandPreset(id, index: 1)
        m.applyMultibandPreset(id, index: 0)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterOnKey) == 0 && m.multibandValue(id, ClipEffect.mbLimiterAttackKey) == 0)
    }

    @Test func soloAndLinkDoNotChangeThePresetButBypassDoes() {
        let (m, id) = rig()
        m.onEdit = { [weak m] c, _, _ in m?.setClip(c) }
        m.applyMultibandPreset(id, index: 1)
        m.toggleMultibandSolo(id, band: 2)
        m.setMultibandLink(id, true)
        #expect(MultibandEditor.matchingPreset(m.multibandSnapshot(id)) == 1)
        m.toggleMultibandBypass(id, band: 0)
        #expect(MultibandEditor.matchingPreset(m.multibandSnapshot(id)) == nil)
    }

    @Test func soloAndBypassToggleOneUndoStepEach() {
        let (m, id) = rig()
        let log = logged(m)
        m.toggleMultibandSolo(id, band: 1)
        #expect(m.multibandSolo(id, band: 1) && !m.multibandSolo(id, band: 0))
        m.toggleMultibandBypass(id, band: 3)
        #expect(m.multibandBypass(id, band: 3))
        m.toggleMultibandSolo(id, band: 1)
        #expect(!m.multibandSolo(id, band: 1))
        #expect(log.edits.count == 3 && log.edits.allSatisfy { !$0.1 })
    }

    @Test func linkedBandEditMovesEveryBandByTheSameDeltaInOneStep() {
        let (m, id) = rig()
        m.onEdit = { [weak m] c, _, _ in m?.setClip(c) }
        m.applyMultibandPreset(id, index: 1)                                   // thresholds -15 / -11 / -17 / -15
        let log = logged(m)
        m.setMultibandLink(id, true)
        log.edits = []
        m.setMultibandBandValue(id, key: ClipEffect.mbThresholdKey, band: 1, to: -21)
        #expect(log.edits.count == 1)
        #expect((1...4).map { m.multibandValue(id, ClipEffect.mbThresholdKey($0)) } == [-25, -21, -27, -25])
        // Clamped at the range: band 3 stops at -60, the others keep moving.
        m.setMultibandBandValue(id, key: ClipEffect.mbThresholdKey, band: 0, to: -58)
        #expect((1...4).map { m.multibandValue(id, ClipEffect.mbThresholdKey($0)) } == [-58, -54, -60, -58])
    }

    @Test func unlinkedBandEditMovesOneBand() {
        let (m, id) = rig()
        m.onEdit = { [weak m] c, _, _ in m?.setClip(c) }
        m.setMultibandBandValue(id, key: ClipEffect.mbRatioKey, band: 2, to: 6)
        #expect((1...4).map { m.multibandValue(id, ClipEffect.mbRatioKey($0)) } == [2, 2, 6, 2])
    }

    @Test func linkedDragIsOneUndoGesture() {
        let (m, id) = rig()
        let log = logged(m)
        m.setMultibandLink(id, true)
        log.edits = []
        m.beginGesture()
        m.setMultibandBandValue(id, key: ClipEffect.mbGainKey, band: 0, to: 1)
        m.setMultibandBandValue(id, key: ClipEffect.mbGainKey, band: 0, to: 3)
        m.endGesture()
        #expect(log.edits.map(\.1) == [false, true])
        #expect((1...4).map { m.multibandValue(id, ClipEffect.mbGainKey($0)) } == [3, 3, 3, 3])
    }

    @Test func setupOnlyKeysHaveNoRowsButLimiterAttackHasOne() {
        let (m, id) = rig()
        let props = m.visibleSections.flatMap(\.properties)
        #expect(!props.contains(.fx(id, kind: ClipEffect.audioMultibandKind, key: ClipEffect.mbSoloKey(1))))
        #expect(!props.contains(.fx(id, kind: ClipEffect.audioMultibandKind, key: ClipEffect.mbLinkKey)))
        #expect(props.contains(.fx(id, kind: ClipEffect.audioMultibandKind, key: ClipEffect.mbLimiterAttackKey)))
    }

    // MARK: Meters (pure display state)

    @Test func metersFollowNewReadingsAndDropWhenTheAudioStops() {
        var s = MultibandMeterDisplay()
        let r = MultibandMeterReading(sequence: 5, inputPeak: SIMD4(0.5, 0.1, 0, 0), gainReductionDB: SIMD4(3, 0, 0, 0), limiterReductionDB: 2)
        s.update(r, at: 0)
        #expect(s.isLive)
        #expect(abs(s.inputDB[0] - (-6.02)) < 0.05 && s.gainReductionDB[0] == 3 && s.limiterReductionDB == 2)
        s.update(r, at: 0.1)                                 // same block again: no new audio, bars fall
        #expect(s.inputDB[0] < -6.02 - 1 && s.isLive)
        s.update(r, at: 0.5)                                 // nothing new for longer than the stale time: no reading shown
        #expect(!s.isLive && s.gainReductionDB == [0, 0, 0, 0] && s.limiterReductionDB == 0)
        s.update(nil, at: 0.6)
        #expect(!s.isLive && s.inputDB.allSatisfy { $0 <= MeterBallistics.floorDB })
    }
}
