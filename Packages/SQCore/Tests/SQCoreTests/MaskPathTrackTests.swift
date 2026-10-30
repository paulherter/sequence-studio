import Foundation
import Testing
@testable import SQCore

/// Mask Path keys as a `PropertyTrack` (`.path`): they move, ease, hold, copy and paste like any other key.
struct MaskPathTrackTests {
    private let p: PropertyID = "mask:path"
    private func rect(_ s: Double) -> MaskPath { .rectangle(Vec2(0, 0), Vec2(s, s)) }
    private func track() -> (PropertyTrack, UUID, UUID) {
        let a = Keyframe(time: Time(0, 30), value: rect(0.5)), b = Keyframe(time: Time(30, 30), value: rect(1))
        return (.path(KeyframeTrack(keys: [a, b])), a.id, b.id)
    }

    @Test func pathTrackListsItsKeys() {
        let (t, a, b) = track()
        #expect(t.keyIDs == [a, b])
        #expect(t.times.map(\.time) == [Time(0, 30), Time(30, 30)])
    }

    @Test func summaryMovesPathKeys() {
        let (t, _, b) = track()
        var s = KeyframeSummary(tracks: [p: t])
        let d = s.move([SummaryMember(property: p, keyID: b)], by: Time(10, 30), frame: Time(1, 30))
        #expect(d == Time(10, 30))
        #expect(s.tracks[p]?.times.first { $0.id == b }?.time == Time(40, 30))
    }

    @Test func holdAndEasingApplyToPathKeys() {
        let (t, a, _) = track()
        var s = KeyframeSummary(tracks: [p: t])
        s.toggleHold([SummaryMember(property: p, keyID: a)])
        #expect(s.tracks[p]?.interpolation(of: a) == .hold)
        s.tracks[p]?.apply(KeyInterpolationChoice.linear, to: [a])
        #expect(s.tracks[p]?.interpolation(of: a) == .linear)
        s.tracks[p]?.apply(KeyInterpolationChoice.easyEase, to: [a])
        #expect(s.tracks[p]?.interpolation(of: a) != .hold)
    }

    @Test func pathKeysCopyAndPasteOntoPathOnly() throws {
        let (t, a, b) = track()
        let clip = try #require(KeyframeClipboard.copy(from: [p: t], selection: [p: [a, b]]))
        #expect(clip.keyCount == 2)
        var target: [PropertyID: PropertyTrack] = [p: .path(KeyframeTrack())]
        #expect(clip.paste(into: &target, at: Time(60, 30)))
        #expect(target[p]?.times.map(\.time) == [Time(60, 30), Time(90, 30)])
        var wrong: [PropertyID: PropertyTrack] = [p: .scalar(KeyframeTrack())]
        #expect(!clip.paste(into: &wrong, at: .zero))
        #expect(clip.retargeted(to: "x", isVector: false) == nil)
        #expect(clip.retargeted(to: "mask:other", isVector: false, isPath: true)?.propertyIDs == ["mask:other"])
        let k = Keyframe(time: .zero, value: 1.0)
        let scalar = try #require(KeyframeClipboard.copy(from: [p: .scalar(KeyframeTrack(keys: [k]))], selection: [p: [k.id]]))
        #expect(scalar.retargeted(to: "mask:other", isVector: false, isPath: true) == nil)
    }

    @Test func pathHasNoSpeedCurve() {
        #expect(track().0.speedOverlay() == nil)
    }
}
