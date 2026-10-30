import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

@Suite struct TransitionPresetTests {
    private func fixture() throws -> (Timeline, Track.ID, Transition.ID, Clip, Clip) {
        var v = Track(kind: .video, name: "V1")
        let a = clip(0), b = clip(60)
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "T", frameDuration: fd, tracks: [v])
        let id = try t.addTransition(kind: .push, track: v.id, outgoing: a.id, incoming: b.id, duration: f(12))
        try t.setTransition(id, easing: .fastStart, direction: .up, motionBlur: 1.5)
        return (t, v.id, id, a, b)
    }

    @Test func captureTakesKindDurationEasingAndParams() throws {
        let (t, _, id, _, _) = try fixture()
        let tr = t.transition(id)!.1
        let p = TransitionPreset.capture(from: tr)
        #expect(p.kind == .push && p.duration == f(12))
        #expect(p.easing == .fastStart && p.direction == .up && p.motionBlur == 1.5)
        #expect(p.alignment == .center)
    }

    @Test func customAlignmentIsSavedAsCenter() {
        var tr = Transition(kind: .crossDissolve, duration: f(10), alignment: .custom, customBefore: f(3), outgoing: UUID(), incoming: UUID())
        #expect(TransitionPreset.capture(from: tr).alignment == .center)
        tr.alignment = .endAtCut
        #expect(TransitionPreset.capture(from: tr).alignment == .endAtCut)
    }

    @Test func customAlignmentInPayloadIsNormalizedOnDecode() throws {
        let p = TransitionPreset(kind: .crossDissolve, duration: f(10))
        var json = try #require(try JSONSerialization.jsonObject(with: try p.payload()) as? [String: Any])
        json["alignment"] = "custom"
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(try TransitionPreset(payload: data, version: 1).alignment == .center)
    }

    @Test func payloadRoundTripsAndRejectsNewerVersion() throws {
        let (t, _, id, _, _) = try fixture()
        let p = TransitionPreset.capture(from: t.transition(id)!.1)
        let data = try p.payload()
        #expect(try TransitionPreset(payload: data, version: TransitionPreset.payloadVersion) == p)
        #expect(throws: TransitionPreset.PayloadError.newerVersion(found: 2, supported: 1)) {
            _ = try TransitionPreset(payload: data, version: 2)
        }
    }

    @Test func applyToExistingTransitionChangesKindDurationAndStyle() throws {
        var (t, _, id, _, _) = try fixture()
        let p = TransitionPreset(kind: .softWipe, duration: f(20), alignment: .startAtCut, easing: .easeIn,
                                 direction: .down, softness: 0.25, motionBlur: 0)
        try t.applyTransitionPreset(p, to: id)
        let tr = t.transition(id)!.1
        #expect(tr.kind == .softWipe && tr.duration == f(20) && tr.alignment == .startAtCut)
        #expect(tr.effectiveEasing == .easeIn && tr.effectiveDirection == .down && tr.effectiveSoftness == 0.25 && tr.effectiveMotionBlur == 0)
    }

    @Test func applyRefusesWrongTrackKind() throws {
        var (t, _, id, _, _) = try fixture()
        let audio = TransitionPreset(kind: .constantPower, duration: f(10))
        #expect(throws: EditError.wrongTrackKind) { try t.applyTransitionPreset(audio, to: id) }
        #expect(t.transition(id)!.1.kind == .push)   // untouched
    }

    @Test func addAtCutBuildsTheTransitionFromThePreset() throws {
        var v = Track(kind: .video, name: "V1")
        let a = clip(0), b = clip(60)
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "T", frameDuration: fd, tracks: [v])
        let p = TransitionPreset(kind: .slide, duration: f(8), easing: .easeOut, direction: .left, motionBlur: 0.5)
        let id = try t.addTransition(preset: p, point: .cut(outgoing: a.id, incoming: b.id), track: v.id)
        let tr = t.transition(id)!.1
        #expect(tr.kind == .slide && tr.duration == f(8) && tr.effectiveEasing == .easeOut && tr.effectiveMotionBlur == 0.5)
    }
}
