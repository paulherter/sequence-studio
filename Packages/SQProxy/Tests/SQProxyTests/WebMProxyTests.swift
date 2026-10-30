@preconcurrency import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQProxy

private let webm = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SequenceStudio/TestMedia/sample-vp9-vorbis.webm")

@Suite struct WebMProxyTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func webmSourceGetsAProRes422ProxyWithAudio() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("sq-webm-proxy-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        let out = try await ProxyTranscoder().transcode(source: webm, kind: .optimized, destination: dest, timeRange: nil) { _ in }
        #expect(out.sourceDuration > .zero)
        let asset = AVURLAsset(url: dest)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(Int(size.width) == out.dimensions.width && Int(size.height) == out.dimensions.height)
        let secs = try await asset.load(.duration).seconds
        let src = Double(out.sourceDuration.value) / Double(out.sourceDuration.timescale)
        #expect(abs(secs - src) < 0.2)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func seekProbeReadsTheWebMIndex() async throws {
        let info = try await AVSourceSeekProber().probe(webm)
        #expect(info.scannedFrames > 1)
        #expect(info.maxSyncDistance != nil)
    }

    @Test func cancelledTranscodeLeavesNoFile() async {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("sq-webm-proxy-\(UUID().uuidString).mov")
        let task = Task { try await ProxyTranscoder().transcode(source: webm, kind: .optimized, destination: dest, timeRange: nil) { _ in } }
        task.cancel()
        _ = try? await task.value
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
