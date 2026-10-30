import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQMediaTestSupport
import Testing

/// Reads all video frames of `url` in the order AVAssetReader delivers them (presentation order) and returns
/// (stamp, pts) pairs.
private func readStamps(_ url: URL, format: OSType) async throws -> [(Int?, CMTime)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
    reader.add(out)
    #expect(reader.startReading())
    var r: [(Int?, CMTime)] = []
    while let sb = out.copyNextSampleBuffer() {
        let pb = try #require(CMSampleBufferGetImageBuffer(sb))
        r.append((FrameStamp.read(pb), CMSampleBufferGetPresentationTimeStamp(sb)))
    }
    #expect(reader.status == .completed)
    return r
}

@Test func h264BFramesStampsRoundTrip() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let url = try await TestClipWriter.write(spec)
    let frames = try await readStamps(url, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(frames.map(\.0) == Array(0..<60).map { Optional($0) })
    #expect(zip(frames, frames.dropFirst()).allSatisfy { CMTimeCompare($0.1, $1.1) < 0 })
}

@Test func hevcMain10StampsRoundTrip() async throws {
    var spec = TestClipSpec(); spec.codec = .hevcMain10; spec.frameCount = 60
    let url: URL
    do { url = try await TestClipWriter.write(spec) }
    catch let TestClipError.encoderUnavailable(why) {
        Issue.record("HEVC Main10 encode unavailable on this host: \(why)"); return
    }
    let frames = try await readStamps(url, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    #expect(frames.map(\.0) == Array(0..<60).map { Optional($0) })
}

@Test func vfrAndStartOffsetKeepStamps() async throws {
    var spec = TestClipSpec()
    let offset = CMTime(value: 1, timescale: 10)
    var ticks: [Int64] = []          // timescale 60, irregular gaps 1...4 ticks, strictly increasing
    var t: Int64 = 6
    for i in 0..<30 { ticks.append(t); t += Int64(1 + (i * 7) % 4) }
    spec.presentationTimes = ticks.map { CMTime(value: $0, timescale: 60) }
    let url = try await TestClipWriter.write(spec)
    let frames = try await readStamps(url, format: kCVPixelFormatType_32BGRA)
    // The writer session starts at 0, so the reader pads the leading gap by repeating frame 0 at pts 0.
    var stamps = frames.map(\.0)
    if stamps.count == 31, stamps[0] == stamps[1] { stamps.removeFirst() }
    #expect(stamps == Array(0..<30).map { Optional($0) })
    #expect(frames.last?.1 == CMTime(value: ticks[29], timescale: 60))   // offset pts preserved
}

/// The second write of the same spec comes from the shared cache; each caller still owns a private clone it may delete.
@Test func sameSpecIsEncodedOnceAndClonedPerCaller() async throws {
    var spec = TestClipSpec(); spec.frameCount = 7
    let fm = FileManager.default
    let a = try await TestClipWriter.write(spec)
    let cached = TestClipWriter.cacheDirectory.appendingPathComponent("\(TestClipWriter.cacheKey(spec)).mov")
    #expect(fm.fileExists(atPath: cached.path))
    let stamp = try fm.attributesOfItem(atPath: cached.path)[.modificationDate] as? Date
    let b = try await TestClipWriter.write(spec)
    #expect(a != b && a.lastPathComponent == "clip.mov" && a.deletingLastPathComponent().lastPathComponent.hasPrefix("SQTestClip-"))
    #expect(try fm.attributesOfItem(atPath: cached.path)[.modificationDate] as? Date == stamp)   // not re-encoded
    #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    try fm.removeItem(at: a.deletingLastPathComponent())
    #expect(fm.fileExists(atPath: b.path) && fm.fileExists(atPath: cached.path))
    let frames = try await readStamps(b, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(frames.map(\.0) == Array(0..<7).map { Optional($0) })
    try? fm.removeItem(at: b.deletingLastPathComponent())
}

@Test func cacheKeyCoversEveryOutputShapingField() {
    let base = TestClipSpec()
    let k = TestClipWriter.cacheKey(base)
    #expect(k == TestClipWriter.cacheKey(base) && k.count == 64)
    var variants: [TestClipSpec] = []
    func v(_ edit: (inout TestClipSpec) -> Void) { var s = base; edit(&s); variants.append(s) }
    v { $0.codec = .prores4444 }; v { $0.width = 321 }; v { $0.height = 181 }; v { $0.frameDuration = TestClipSpec.fps(25) }
    v { $0.frameCount = 61 }; v { $0.presentationTimes = [CMTime(value: 1, timescale: 30)] }
    v { $0.startOffset = CMTime(value: 1, timescale: 10) }; v { $0.audioClicks = [] }; v { $0.audioClicks = [.zero] }
    v { $0.audioChannels = 1 }; v { $0.moovAtStart = true }; v { $0.rotation = 90 }; v { $0.pixelAspect = (4, 3) }
    let keys = variants.map(TestClipWriter.cacheKey)
    #expect(!keys.contains(k) && Set(keys).count == keys.count)
}

@Test func stampReadsBackInAllFormats() {
    for f in FrameStamp.supportedFormats {
        for n in [0, 1, 37, 59, 0xABCD, 0xFFFF] {
            let pb = FrameStamp.makePixelBuffer(width: 320, height: 180, format: f, frame: n)
            #expect(pb.flatMap(FrameStamp.read) == n)
        }
    }
}

@Test func audioClicksLandOnExactSamples() async throws {
    var spec = TestClipSpec(); spec.frameCount = 90
    let clicks = [CMTime(value: 1, timescale: 4), CMTime(value: 1, timescale: 1), CMTime(value: 2401, timescale: 1200)]
    spec.audioClicks = clicks
    let url = try await TestClipWriter.write(spec)
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(out)
    #expect(reader.startReading())
    var hits: [Int64] = [], pos: Int64 = 0
    while let sb = out.copyNextSampleBuffer() {
        if pos == 0 { pos = Int64(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), timescale: 48_000, method: .default).value) }
        let n = CMSampleBufferGetNumSamples(sb)
        var data = [Float](repeating: 0, count: n * 2)
        let block = try #require(CMSampleBufferGetDataBuffer(sb))
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: &data) == noErr)
        for i in 0..<n where abs(data[i * 2]) > 0.5 { hits.append(pos + Int64(i)); #expect(data[i * 2] == 1 && data[i * 2 + 1] == 1) }
        pos += Int64(n)
    }
    #expect(hits == clicks.map(TestClipSpec.sampleIndex(of:)).sorted())
}
