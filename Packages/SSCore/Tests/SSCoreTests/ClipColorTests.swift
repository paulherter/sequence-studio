import Foundation
import Testing
@testable import SSCore

@Suite struct ClipColorTests {
    private func makeClip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    @Test func defaultIsOneEffectWithAutomaticInputLUT() {
        let c = ClipColor.default
        #expect(c.source == nil)
        #expect(c.useEmbeddedLUT)
        #expect(c.effects.count == 1)
        #expect(c.primary.inputLUT == .automatic)
        #expect(ColorSectionKind.allCases.allSatisfy { c.primary.isEnabled($0) })
        #expect(c.isDefault)
        #expect(c.isIdentity(rec709Source: true))
        #expect(!c.isIdentity(rec709Source: false))
    }

    @Test func fixedSectionOrder() {
        #expect(ColorSectionKind.allCases == [.basicCorrection, .creative, .curves, .wheels, .hslSecondary, .vignette])
        #expect(!ColorSectionKind.hslSecondary.isImplemented)
    }

    @Test func roundTripsThroughJSON() throws {
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        c.useEmbeddedLUT = false
        c.effects[0].basic.exposure = 1.5; c.effects[0].basic.saturation = 120; c.effects[0].basic.whites = 10
        c.effects[0].inputLUT = .file("/luts/a.cube")
        c.effects[0].creative.look = .embedded(UUID()); c.effects[0].creative.intensity = 40
        c.effects[0].creative.shadowTint = WheelValue(hue: 200, amount: 0.3)
        c.effects[0].setEnabled(.creative, false)
        c.effects[0].vignette.amount = -2
        let second = c.addEffect()
        c.effects[1].inputLUT = .file("/luts/b.cube"); c.effects[1].inputLUTIntensity = 35
        let back = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.effect(second)?.inputLUTIntensity == 35)
        #expect(!back.effects[0].isEnabled(.creative) && back.effects[0].isEnabled(.basicCorrection))
        #expect(!back.isDefault)
        // "none" survives a round trip (JSON null), it does not turn into the default automatic LUT.
        var none = ClipColor.default; none.effects[0].inputLUT = nil
        #expect(try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(none)).primary.inputLUT == nil)
    }

    @Test func effectEditing() {
        var c = ClipColor.default
        let b = c.addEffect(), d = c.addEffect()
        #expect(Set(c.effects.map(\.id)).count == 3)
        #expect(c.effect(b)?.inputLUT == nil, "a later effect has no Input LUT by default")
        c.removeEffect(b)
        #expect(c.effects.map(\.id) == [1, d])
        c.removeEffect(d); c.removeEffect(1)
        #expect(c.effects.count == 1, "the last effect stays")
        c.effects[0].basic.tint = 5
        c.effects[0].inputLUT = .file("/x.cube")
        c.resetSection(.basicCorrection, in: 1)
        #expect(c.effects[0].basic.isNeutral && c.effects[0].inputLUT == .automatic)
        let e2 = c.addEffect()
        c.effects[1].inputLUT = .file("/y.cube")
        c.resetSection(.basicCorrection, in: e2)
        #expect(c.effects[1].inputLUT == nil)
    }

    @Test func neutralityAndIdentity() {
        var c = ClipColor.default
        #expect(c.isIdentity(rec709Source: true))
        c.effects[0].inputLUT = .file("/x.cube")
        #expect(!c.isIdentity(rec709Source: true))
        c.effects[0].setEnabled(.basicCorrection, false)
        #expect(c.isIdentity(rec709Source: true))
        #expect(!c.isIdentity(rec709Source: false), "log sources always need the conversion")
        c.effects[0].setEnabled(.basicCorrection, true)
        c.effects[0].inputLUT = nil
        c.effects[0].vignette.amount = 1
        #expect(!c.isIdentity(rec709Source: true))
        c.addEffect()
        c.effects[0].vignette = Vignette()
        c.effects[1].curves.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        #expect(!c.isIdentity(rec709Source: true), "a later effect counts too")
        #expect(BasicCorrection().isNeutral && CreativeLook().isNeutral)
        var cl = CreativeLook(); cl.look = .file("/a.cube"); cl.intensity = 0
        #expect(cl.isNeutral, "a look at intensity 0 does nothing")
    }

    @Test func v11BlocksMapIntoFixedSections() throws {
        let json = #"""
        {"source":"rec709","useEmbeddedLUT":true,"sections":[
         {"id":1,"enabled":true,"params":{"basic":{"_0":{"temperature":10,"tint":0,"exposure":1,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":110,"vibrance":0}}}},
         {"id":2,"enabled":true,"params":{"inputLUT":{"_0":{"kind":"file","path":"/c.cube"}}}},
         {"id":3,"enabled":false,"params":{"vignette":{"_0":{"amount":-1,"midpoint":50,"roundness":0,"feather":50}}}},
         {"id":4,"enabled":true,"params":{"basic":{"_0":{"temperature":0,"tint":7,"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}}}},
         {"id":5,"enabled":true,"params":{"vignette":{"_0":{"amount":2,"midpoint":50,"roundness":0,"feather":50}}}},
         {"id":6,"enabled":true,"params":{"curves":{"_0":{"master":[{"x":0,"y":0},{"x":0.5,"y":0.6},{"x":1,"y":1}],"red":[{"x":0,"y":0},{"x":1,"y":1}],"green":[{"x":0,"y":0},{"x":1,"y":1}],"blue":[{"x":0,"y":0},{"x":1,"y":1}]}}}}]}
        """#
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(json.utf8))
        #expect(c.effects.count == 2, "duplicates become a second effect")
        let a = c.effects[0], b = c.effects[1]
        #expect(a.basic.temperature == 10 && a.basic.exposure == 1 && a.basic.saturation == 110)
        #expect(a.inputLUT == .file("/c.cube"))
        #expect(a.vignette.amount == -1 && !a.isEnabled(.vignette))
        #expect(a.curves.master.count == 3)
        #expect(b.basic.tint == 7 && b.vignette.amount == 2 && b.isEnabled(.vignette))
        #expect(b.inputLUT == nil)
        #expect(c.effects.map(\.id) == [1, 2])
    }

    @Test func v11BypassedInputLUTBecomesNone() throws {
        let json = #"""
        {"sections":[{"id":1,"enabled":true,"params":{"basic":{"_0":{"temperature":0,"tint":0,"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}}}},
         {"id":2,"enabled":false,"params":{"inputLUT":{"_0":{"kind":"file","path":"/c.cube"}}}}]}
        """#
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(json.utf8))
        #expect(c.effects.count == 1 && c.primary.inputLUT == nil)
        #expect(c.primary.isEnabled(.basicCorrection))
        // A v11 "none" LUT (absent payload) stays none.
        let n = #"{"sections":[{"id":2,"enabled":true,"params":{"inputLUT":{}}}]}"#
        #expect(try JSONDecoder().decode(ClipColor.self, from: Data(n.utf8)).primary.inputLUT == nil)
    }

    @Test func v10ColorMigratesIntoFixedSections() throws {
        let json = #"""
        {"source":"sLog3SGamut3Cine","useEmbeddedLUT":false,
         "correction":{"temperature":10,"tint":-5,"exposure":1.5,"contrast":20,"highlights":-30,"shadows":15,"saturation":130},
         "conversionLUT":{"kind":"file","path":"/c.cube"},
         "creativeLUT":{"kind":"file","path":"/l.cube"},"creativeIntensity":0.4,
         "bypassCorrection":false,"bypassConversionLUT":false,"bypassCreativeLUT":true}
        """#
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(json.utf8))
        #expect(c.source == .sLog3SGamut3Cine && !c.useEmbeddedLUT)
        #expect(c.effects.count == 1)
        let e = c.primary
        #expect(e.basic.temperature == 10 && e.basic.tint == -5 && e.basic.exposure == 1.5 && e.basic.contrast == 20)
        #expect(e.basic.highlights == -30 && e.basic.shadows == 15 && e.basic.saturation == 130 && e.basic.whites == 0)
        #expect(e.isEnabled(.basicCorrection))
        #expect(!e.isEnabled(.creative))
        #expect(e.inputLUT == .file("/c.cube"))
        #expect(e.creative.look == .file("/l.cube") && abs(e.creative.intensity - 40) < 1e-4)
        let none = try JSONDecoder().decode(ClipColor.self, from: Data(#"{"conversionLUT":null}"#.utf8))
        #expect(none.primary.inputLUT == nil)
    }

    @Test func v10BypassedCorrectionWithDefaultLUTKeepsTheLUT() throws {
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(#"{"correction":{"exposure":1},"bypassCorrection":true}"#.utf8))
        #expect(c.primary.inputLUT == .automatic && c.primary.isEnabled(.basicCorrection) && c.primary.basic.isNeutral)
        // Bypassed LUT and bypassed correction: both stay off.
        let off = try JSONDecoder().decode(ClipColor.self, from: Data(#"{"correction":{"exposure":1},"bypassCorrection":true,"bypassConversionLUT":true}"#.utf8))
        #expect(off.primary.inputLUT == nil && !off.primary.isEnabled(.basicCorrection) && off.primary.basic.exposure == 1)
    }

    @Test func emptyingEffectsRestoresTheDefaultEffect() {
        var c = ClipColor.default
        c.effects = []
        #expect(c.effects.count == 1 && c.primary.id == 1)
        c.effects.removeAll()
        #expect(c.effects.count == 1)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let c = try JSONDecoder().decode(ClipColor.self, from: Data("{}".utf8))
        #expect(c == .default)
    }

    @Test func decodedColorAlwaysHasAnEffect() throws {
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(#"{"effects":[]}"#.utf8))
        #expect(c.effects.count == 1)
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
        clip.color.effects[0].basic.contrast = 20
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(Clip.self, from: data).color.effects[0].basic.contrast == 20)
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
        clip.color.effects[0].basic.exposure = 1
        var t = Timeline(name: "T", frameDuration: Time(1, 30))
        t.tracks = [Track(kind: .video, clips: [clip])]
        let layers = t.videoLayers(at: Time(1, 1))
        #expect(layers.count == 1)
        #expect(layers[0].color.effects[0].basic.exposure == 1)
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
        #expect(ProjectFile.currentVersion == 13)
        let clip = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(clip.color == .default)
    }

    @Test func v11ProjectFileMigratesToV12() throws {
        let pid = UUID(), tid = UUID(), mid = UUID(), cid = UUID()
        let json = #"""
        {"formatVersion":11,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "color":{"sections":[{"id":1,"enabled":true,"params":{"basic":{"_0":{"temperature":0,"tint":0,"exposure":2,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}}}},
                             {"id":2,"enabled":true,"params":{"inputLUT":{"_0":{"kind":"automatic"}}}}]},
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":2,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        let clip = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(clip.color.effects.count == 1 && clip.color.primary.basic.exposure == 2 && clip.color.primary.inputLUT == .automatic)
    }

    @Test func v12ProjectFileMigratesToV13WithFlatHueCurves() throws {
        let pid = UUID(), tid = UUID(), mid = UUID(), cid = UUID()
        let json = #"""
        {"formatVersion":12,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "color":{"useEmbeddedLUT":true,"effects":[{"id":1,"inputLUT":{"kind":"automatic"},"inputLUTIntensity":100,
        "basic":{"temperature":0,"tint":0,"exposure":1.5,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}}]},
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":2,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        let e = try #require(p.timelines.first?.tracks.first?.clips.first?.color.primary)
        #expect(e.basic.exposure == 1.5 && e.hueCurves == HueCurves() && e.hueCurves.isNeutral)
        #expect(e.isNeutral(.curves))
    }

    @Test func hueCurvesRoundTripAndOnlyEncodeWhenUsed() throws {
        var c = ClipColor.default
        let plain = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!plain.contains("hueCurves"), "neutral curves keep the JSON unchanged")
        c.effects[0].hueCurves.hueVsSat = [CurvePoint(0, 0.5), CurvePoint(0.33, 0.9), CurvePoint(1, 0.5)]
        c.effects[0].hueCurves.lumaVsSat = [CurvePoint(0, 0.2), CurvePoint(1, 0.5)]
        #expect(!c.effects[0].isNeutral(.curves) && !c.isIdentity(rec709Source: true))
        let back = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        c.resetSection(.curves, in: 1)
        #expect(c.effects[0].hueCurves.isNeutral && c.isIdentity(rec709Source: true))
    }

    @Test func hueCurvesNeutralMeansEveryPointOnTheMiddleLine() {
        var h = HueCurves()
        #expect(h.isNeutral)
        h.hueVsHue = [CurvePoint(0, 0.5), CurvePoint(0.5, 0.5), CurvePoint(1, 0.5)]
        #expect(h.isNeutral, "extra points on the line change nothing")
        h.hueVsLuma = [CurvePoint(0, 0.5), CurvePoint(0.5, 0.6), CurvePoint(1, 0.5)]
        #expect(!h.isNeutral)
    }
}
