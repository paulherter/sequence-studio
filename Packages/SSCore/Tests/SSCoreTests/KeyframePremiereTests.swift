import Foundation
import Testing
@testable import SSCore

private let opacity = PropertyID("opacity")

@Test func choiceCurvesMatchPremiereNames() {
    #expect(KeyInterpolationChoice.allCases.map(\.title) == ["Linear", "Bezier", "Ease In", "Ease Out", "Easy Ease", "Hold"])
    #expect(KeyInterpolationChoice.easeIn.side == .in)
    #expect(KeyInterpolationChoice.easeOut.side == .out)
    #expect(KeyInterpolationChoice.hold.side == .out)
    #expect(KeyInterpolationChoice.easyEase.side == .both)
}

@Test func easeInTouchesOnlyTheInHandle() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var tr = PropertyTrack.scalar(KeyframeTrack(keys: ks))
    tr.apply(KeyInterpolationChoice.easeIn.curve, to: [ks[1].id], side: .in)
    guard case .scalar(let t) = tr else { return }
    #expect(t.keys[1].inHandle.dy == 0)
    #expect(t.keys[1].outHandle == .linear)
    #expect(t.keys[0] == ks[0] && t.keys[2] == ks[2])
}

@Test func bezierChoiceStaysVisuallyLinear() {
    let ks = [kfKey(0, 0), kfKey(2, 10)]
    var tr = KeyframeTrack(keys: ks)
    tr.apply(KeyInterpolationChoice.bezier.curve, to: Set(ks.map(\.id)))
    #expect(abs(tr.value(at: kfT(1))! - 5) < 1e-6)
}

@Test func moveDuplicatingLeavesCopiesBehind() {
    let ks = [kfKey(1, 1), kfKey(3, 3)]
    var s = KeyframeSummary(tracks: [opacity: .scalar(KeyframeTrack(keys: ks))])
    let applied = s.moveDuplicating([SummaryMember(property: opacity, keyID: ks[0].id)], by: kfT(1))
    #expect(applied == kfT(1))
    guard case .scalar(let t) = s.tracks[opacity] else { return }
    #expect(t.keys.map(\.time) == [kfT(1), kfT(2), kfT(3)])
    #expect(t.key(id: ks[0].id)?.time == kfT(2))         // the original id moved
    #expect(t.keys[0].id != ks[0].id)                     // a new key stays at 1
    #expect(t.keys[0].value == 1)
}

@Test func moveDuplicatingOntoOccupiedTimeKeepsTheMovedKey() {
    let ks = [kfKey(1, 1), kfKey(3, 3)]
    var s = KeyframeSummary(tracks: [opacity: .scalar(KeyframeTrack(keys: ks))])
    s.moveDuplicating([SummaryMember(property: opacity, keyID: ks[0].id)], by: kfT(2))
    guard case .scalar(let t) = s.tracks[opacity] else { return }
    #expect(t.keys.map(\.time) == [kfT(1), kfT(3)])
    #expect(t.keys[1].value == 1)
}

@Test func retargetSinglePropertyClipboard() {
    let ks = [kfKey(1, 0.5)]
    let clip = KeyframeClipboard.copy(from: [opacity: .scalar(KeyframeTrack(keys: ks))], selection: [opacity: [ks[0].id]])!
    let r = clip.retargeted(to: PropertyID("rotation"), isVector: false)
    #expect(r?.tracks.keys.first == PropertyID("rotation"))
    #expect(clip.retargeted(to: PropertyID("position"), isVector: true) == nil)   // other value type
}
