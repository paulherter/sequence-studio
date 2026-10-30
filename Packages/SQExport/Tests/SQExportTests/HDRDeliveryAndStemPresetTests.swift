import Testing
import Foundation
import AVFoundation
import VideoToolbox
import SQCore
@testable import SQExport

@Suite struct HDRDeliveryTests {
    @Test func masteringBytesAreBigEndianAndExact() {
        let d = HDRDelivery(transfer: .pq, peakNits: 1000, frameAverageNits: 400, minNits: 0.005)
        let b = [UInt8](d.masteringDisplayData)
        #expect(b.count == 24)
        // Green x 0.265 / 0.00002 = 13250 = 0x33C2; white point x 0.3127 -> 15635 = 0x3D13.
        #expect(Array(b[0..<2]) == [0x33, 0xC2])
        #expect(Array(b[12..<14]) == [0x3D, 0x13])
        // 1000 nits = 10_000_000 = 0x00989680; 0.005 nit = 50 = 0x32.
        #expect(Array(b[16..<20]) == [0x00, 0x98, 0x96, 0x80])
        #expect(Array(b[20..<24]) == [0, 0, 0, 0x32])
    }

    @Test func lightLevelAndClamping() {
        let d = HDRDelivery(peakNits: 99_999, frameAverageNits: 50_000)
        #expect(d.peakNits == 10_000 && d.frameAverageNits == 10_000)
        #expect([UInt8](d.contentLightLevelData) == [0x27, 0x10, 0x27, 0x10])
        #expect(HDRDelivery(peakNits: 10).peakNits == 100)
    }

    @Test func tagsForHLGAndPQ() {
        #expect(HDRDelivery(transfer: .pq).transferTag == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(HDRDelivery(transfer: .hlg).transferTag == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(HDRDelivery().primariesTag == AVVideoColorPrimaries_ITU_R_2020)
    }

    @Test func writerOutputOnlyForHEVC() {
        var s = ExportSettings()
        s.hdrDelivery = HDRDelivery(transfer: .hlg, peakNits: 1000)
        s.video.codec = .hevc; s.video.profile = .main
        let out = ExportWriter.videoOutputSettings(s)
        let color = out[AVVideoColorPropertiesKey] as? [String: Any]
        #expect(color?[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
        let comp = out[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(comp?[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        #expect((comp?[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] as? Data)?.count == 24)
        #expect((comp?[kVTCompressionPropertyKey_ContentLightLevelInfo as String] as? Data)?.count == 4)
        let props = ExportWriter.speedEncoderProperties(s).required
        #expect(props[kVTCompressionPropertyKey_TransferFunction as String] as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect((props[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] as? Data)?.count == 24)

        s.video.codec = .h264
        let sdr = ExportWriter.videoOutputSettings(s)
        let c2 = sdr[AVVideoColorPropertiesKey] as? [String: Any]
        #expect(c2?[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_709_2)
        #expect(ExportWriter.speedEncoderProperties(s).required[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] == nil)
    }

    @Test func absentByDefaultAndRoundTrips() throws {
        var s = ExportSettings()
        #expect(s.hdrDelivery == nil)
        s.hdrDelivery = HDRDelivery(transfer: .hlg, peakNits: 600)
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back.hdrDelivery == s.hdrDelivery)
    }
}

@Suite struct StemPresetTests {
    private func plan() -> [StemPlan.Stem] {
        let tl = Timeline(name: "T", frameDuration: Time(1, 30))
        return ["dialogue", "music", "other", "me"].map { StemPlan.Stem(id: $0, title: $0.capitalized, fileSuffix: $0, timeline: tl) }
    }

    @Test func selectsInPlanOrderAndSkipsMissing() {
        let p = StemPreset(name: "x", stemIDs: ["me", "dialogue", "sfx"])
        #expect(p.select(from: plan()).map(\.id) == ["dialogue", "me"])
    }

    @Test func builtInChoices() {
        let b = StemPreset.builtIn(for: plan())
        #expect(b.map(\.name) == ["All roles", "Roles only", "Music and Effects only"])
        #expect(b[1].stemIDs == ["dialogue", "music", "other"])
        #expect(StemPreset.builtIn(for: Array(plan().prefix(2))).count == 1)
    }

    @Test func storeSavesReplacesDeletes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stempresets-\(UUID().uuidString)/p.json")
        let store = StemPresetStore(url: url)
        #expect(store.load().isEmpty)
        try store.save(StemPreset(name: "Dub", stemIDs: ["me"]))
        let after = try store.save(StemPreset(name: "dub", stemIDs: ["me", "music"], format: .m4a))
        #expect(after.count == 1 && after[0].stemIDs == ["me", "music"] && after[0].format == .m4a)
        #expect(try store.delete(id: after[0].id).isEmpty)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try Data("garbage".utf8).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bad.json"))
        #expect(StemPresetStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("bad.json")).load().isEmpty)
    }

    @Test func sizeEstimateScalesWithCount() {
        let one = StemPreset.estimatedBytes(count: 1, duration: Time(60, 1), format: .wav, audio: AudioSettings())
        // 48 kHz x 2 ch x 24 bit x 60 s / 8
        #expect(one == 48_000 * 2 * 24 * 60 / 8)
        #expect(StemPreset.estimatedBytes(count: 3, duration: Time(60, 1), format: .wav, audio: AudioSettings()) == one * 3)
    }
}
