import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

@Test func indexOfGeneratedClip() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    let e = d.index.entries
    #expect(e.count == 60)
    #expect(e.first?.pts == .zero)
    #expect(e.enumerated().allSatisfy { $1.pts == Time(Int64($0), 30) })
    // Encoder keyframe interval 12 (decode order) gives syncs every 11 frames here: 0, 11, 22, ...
    let syncs = e.indices.filter { e[$0].isSync }
    #expect(syncs.first == 0 && syncs.count >= 5)
    #expect(zip(syncs, syncs.dropFirst()).allSatisfy { $1 - $0 <= 12 })
    #expect(d.index.gop(containing: 14).contains(14))   // GOP boundaries vary per encode; GOPs tile the presentation order without gaps
    var i = 0
    while i < e.count { let g = d.index.gop(containing: i); #expect(g.lowerBound == i); i = g.upperBound + 1 }
    #expect(e.contains { $0.decodeOrdinal != e.firstIndex(of: $0) })   // B-frames: decode order differs
}

@Test func startOffsetClipStartsAtZero() async throws {
    var spec = TestClipSpec(); spec.frameCount = 24; spec.startOffset = CMTime(value: 1, timescale: 10)
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    #expect(d.index.entries.first?.pts == .zero)
    // Writer pads the offset with a repeated frame 0, so there may be one extra leading entry.
    #expect([24, 25].contains(d.index.count))
    #expect(d.index.entries.first?.isSync == true)
}

@Test func samplesComeInDecodeOrderFromSync() async throws {
    var spec = TestClipSpec(); spec.frameCount = 36
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    let range = 14...16
    let sbs = try await d.samples(for: range)
    let sync = d.index.syncDecodeOrdinal(for: 14)
    let maxOrd = range.map { d.index.entries[$0].decodeOrdinal }.max()!
    #expect(sbs.count == maxOrd - sync + 1)
    let first = sbs[0]
    let att = (CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false) as? [[CFString: Any]])?.first
    #expect(att?[kCMSampleAttachmentKey_NotSync] == nil)          // starts on a sync sample
    let dts = sbs.map { CMSampleBufferGetDecodeTimeStamp($0) }
    #expect(zip(dts, dts.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 })
    #expect(CMSampleBufferGetFormatDescription(first) != nil)
    await #expect(throws: MediaError.self) { _ = try await d.samples(for: 0...999) }
}

@Test func probeReportsGeneratedClip() async throws {
    var spec = TestClipSpec(); spec.frameCount = 30; spec.audioClicks = [CMTime(value: 1, timescale: 4)]
    let url = try await TestClipWriter.write(spec)
    let (ref, info) = try await MediaImporter.probe(url)
    let v = try #require(info.video)
    #expect(v.width == 320 && v.height == 180)
    #expect(v.codec == "avc1" && v.bitDepth == 8 && v.chroma == "4:2:0")
    #expect(v.nominalFrameDuration == Time(1, 30) && !v.isVariableFrameRate)
    #expect(info.audio == AudioTrackInfo(sampleRate: 48000, channels: 2, codec: "lpcm"))
    #expect(info.duration == Time(1, 1))
    #expect(ref.info == info && ref.fingerprint.size > 0 && ref.fingerprint.headHash != nil && ref.name == "clip.mov")
    #expect(ref.status() == .ok)
}

@Test func probeHEVC10AndVFR() async throws {
    var spec = TestClipSpec(); spec.codec = .hevcMain10
    var t: Int64 = 0; var ticks: [Int64] = []
    for i in 0..<30 { ticks.append(t); t += Int64(1 + (i * 7) % 4) }
    spec.presentationTimes = ticks.map { CMTime(value: $0, timescale: 60) }
    let url: URL
    do { url = try await TestClipWriter.write(spec) } catch TestClipError.encoderUnavailable { return }
    let (_, info) = try await MediaImporter.probe(url)
    let v = try #require(info.video)
    #expect(v.bitDepth == 10 && v.chroma == "4:2:0" && v.codec == "hvc1")
    #expect(v.isVariableFrameRate)
}

@Test func probeGarbageIsUnreadable() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID()).mov")
    try Data(repeating: 7, count: 4096).write(to: url)
    await #expect(throws: MediaError.self) { _ = try await MediaImporter.probe(url) }
}

@Test func probeSonyC2160() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SQ_MEDIA_DIR"] ?? NSString("~/Documents/Videos").expandingTildeInPath)
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
    guard let url = en.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.contains("C2160") }) else { return }
    let (_, info) = try await MediaImporter.probe(url)
    let v = try #require(info.video)
    #expect(v.width == 3840 && v.height == 2160)
    #expect(v.chroma == "4:2:2" && v.bitDepth == 10)
    #expect(v.colorPrimaries == nil && v.transfer == nil && v.matrix == nil)
}
