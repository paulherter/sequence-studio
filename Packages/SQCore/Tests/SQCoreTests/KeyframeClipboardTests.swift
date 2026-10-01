import Foundation
import Testing
@testable import SQCore

private let opacity = PropertyID("opacity")
private let position = PropertyID("position")

private func sample() -> (tracks: [PropertyID: PropertyTrack], sel: [PropertyID: Set<UUID>]) {
    var a = kfKey(1, 10, .bezier); a.outHandle = EaseHandle(dx: 0.5, dy: 0.2)
    let b = kfKey(3, 20)
    let c = Keyframe(time: kfT(2), value: Vec2(5, 6))
    let d = Keyframe(time: kfT(9), value: Vec2(7, 8))
    return ([opacity: .scalar(KeyframeTrack(keys: [a, b])), position: .vector(KeyframeTrack(keys: [c, d]))],
            [opacity: [a.id, b.id], position: [c.id]])
}

@Test func kfCopyPasteRelativeAndEasingKept() {
    let (tracks, sel) = sample()
    let clip = KeyframeClipboard.copy(from: tracks, selection: sel)
    #expect(clip != nil)
    var target: [PropertyID: PropertyTrack] = [:]
    let r1 = clip!.paste(into: &target, at: kfT(10))
    #expect(r1)
    guard case .scalar(let o) = target[opacity], case .vector(let p) = target[position] else { Issue.record("missing"); return }
    #expect(o.keys.map(\.time) == [kfT(10), kfT(12)])   // earliest copied key (t=1) lands at 10
    #expect(o.keys[0].outHandle == EaseHandle(dx: 0.5, dy: 0.2) && o.keys[0].interpolation == .bezier)
    #expect(p.keys.map(\.time) == [kfT(11)])            // 2 - 1 + 10
    #expect(p.keys[0].value == Vec2(5, 6))
    if case .scalar(let orig) = tracks[opacity] { #expect(o.keys[0].id != orig.keys[0].id) }
}

@Test func kfPasteReplacesKeysAtIdenticalTimes() {
    let (tracks, sel) = sample()
    let clip = KeyframeClipboard.copy(from: tracks, selection: sel)!
    var target: [PropertyID: PropertyTrack] = [opacity: .scalar(KeyframeTrack(keys: [kfKey(10, -1), kfKey(11, -2)]))]
    let r2 = clip.paste(into: &target, at: kfT(10))
    #expect(r2)
    guard case .scalar(let o) = target[opacity] else { return }
    #expect(o.keys.map(\.time) == [kfT(10), kfT(11), kfT(12)])
    #expect(o.keys.first { $0.time == kfT(10) }?.value == 10)
    #expect(o.keys.first { $0.time == kfT(11) }?.value == -2)
}

@Test func kfPasteRejectsTypeMismatchAtomically() {
    let (tracks, sel) = sample()
    let clip = KeyframeClipboard.copy(from: tracks, selection: sel)!
    let wrong: [PropertyID: PropertyTrack] = [position: .scalar(KeyframeTrack(keys: [kfKey(0, 1)])), opacity: .scalar(KeyframeTrack())]
    var target = wrong
    let r3 = clip.paste(into: &target, at: kfT(0))
    #expect(!r3)
    #expect(target == wrong)
}

@Test func kfCopyEmptySelectionIsNil() {
    let (tracks, _) = sample()
    #expect(KeyframeClipboard.copy(from: tracks, selection: [:]) == nil)
}

@Test func kfClipboardCodable() throws {
    let (tracks, sel) = sample()
    let clip = KeyframeClipboard.copy(from: tracks, selection: sel)!
    #expect(try JSONDecoder().decode(KeyframeClipboard.self, from: JSONEncoder().encode(clip)) == clip)
}
