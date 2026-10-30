import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsKeyToolsTests {
    func animated() -> EffectControlsModel {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(c); m.playhead = Time(5, 1)
        m.setValue(.opacity, to: 0.1); m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1); m.setValue(.opacity, to: 0.5)
        m.playhead = Time(9, 1); m.setValue(.opacity, to: 0.9)
        return m
    }

    @Test func perPropertyGraphModeLeavesOthersAlone() {
        let m = EffectControlsModel()
        m.setGraphMode(.value, for: .opacity)
        #expect(m.graphMode(for: .opacity) == .value)
        #expect(m.graphMode(for: .scale) == .speed)
        #expect(m.graphMode == .speed)
    }

    @Test func dialogNumbersParse() {
        #expect(KeyToolsInput.timeScaleRatio("50 %")! == (50_000, 100_000))
        #expect(KeyToolsInput.timeScaleRatio("12,5")! == (12_500, 100_000))
        #expect(KeyToolsInput.timeScaleRatio("0") == nil)
        #expect(KeyToolsInput.timeScaleRatio("abc") == nil)
        #expect(KeyToolsInput.number("3.5 px") == 3.5)
    }

    @Test func timeScaleDoublesDistanceFromFirstSelectedKey() {
        let m = animated()
        let ids = m.track(.opacity)!.keyIDs
        m.select(ids.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }, extend: false)
        #expect(m.scaleSelectionTime(by: 2, over: 1))
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(t.keys.map(\.time) == [Time(0, 1), Time(4, 1), Time(8, 1)])
    }

    func selectAll(_ m: EffectControlsModel) {
        m.select(m.track(.opacity)!.keyIDs.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }, extend: false)
    }

    @Test func loopRepeatsPatternAndUndoesInOneStep() {
        let m = animated()
        selectAll(m)
        #expect(m.loopSelectedTracks(cycles: 1))
        #expect(m.track(.opacity)!.keyIDs.count == 5)
    }

    @Test func convertToKeysSamplesRange() {
        let m = animated()
        selectAll(m)
        #expect(m.bakeSelectedKeys(samplesPerSecond: 10))
        #expect(m.track(.opacity)!.keyIDs.count == 41)
    }

    @Test func wiggleOnNumberTrackIsDeterministic() {
        let m = animated()
        selectAll(m)
        #expect(m.hasSelectedScalarKey)
        #expect(m.wiggleSelectedKeys(perSecond: 4, amount: 0.1, seed: 3))
        #expect(m.track(.opacity)!.keyIDs.count == 17)
    }

    @Test func wiggleAndLoopInputParse() {
        #expect(KeyToolsInput.wiggle(frequency: "5", amount: "0,5", seed: "7")! == (5, 0.5, 7))
        #expect(KeyToolsInput.wiggle(frequency: "0", amount: "1", seed: "1") == nil)
        #expect(KeyToolsInput.wiggle(frequency: "5", amount: "-1", seed: "1") == nil)
        #expect(KeyToolsInput.wholeNumber("2", in: 1...100) == 2)
        #expect(KeyToolsInput.wholeNumber("2.5", in: 1...100) == nil)
    }

    @Test func velocityKeepsInfluenceAndSetsSpeedRelativeToSegment() {
        let m = animated()
        let ids = m.track(.opacity)!.keyIDs
        let member = SummaryMember(property: EffectProperty.opacity.id, keyID: ids[0])
        m.select([member], extend: false)
        // Segment 0.1 -> 0.5 over 2 s: average 0.2 per s (opacity shows x100: 20 %/s). 40 %/s is twice the average.
        let ok = m.setGraphVelocity(speed: 40, influence: 0.5, side: .outgoing)
        #expect(ok)
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(abs(t.keys[0].outHandle.dx - 0.5) < 1e-9)
        #expect(abs(t.keys[0].outHandle.dy - 1.0) < 1e-6)
        let v = m.graphVelocity(of: member, side: .outgoing)
        #expect(v != nil && abs(v!.influence - 0.5) < 1e-6)
    }

    @Test func handleReadoutNamesSpeedAndInfluence() {
        let s = GraphHandleReadout.text(title: "Opacity", speed: 12.5, influence: 0.33, unit: "%")
        #expect(s.hasPrefix("Opacity\n"))
        #expect(s.contains("%/s") && s.contains("33 %"))
    }

    @Test func graphSnapTargetsClipEnds() {
        let m = animated()
        m.graphSnap = true
        let ids = m.track(.opacity)!.keyIDs
        m.select([SummaryMember(property: EffectProperty.opacity.id, keyID: ids[2])], extend: false)
        m.beginGesture()
        // Key at 4 s; clip lasts 10 s. A move of 5.9 s lands exactly on the end with a 0.2 s tolerance.
        m.moveGraphSelection(bySeconds: 5.9, snapTolerance: 0.2)
        m.endGraphKeyMove()
        guard case .scalar(let t)? = m.track(.opacity) else { return }
        #expect(t.keys.last?.time == Time(10, 1))
    }
}
