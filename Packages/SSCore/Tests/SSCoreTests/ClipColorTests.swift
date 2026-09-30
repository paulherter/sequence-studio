import Foundation
import Testing
@testable import SSCore

@Suite struct ClipColorTests {
    private func makeClip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    @Test func defaultStackIsBasicCorrectionThenInputLUT() {
        let c = ClipColor.default
        #expect(c.source == nil)
        #expect(c.useEmbeddedLUT)
        #expect(c.sections.map(\.kind) == [.basicCorrection, .inputLUT])
        #expect(c.sections[1].params == .inputLUT(.automatic))
        #expect(c.sections.allSatisfy { $0.enabled })
        #expect(c.isDefault)
        #expect(c.isIdentity(rec709Source: true))
        #expect(!c.isIdentity(rec709Source: false))
    }

    @Test func roundTripsThroughJSON() throws {
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        var b = BasicCorrection(); b.exposure = 1.5; b.saturation = 120; b.whites = 10; b.vibrance = -20
        c.sections[0].params = .basic(b)
        c.sections[1].params = .inputLUT(.file("/luts/a.cube"))
        c.useEmbeddedLUT = false
        var cl = CreativeLook(); cl.look = .embedded(UUID()); cl.intensity = 40; cl.shadowTint = WheelValue(hue: 200, amount: 0.3)
        let id = c.addSection(.creative)!; c.sections[2].params = .creative(cl)
        c.addSection(.curves); c.addSection(.wheels); c.addSection(.vignette)
        c.sections[id - 1].enabled = false
        let back = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(!back.isDefault)
    }

    @Test func sectionEditing() throws {
        var c = ClipColor.default
        let cur = c.addSection(.curves)!
        let vig = c.addSection(.vignette)!
        let b2 = c.addSection(.basicCorrection)!
        #expect(Set(c.sections.map(\.id)).count == c.sections.count)
        let dup = c.addSection(.inputLUT)
        #expect(dup == nil, "the Input LUT exists once")
        c.moveSection(b2, to: 1)   // a second Basic Correction after the first, before the LUT
        #expect(c.sections.map(\.kind) == [.basicCorrection, .basicCorrection, .inputLUT, .curves, .vignette])
        c.moveSection(vig, to: 0)
        #expect(c.sections.first?.id == vig)
        c.removeSection(cur)
        #expect(c.section(cur) == nil)
        let lut = c.sections.first { $0.kind == .inputLUT }!.id
        c.removeSection(lut)
        #expect(c.section(lut) != nil, "the Input LUT cannot be removed")
        c.sections[c.sections.firstIndex { $0.id == b2 }!].params = .basic({ var b = BasicCorrection(); b.tint = 5; return b }())
        c.resetSection(b2)
        #expect(c.section(b2)?.isNeutral == true)
    }

    @Test func neutralityAndIdentity() {
        var c = ClipColor.default
        c.sections[0].enabled = true
        #expect(c.isIdentity(rec709Source: true))
        c.sections[1].params = .inputLUT(.file("/x.cube"))
        #expect(!c.isIdentity(rec709Source: true))
        c.sections[1].enabled = false
        #expect(c.isIdentity(rec709Source: true))
        let k = BasicCorrection()
        #expect(k.isNeutral)
        #expect(CreativeLook().isNeutral)
        var cl = CreativeLook(); cl.look = .file("/a.cube"); cl.intensity = 0
        #expect(cl.isNeutral, "a look at intensity 0 does nothing")
    }

    @Test func v10ColorMigratesIntoBlocksInOldOrder() throws {
        let json = #"""
        {"source":"sLog3SGamut3Cine","useEmbeddedLUT":false,
         "correction":{"temperature":10,"tint":-5,"exposure":1.5,"contrast":20,"highlights":-30,"shadows":15,"saturation":130},
         "conversionLUT":{"kind":"file","path":"/c.cube"},
         "creativeLUT":{"kind":"file","path":"/l.cube"},"creativeIntensity":0.4,
         "bypassCorrection":true,"bypassConversionLUT":false,"bypassCreativeLUT":true}
        """#
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(json.utf8))
        #expect(c.source == .sLog3SGamut3Cine && !c.useEmbeddedLUT)
        #expect(c.sections.map(\.kind) == [.basicCorrection, .inputLUT, .creative])
        guard case .basic(let b) = c.sections[0].params else { Issue.record("basic"); return }
        #expect(b.temperature == 10 && b.tint == -5 && b.exposure == 1.5 && b.contrast == 20)
        #expect(b.highlights == -30 && b.shadows == 15 && b.saturation == 130 && b.whites == 0)
        #expect(!c.sections[0].enabled && c.sections[1].enabled && !c.sections[2].enabled)
        #expect(c.sections[1].params == .inputLUT(.file("/c.cube")))
        guard case .creative(let cl) = c.sections[2].params else { Issue.record("creative"); return }
        #expect(cl.look == .file("/l.cube") && abs(cl.intensity - 40) < 1e-4)
        // "none" stays none, absent keys = default stack.
        let none = try JSONDecoder().decode(ClipColor.self, from: Data(#"{"conversionLUT":null}"#.utf8))
        #expect(none.sections[1].params == .inputLUT(nil))
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let c = try JSONDecoder().decode(ClipColor.self, from: Data("{}".utf8))
        #expect(c == .default)
    }

    @Test func decodedStackAlwaysHasAnInputLUT() throws {
        var c = ClipColor.default
        c.sections.removeAll { $0.kind == .inputLUT }
        let back = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c))
        #expect(back.sections.filter { $0.kind == .inputLUT }.count == 1)
    }

    @Test func lutRefRoundTrips() throws {
        let id = UUID()
        for r in [LUTRef.automatic, .file("/x.cube"), .embedded(id)] {
            #expect(try JSONDecoder().decode(LUTRef.self, from: JSONEncoder().encode(r)) == r)
        }
    }

    @Test func clipDefaultsAndOldJSON() throws {
        var clip = makeClip()
        #expect(clip.color == .default)
        clip.color.sections[0].params = .basic({ var b = BasicCorrection(); b.contrast = 20; return b }())
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(Clip.self, from: data).color.sections[0].params == .basic({ var b = BasicCorrection(); b.contrast = 20; return b }()))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "color")
        let old = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.color == .default)
    }

    @Test func mediaInfoColorFieldsAreOptionalOnDecode() throws {
        var info = MediaInfo(duration: Time(5, 1))
        #expect(info.colorSpace == .rec709)
        info.detectedColorSpace = .sLog3SGamut3Cine
        info.embeddedLUTName = "Look"
        #expect(try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(info)) == info)
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(MediaInfo(duration: Time(5, 1)))) as? [String: Any])
        obj.removeValue(forKey: "detectedColorSpace"); obj.removeValue(forKey: "embeddedLUTName")
        let old = try JSONDecoder().decode(MediaInfo.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.needsColorDetection)
        #expect(!info.needsColorDetection)
        #expect(old.detectedColorSpace == nil && old.embeddedLUTName == nil && old.colorSpace == .rec709)
    }

    @Test func layerRequestCarriesClipColor() {
        var clip = makeClip()
        clip.color.sections[0].params = .basic({ var b = BasicCorrection(); b.exposure = 1; return b }())
        var t = Timeline(name: "T", frameDuration: Time(1, 30))
        t.tracks = [Track(kind: .video, clips: [clip])]
        let layers = t.videoLayers(at: Time(1, 1))
        #expect(layers.count == 1)
        #expect(layers[0].color.sections[0].params == .basic({ var b = BasicCorrection(); b.exposure = 1; return b }()))
    }

    @Test func v6ProjectFileLoadsAsV7WithDefaultColor() throws {
        let pid = UUID(), tid = UUID(), mid = UUID(), cid = UUID()
        let json = #"""
        {"formatVersion":6,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":2,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        #expect(ProjectFile.currentVersion == 11)
        let clip = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(clip.color == .default)
    }
}
