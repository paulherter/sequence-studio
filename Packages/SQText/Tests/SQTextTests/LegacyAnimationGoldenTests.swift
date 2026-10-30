#if canImport(CoreText)
import Testing
import Foundation
import CoreVideo
import CryptoKit
import SQCore
@testable import SQText

/// W7.3 AnimationStackUnify: text-clip payloads as v26-v28 projects store them must render pixel-identical after the
/// animation model moved to SQCore. Each fixture is a literal legacy payload; every sampled frame is digested (raster
/// bytes, placement and animation factors, bit-exact). The expected digests were recorded with the pre-W7.3 code
/// (SQText-owned KeyframeTemplate / AnimationSet / TextAnimator, commit 055055f) on macOS 27 and matched until
/// 2026-10-28, when Core Graphics glyph origins stopped snapping to whole pixels (subpixel positioning in
/// `TextRenderer` / `TextAnimatorRenderer`); recorded again then from main. Record again only for a deliberate render
/// change: `SQ_RECORD_GOLDEN=<file> scripts/test.sh SQText` writes the table to <file>.
@Suite(.serialized) struct LegacyAnimationGoldenTests {
    static let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
    static let clipDuration = Time(3, 1)
    /// Frames 0...89 of a 3 s clip at 30 fps, every 3rd frame plus the last one.
    static let times: [Time] = Array(stride(from: 0, to: 90, by: 3)).map { Time(Int64($0), 30) } + [Time(89, 30)]

    static func key(_ i: Int, _ t: String, _ v: Double, _ interp: String = "linear",
                    out: (Double, Double) = (0, 0), in inH: (Double, Double) = (0, 0)) -> String {
        #"{"id":"00000000-0000-0000-0000-00000000000\#(i)","time":\#(t),"value":\#(v),"interpolation":"\#(interp)","#
            + #""inHandle":{"dx":\#(inH.0),"dy":\#(inH.1)},"outHandle":{"dx":\#(out.0),"dy":\#(out.1)},"#
            + #""inTangent":{"x":0,"y":0},"outTangent":{"x":0,"y":0}}"#
    }
    static func time(_ v: Int, _ s: Int) -> String { #"{"value":\#(v),"timescale":\#(s)}"# }

    /// (name, template.animation JSON or nil, animations JSON or nil).
    static let fixtures: [(String, String?, String?)] = [
        // Template v1 shape (fractions + easing enum) as the clip's only animation: start-anchored pop.
        ("template-v1-pop", """
         {"duration":\(time(1, 2)),"tracks":[
           {"property":"scale","keyframes":[
             {"time":{"numerator":0,"denominator":1},"value":0.6,"easing":"overshoot"},
             {"time":{"numerator":1,"denominator":1},"value":1,"easing":"linear"}]},
           {"property":"opacity","keyframes":[
             {"time":{"numerator":0,"denominator":1},"value":0,"easing":"easeOut"},
             {"time":{"numerator":1,"denominator":2},"value":1,"easing":"linear"}]}]}
         """, nil),
        // v2 shape (Time keys, no anchor) in an AnimationSet with in and out (out written without an anchor).
        ("set-v2-in-out", nil, """
         {"animationIn":{"duration":\(time(1, 2)),"tracks":[
            {"property":"positionY","track":{"keys":[\(key(1, time(0, 1), 120, "bezier", out: (0.3333, 1))),\(key(2, time(1, 2), 0, in: (0.3333, 0)))]}},
            {"property":"opacity","track":{"keys":[\(key(1, time(0, 1), 0)),\(key(2, time(1, 4), 1))]}}]},
          "animationOut":{"duration":\(time(2, 5)),"tracks":[
            {"property":"rotation","track":{"keys":[\(key(1, time(0, 1), 0)),\(key(2, time(2, 5), -15))]}},
            {"property":"positionX","track":{"keys":[\(key(1, time(0, 1), 0, "hold")),\(key(2, time(1, 5), 200)),\(key(3, time(2, 5), 400))]}},
            {"property":"opacity","track":{"keys":[\(key(1, time(0, 1), 1)),\(key(2, time(2, 5), 0))]}}]}}
         """),
        // v3 template-only, end-anchored, with scale keys (out animation by anchor).
        ("template-v3-end", """
         {"anchor":"end","duration":\(time(1, 1)),"tracks":[
           {"property":"scale","track":{"keys":[\(key(1, time(0, 1), 1)),\(key(2, time(1, 1), 1.8, "linear"))]}},
           {"property":"opacity","track":{"keys":[\(key(1, time(1, 2), 1)),\(key(2, time(1, 1), 0))]}}]}
         """, nil),
        // W3.5 text animators: word slide in, character pop out, plus a block opacity track on the in side.
        ("set-v3-animators", nil, """
         {"animationIn":{"anchor":"start","duration":\(time(1, 3)),"tracks":[
            {"property":"opacity","track":{"keys":[\(key(1, time(0, 1), 0.5)),\(key(2, time(1, 3), 1))]}}],
           "textAnimator":{"effect":"slide","unit":"word","order":"forward","easing":"easeOut","duration":\(time(3, 10)),
                           "stagger":\(time(1, 10)),"distance":60,"direction":"up","blurRadius":12}},
          "animationOut":{"anchor":"end","duration":\(time(0, 1)),"tracks":[],
           "textAnimator":{"effect":"pop","unit":"character","order":"center","easing":"overshoot","duration":\(time(1, 5)),
                           "stagger":\(time(1, 30)),"distance":40,"direction":"up","blurRadius":12}}}
         """),
        // Typewriter in, blur out (line), reverse order.
        ("set-v3-typewriter-blur", nil, """
         {"animationIn":{"anchor":"start","duration":\(time(0, 1)),"tracks":[],
           "textAnimator":{"effect":"typewriter","unit":"character","duration":\(time(0, 1)),"stagger":\(time(1, 20))}},
          "animationOut":{"anchor":"end","duration":\(time(0, 1)),"tracks":[],
           "textAnimator":{"effect":"blur","unit":"line","order":"reverse","easing":"linear","duration":\(time(1, 2)),
                           "stagger":\(time(1, 5)),"blurRadius":20}}}
         """),
        // Template animation present but the set wins (both written, as old Type tool clips did).
        ("set-overrides-template", """
         {"anchor":"start","duration":\(time(1, 1)),"tracks":[
           {"property":"opacity","track":{"keys":[\(key(1, time(0, 1), 0)),\(key(2, time(1, 1), 1))]}}]}
         """, """
         {"animationIn":{"anchor":"start","duration":\(time(1, 2)),"tracks":[
            {"property":"scale","track":{"keys":[\(key(1, time(0, 1), 0.5)),\(key(2, time(1, 2), 1))]}}]}}
         """),
    ]

    static let style = TextStyle(fontName: "Helvetica-Bold", size: 90, color: .white,
                                 stroke: TextStroke(color: .black, width: 4), alignment: .center, lineSpacing: 2)

    static func ref(_ animation: String?, _ animations: String?) throws -> GeneratorRef {
        let plain = TextTemplate(name: "T", text: "Hello big\nworld again", style: style, box: TextBox(width: 800, height: 600))
        var template = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        if let animation { template["animation"] = try JSONSerialization.jsonObject(with: Data(animation.utf8)) }
        var payload: [String: Any] = ["template": template]
        if let animations { payload["animations"] = try JSONSerialization.jsonObject(with: Data(animations.utf8)) }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return GeneratorRef(kind: GeneratorRef.text, payload: data, payloadVersion: 1)
    }

    /// SHA-256 (first 8 bytes) over the frame's placement/animation numbers (bit patterns) and its pixel rows.
    static func digest(_ f: TextFrame?) -> UInt64 {
        var sha = SHA256()
        guard let f else { sha.update(data: Data([0xee])); return fold(sha) }
        for d in [f.x, f.y, f.width, f.height, f.opacity, f.scale, f.offsetX, f.offsetY, f.rotation] {
            withUnsafeBytes(of: d.bitPattern.littleEndian) { sha.update(bufferPointer: $0) }
        }
        let pb = f.buffer
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), hgt = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<hgt { sha.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * row, count: w * 8)) }
        return fold(sha)
    }

    static func fold(_ sha: SHA256) -> UInt64 {
        sha.finalize().prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Digest of all sampled frames of one fixture.
    static func run(_ ref: GeneratorRef) throws -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for t in times {
            let d = digest(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: clipDuration, canvas: canvas, scale: 1))
            h = (h ^ d) &* 0x100_0000_01b3
        }
        return h
    }

    static let expected: [String: UInt64] = [
        "template-v1-pop": 0x72a2e621635fdd85,
        "set-v2-in-out": 0xafce9c40705926f1,
        "template-v3-end": 0xbc9b26315eecc70d,
        "set-v3-animators": 0xacfcd02f8b416f36,
        "set-v3-typewriter-blur": 0xd324329e507d24eb,
        "set-overrides-template": 0xd88c90cb7a0b2938,
    ]

    /// Guards the fixtures themselves: every one decodes and actually animates (several distinct frames).
    @Test func fixturesAnimate() throws {
        for (name, anim, set) in Self.fixtures {
            let r = try Self.ref(anim, set)
            let frames = try Set(Self.times.map {
                Self.digest(try TextGenerator.frame(ref: r, localTime: $0, clipDuration: Self.clipDuration, canvas: Self.canvas, scale: 1))
            })
            #expect(frames.count >= 3, "\(name)")
        }
    }

    @Test func legacyPayloadsRenderAsBefore() throws {
        let record = ProcessInfo.processInfo.environment["SQ_RECORD_GOLDEN"]
        var lines: [String] = []
        for (name, anim, set) in Self.fixtures {
            let got = try Self.run(Self.ref(anim, set))
            lines.append("\"\(name)\": 0x\(String(got, radix: 16)),")
            if record == nil { #expect(Self.expected[name] == got, "\(name)") }
        }
        if let record { try lines.joined(separator: "\n").write(toFile: record, atomically: true, encoding: .utf8) }
    }

    /// The same payloads inside a project file written as v26/v27 (envelope version patched down) open to the same clip
    /// and the same pixels: ProjectFile and its migrations never touch the text payload.
    @Test func legacyProjectFilesOpenPixelIdentical() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sq-w73-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for version in [26, 27, 28] {
            for (name, anim, set) in Self.fixtures {
                let r = try Self.ref(anim, set)
                var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
                tl.format = Self.canvas
                var p = Project(name: "P", timelines: [tl])
                let id = try p.addGeneratorClip(kind: GeneratorRef.text, payload: r.payload, in: tl.id, at: .zero,
                                                track: tl.tracks[0].id, duration: Self.clipDuration)
                let url = dir.appendingPathComponent("\(name)-\(version).sqproj")
                try ProjectFile.write(p, to: url)
                let file = url.appendingPathComponent("project.json")
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                json["formatVersion"] = version
                try JSONSerialization.data(withJSONObject: json).write(to: file)
                let back = try ProjectFile.read(from: url)
                let clip = try #require(back.timelines[0].tracks[0].clips.first { $0.id == id })
                let g = try #require(clip.generator)
                #expect(g.payload == r.payload, "\(name) v\(version)")
                // Same bytes render the same pixels; render once per fixture (from the oldest file) to prove it end to end.
                if version == 26, Self.expected[name] != nil { #expect(try Self.run(g) == Self.expected[name], "\(name) v\(version)") }
            }
        }
    }
}
#endif
