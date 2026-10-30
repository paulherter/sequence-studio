import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct AnchorTests {
    let fadeIn = CaptionPresetLibrary.builtIn.animation(for: "fade")         // 0.2 s, .start
    let fadeOut = CaptionPresetLibrary.builtIn.animation(for: "fade-out")    // 0.2 s, .end
    func op(_ a: KeyframeTemplate, _ t: Time, clip: Time) -> Double { a.value(of: "opacity", clipTime: t, clipDuration: clip)! }

    @Test func builtInAnchors() {
        let lib = CaptionPresetLibrary.builtIn
        #expect(lib.animation(for: "fade").anchor == .start)
        #expect(lib.animation(for: "pop-in").anchor == .start)
        #expect(lib.animation(for: "none").anchor == .start)
        #expect(lib.animation(for: "fade-out").anchor == .end)
        #expect(lib.hasAnimation("fade-out"))
        #expect(KeyframeTemplate(tracks: [], duration: .zero).anchor == .start)
    }

    @Test func startAnchorMeasuresFromClipStart() {
        let clip = Time(10, 1)
        #expect(fadeIn.startOffset(clipDuration: clip) == .zero)
        #expect(op(fadeIn, .zero, clip: clip) == 0)
        #expect(abs(op(fadeIn, Time(1, 10), clip: clip) - 0.5) < 1e-9)
        #expect(op(fadeIn, Time(5, 1), clip: clip) == 1)
    }

    @Test func endAnchorMeasuresBackFromClipEnd() {
        let clip = Time(10, 1)
        #expect(fadeOut.startOffset(clipDuration: clip) == Time(49, 5))   // 10 - 1/5 = 9.8
        #expect(op(fadeOut, .zero, clip: clip) == 1)                       // before the out-animation: first value
        #expect(op(fadeOut, Time(98, 10), clip: clip) == 1)
        #expect(abs(op(fadeOut, Time(99, 10), clip: clip) - 0.5) < 1e-9)
        #expect(op(fadeOut, clip, clip: clip) == 0)
    }

    @Test func anchoredDurationIsNeverScaled() {
        // Same 0.2 s out-animation regardless of clip length.
        for clipSec: Int64 in [1, 3, 60] {
            let clip = Time(clipSec, 1)
            #expect(abs(op(fadeOut, clip - Time(1, 10), clip: clip) - 0.5) < 1e-9)
        }
    }

    @Test func resolvedGivesClipLocalTimes() {
        let clip = Time(10, 1)
        let out = fadeOut.resolved(clipDuration: clip)
        #expect(out.count == 1 && out[0].property == "opacity")
        #expect(out[0].track.keys.map(\.time) == [Time(49, 5), clip])
        #expect(out[0].value(at: Time(99, 10)).map { abs($0 - 0.5) < 1e-9 } == true)
        let inn = fadeIn.resolved(clipDuration: clip)
        #expect(inn[0].track.keys.map(\.time) == [.zero, Time(1, 5)])
        // Resolved tracks match direct evaluation.
        for t in [Time(0, 1), Time(1, 10), Time(49, 5), Time(99, 10), Time(10, 1)] {
            #expect(inn[0].value(at: t) == fadeIn.value(of: "opacity", at: t))
            #expect(out[0].value(at: t) == fadeOut.value(of: "opacity", clipTime: t, clipDuration: clip))
        }
    }

    @Test func clipShorterThanAnimationClampsToClipRange() {
        let clip = Time(1, 10)                            // 0.1 s clip, 0.2 s animations
        let inn = fadeIn.resolved(clipDuration: clip)[0].track.keys
        #expect(inn.map(\.time) == [.zero, clip])
        #expect(inn.allSatisfy { $0.time >= .zero && $0.time <= clip })
        #expect(abs(inn[1].value - 0.5) < 1e-9)           // in-animation is cut at the clip end
        let out = fadeOut.resolved(clipDuration: clip)[0].track.keys
        #expect(out.map(\.time) == [.zero, clip])
        #expect(abs(out[0].value - 0.5) < 1e-9)           // out-animation starts half way
        #expect(out[1].value == 0)
        #expect(abs(op(fadeOut, .zero, clip: clip) - 0.5) < 1e-9)
    }

    @Test func zeroAndNegativeClipDuration() {
        for clip in [Time.zero, Time(-1, 2)] {
            let r = fadeIn.resolved(clipDuration: clip)[0].track.keys
            #expect(r.count == 1 && r[0].time == .zero)
        }
        #expect(KeyframeTemplate.none.resolved(clipDuration: Time(1, 1)).isEmpty)
        #expect(KeyframeTemplate(tracks: [AnimationTrack(property: "x", keys: [])], duration: Time(1, 2))
            .resolved(clipDuration: Time(1, 1)).first?.track.isEmpty == true)
    }

    @Test func combinedInOutDoNotCross() {
        let set = AnimationSet(in: fadeIn, out: fadeOut)
        func v(_ t: Time, _ clip: Time) -> Double { set.value(of: "opacity", clipTime: t, clipDuration: clip)! }
        let clip = Time(10, 1)
        #expect(v(.zero, clip) == 0)
        #expect(v(Time(5, 1), clip) == 1)
        #expect(abs(v(Time(99, 10), clip) - 0.5) < 1e-9)
        #expect(v(clip, clip) == 0)
        #expect(set.outStart(clipDuration: clip) == Time(49, 5))
        // 0.3 s clip: in (0.2) + out (0.2) would overlap; out starts at in's end and is cut by the clip end.
        let short = Time(3, 10)
        #expect(set.outStart(clipDuration: short) == Time(1, 5))
        #expect(v(Time(1, 5), short) == 1)                 // in finished, out just begins
        #expect(abs(v(Time(1, 4), short) - 0.75) < 1e-9)   // out plays 0.05 of 0.2
        // Clip no longer than the in-animation: out never plays.
        let tiny = Time(1, 10)
        #expect(set.outStart(clipDuration: tiny) == nil)
        #expect(abs(v(tiny, tiny) - 0.5) < 1e-9)
        // Monotonic hand-over: never jumps up again after the in-animation ended.
        let samples = (0...30).map { v(Time(Int64($0), 100), short) }
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
        // In ends at 0.2 s (sample 20); from there the value must never rise (a jump up would fail this).
        let after = Array(samples[20...])
        #expect(after.first == 1)
        #expect(zip(after, after.dropFirst()).allSatisfy { $1 <= $0 + 1e-12 })
    }

    @Test func combinedNormalizesAnchorsAndHandlesMissingSides() {
        let set = AnimationSet(in: fadeOut, out: fadeIn)   // anchors forced: given as "in" -> start
        #expect(set.animationIn?.anchor == .start && set.animationOut?.anchor == .end)
        let onlyOut = AnimationSet(in: nil, out: fadeOut)
        #expect(onlyOut.value(of: "opacity", clipTime: .zero, clipDuration: Time(10, 1)) == 1)
        #expect(onlyOut.value(of: "scale", clipTime: .zero, clipDuration: Time(10, 1)) == nil)
        #expect(AnimationSet(in: nil, out: nil).value(of: "opacity", clipTime: .zero, clipDuration: Time(1, 1)) == nil)
        // Property only in the in-animation keeps its end value while the out-animation plays.
        let pop = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        let both = AnimationSet(in: pop, out: fadeOut)
        #expect(abs(both.value(of: "scale", clipTime: Time(99, 10), clipDuration: Time(10, 1))! - 1.0) < 1e-9)
    }

    @Test func anchorCodableAndLegacyDecode() throws {
        let data = try JSONEncoder().encode(fadeOut)
        #expect(String(decoding: data, as: UTF8.self).contains("\"anchor\":\"end\""))
        #expect(try JSONDecoder().decode(KeyframeTemplate.self, from: data) == fadeOut)
        // A template written before anchors existed decodes as .start.
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "anchor")
        let legacy = try JSONDecoder().decode(KeyframeTemplate.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(legacy.anchor == .start)
        #expect(legacy.tracks == fadeOut.tracks)
    }

    static let v2JSON = """
    {"formatVersion":2,"name":"V2","text":"Hi",
     "style":{"fontName":"Helvetica","size":40,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},
              "alignment":"center","lineSpacing":0},
     "animation":{"duration":{"value":1,"timescale":5},"tracks":[
       {"property":"opacity","track":{"keys":[
         {"id":"00000000-0000-0000-0000-000000000001","time":{"value":0,"timescale":1},"value":0,"interpolation":"linear",
          "inHandle":{"dx":0,"dy":0},"outHandle":{"dx":0,"dy":0},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}},
         {"id":"00000000-0000-0000-0000-000000000002","time":{"value":1,"timescale":5},"value":1,"interpolation":"linear",
          "inHandle":{"dx":0,"dy":0},"outHandle":{"dx":0,"dy":0},"inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}}]}}]}}
    """

    @Test func versionTwoFileReadsAsStartAnchored() throws {
        let t = try TextTemplate.decode(from: Data(Self.v2JSON.utf8))
        let a = try #require(t.animation)
        #expect(a.anchor == .start && a.duration == Time(1, 5))
        #expect(a.value(of: "opacity", at: Time(1, 10)).map { abs($0 - 0.5) < 1e-9 } == true)
        // Re-saving writes the current version (v3+) with the anchor and round-trips.
        let json = try JSONSerialization.jsonObject(with: t.encoded()) as! [String: Any]
        #expect(json["formatVersion"] as? Int == TextTemplate.formatVersion)
        #expect(try TextTemplate.decode(from: t.encoded()) == t)
    }

    @Test func versionThreeOutTemplateRoundTrips() throws {
        let t = TextTemplate(name: "Out", text: "Bye", style: CaptionPresetLibrary.builtIn.style(for: nil), animation: fadeOut)
        let back = try TextTemplate.decode(from: t.encoded())
        #expect(back == t && back.animation?.anchor == .end)
    }
}
