import Foundation
import Testing
@testable import SSCore

@Suite struct ClipColorTests {
    private func makeClip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    @Test func defaultsAreAutomaticFromMedia() {
        let c = ClipColor.default
        #expect(c.source == nil)
        #expect(c.correction.isNeutral)
        #expect(c.conversionLUT == .automatic)
        #expect(c.useEmbeddedLUT)
        #expect(c.creativeLUT == nil)
        #expect(c.creativeIntensity == 1)
        #expect(!c.bypassCorrection && !c.bypassConversionLUT && !c.bypassCreativeLUT)
        #expect(c.isDefault)
    }

    @Test func roundTripsThroughJSON() throws {
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        c.correction.exposure = 1.5
        c.correction.saturation = 120
        c.conversionLUT = .file("/luts/a.cube")
        c.useEmbeddedLUT = false
        c.creativeLUT = .embedded(UUID())
        c.creativeIntensity = 0.4
        c.bypassCreativeLUT = true
        let back = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(!back.isDefault)
    }

    @Test func correctionRoundTripIsExact() throws {
        var k = ColorCorrection()
        k.temperature = 12.5; k.tint = -7; k.exposure = 0.75; k.contrast = 30
        k.highlights = -20; k.shadows = 15; k.saturation = 140
        #expect(try JSONDecoder().decode(ColorCorrection.self, from: JSONEncoder().encode(k)) == k)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let c = try JSONDecoder().decode(ClipColor.self, from: Data("{}".utf8))
        #expect(c == .default)
        let k = try JSONDecoder().decode(ColorCorrection.self, from: Data("{}".utf8))
        #expect(k == .neutral)
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
        clip.color.correction.contrast = 20
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(Clip.self, from: data).color.correction.contrast == 20)
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
        clip.color.correction.exposure = 1
        var t = Timeline(name: "T", frameDuration: Time(1, 30))
        t.tracks = [Track(kind: .video, clips: [clip])]
        let layers = t.videoLayers(at: Time(1, 1))
        #expect(layers.count == 1)
        #expect(layers[0].color.correction.exposure == 1)
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
        #expect(ProjectFile.currentVersion == 9)
        let clip = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(clip.color == .default)
    }
}
