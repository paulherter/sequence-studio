import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Hold Ahead is a property of a key that a reverse leaves behind, not an ease shape: no curve, no segment shape and
/// no anchored animation carries it, so it cannot reach a place the project version gate does not see (text payloads,
/// the curve library, a Keystone or transition ease).
@Suite struct HoldAheadEaseGuardTests {
    private static let aheadKey = Keyframe(time: s(0), value: 1.0, interpolation: .holdAhead)

    @Test func aCurveSavedFromAHoldAheadKeyIsAHold() {
        #expect(EasingCurve(from: Self.aheadKey, name: "A").interpolation == .hold)
        var lib = EasingLibrary()
        let id = lib.saveCurve(from: Self.aheadKey, name: "Saved")
        #expect(lib.userCurves.first { $0.id == id }?.interpolation == .hold)
    }

    @Test func noCurveOrShapeCarriesHoldAhead() {
        var c = EasingCurve(name: "C", interpolation: .holdAhead, outHandle: .linear, inHandle: .linear)
        #expect(c.interpolation == .hold)
        c.interpolation = .holdAhead
        #expect(c.interpolation == .hold)
        var e = EaseShape(interpolation: .holdAhead, out: .linear, in: .linear)
        #expect(e == .hold)
        e.interpolation = .holdAhead
        #expect(e == .hold)
        #expect(EasingCurve(shape: e, name: "S").interpolation == .hold)
    }

    @Test func applyingTheSavedCurveGivesAHoldAndLeavesAHoldAheadAlone() {
        let curve = EasingCurve(from: Self.aheadKey, name: "A")
        let plain = Keyframe(time: s(0), value: 0.0), ahead = Keyframe(time: s(1), value: 1.0, interpolation: .holdAhead)
        var t = KeyframeTrack(keys: [plain, ahead, Keyframe(time: s(2), value: 2.0)])
        t.apply(curve, to: [plain.id, ahead.id])
        #expect(t.keys.map(\.interpolation) == [.hold, .holdAhead, .linear])
    }

    @Test func anAnchoredAnimationNeverCarriesHoldAhead() {
        let keys = [Self.aheadKey, Keyframe(time: s(1), value: 0.0)]
        var a = AnimationTrack(property: "opacity", track: KeyframeTrack(keys: keys))
        #expect(a.track.keys.map(\.interpolation) == [.hold, .linear])
        a.track.keys[1].interpolation = .holdAhead
        #expect(a.track.keys.map(\.interpolation) == [.hold, .hold])
        a.track = KeyframeTrack(keys: keys)
        #expect(a.track.keys.map(\.interpolation) == [.hold, .linear])
    }

    /// Decoding goes through the same guard: an old payload's leader and helper pair folds to a Hold Ahead in the
    /// nested track, and a stored curve or shape may name one.
    @Test func decodingAnOldPairInsideAnAnchoredAnimationGivesAHold() throws {
        let step = Time(1, 1_000_000)
        let old = KeyframeTrack(keys: [Keyframe(time: s(0), value: 0.2), Keyframe(time: s(1), value: 0.8, interpolation: .hold),
                                       Keyframe(time: s(1) + step, value: 0.5, interpolation: .hold), Keyframe(time: s(2), value: 0.5)])
        struct Raw: Codable { var property: String; var track: KeyframeTrack<Double> }
        let json = try JSONEncoder().encode(Raw(property: "opacity", track: old))
        #expect(try JSONDecoder().decode(Raw.self, from: json).track.keys.contains { $0.interpolation == .holdAhead })   // the fold happens
        let a = try JSONDecoder().decode(AnimationTrack.self, from: json)
        #expect(a.property == "opacity" && !a.track.keys.contains { $0.interpolation == .holdAhead })
        let template = KeyframeTemplate(tracks: [a], duration: s(2))
        let set = try JSONDecoder().decode(AnimationSet.self, from: JSONEncoder().encode(AnimationSet(in: template, out: nil)))
        #expect(!String(decoding: try JSONEncoder().encode(set), as: UTF8.self).contains("holdAhead"))
        let wrapped = try JSONEncoder().encode(["tracks": [Raw(property: "opacity", track: old)]])
        struct Tracks: Codable { var tracks: [AnimationTrack] }
        let back = try JSONEncoder().encode(JSONDecoder().decode(Tracks.self, from: wrapped))
        #expect(!String(decoding: back, as: UTF8.self).contains("holdAhead"))
    }

    @Test func aStoredCurveNamingHoldAheadDecodesAsHold() throws {
        let plain = try JSONEncoder().encode(EasingCurve.hold)
        let json = Data(String(decoding: plain, as: UTF8.self).replacingOccurrences(of: "\"hold\"", with: "\"holdAhead\"").utf8)
        #expect(String(decoding: json, as: UTF8.self).contains("holdAhead"))
        let c = try JSONDecoder().decode(EasingCurve.self, from: json)
        #expect(c == .hold)
        #expect(try JSONEncoder().encode(c) == plain || JSONDecoder().decode(EasingCurve.self, from: JSONEncoder().encode(c)) == .hold)
    }

    @Test func aStoredShapeNamingHoldAheadDecodesAsHold() throws {
        let plain = String(decoding: try EasingCurve.hold.presetPayload(), as: UTF8.self)
        let json = Data(plain.replacingOccurrences(of: "\"hold\"", with: "\"holdAhead\"").utf8)
        #expect(String(decoding: json, as: UTF8.self).contains("holdAhead"))
        #expect(try JSONDecoder().decode(EaseShape.self, from: json) == .hold)
        #expect(try EasingCurve(presetPayload: json, name: "P", id: UUID()).interpolation == .hold)
    }

    /// A keystone captured from a reversed clip keeps its Hold Ahead key and says so in its payload version: an older
    /// build skips that preset instead of failing on the unknown shape. Every other keystone still writes version 1.
    @Test func aKeystoneWithAHoldAheadKeyWritesPayloadVersion2() throws {
        let keys = [Keyframe(time: s(0), value: 0.0, interpolation: .holdAhead), Keyframe(time: s(1), value: 1.0)]
        let ahead = Keystone(name: "A", duration: s(1), opacity: KeyframeTrack(keys: keys))
        var plain = ahead
        plain.opacity?.keys[0].interpolation = .hold
        #expect(ahead.writtenPayloadVersion == 2 && plain.writtenPayloadVersion == 1)
        #expect(Keystone.builtIns.allSatisfy { $0.writtenPayloadVersion == 1 })
        #expect(try Keystone(payload: ahead.payload(), version: ahead.writtenPayloadVersion) == ahead)
        #expect(!String(decoding: try plain.payload(), as: UTF8.self).contains("holdAhead"))
        #expect(throws: Keystone.PayloadError.newerVersion(found: 3, supported: 2)) { try Keystone(payload: ahead.payload(), version: 3) }
    }

    /// The path the review found: a curve saved from a Hold Ahead key, put on the keys of a text clip's Custom Intro.
    /// The text payload is encoded outside the project encoder, so the file must stay below v77 and hold no such key.
    @Test func aTextPayloadWithTheSavedCurveKeepsTheFileBelowV77() throws {
        var lib = EasingLibrary()
        let id = lib.saveCurve(from: Self.aheadKey, name: "Saved")
        let curve = try #require(lib.all.first { $0.id == id })
        let k0 = Keyframe(time: s(0), value: 0.0), k1 = Keyframe(time: s(1), value: 1.0)
        var intro = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", track: KeyframeTrack(keys: [k0, k1]))], duration: s(1))
        intro.tracks[0].track.apply(curve, to: [k0.id, k1.id])
        #expect(intro.tracks[0].track.keys.allSatisfy { $0.interpolation == .hold })
        let payload = try JSONEncoder().encode(AnimationSet(in: intro, out: nil))
        #expect(!String(decoding: payload, as: UTF8.self).contains("holdAhead"))

        var clip = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        clip.generator = GeneratorRef(kind: GeneratorRef.text, payload: payload)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try #require(obj["formatVersion"] as? Int) < ProjectFile.v77Version)
    }
}
