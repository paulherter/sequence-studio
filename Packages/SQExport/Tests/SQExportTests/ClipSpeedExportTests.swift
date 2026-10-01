import Testing
import AVFoundation
import Foundation
import CoreVideo
import SQCore
import SQMedia
import SQPlayback
@testable import SQExport

/// Records every source time the export asks for, per media.
private final class RecordingProvider: FrameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var times: [UUID: [Time]] = [:]
    private let inner: SolidProvider
    init(media: [UUID]) {
        inner = SolidProvider(colors: Dictionary(uniqueKeysWithValues: media.map { ($0, (b: 40, g: 40, r: 200)) }), width: 64, height: 112)
    }
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        lock.withLock { times[media, default: []].append(sourceTime) }
        return try await inner.frame(media: media, at: sourceTime)
    }
    func requested(_ m: UUID) -> [Time] { lock.withLock { times[m] ?? [] } }
}

private let fd = Time(1, 30)

/// One video + one linked audio clip of `srcSeconds` of media at `percent` speed; media is `srcSeconds` long.
private func retimedTimeline(percent: Double, srcSeconds: Int64, reversed: Bool = false) -> (Timeline, UUID) {
    let m = UUID(), link = UUID()
    let speed = ClipSpeed(percent: percent)
    let src = TimeRange(start: .zero, duration: Time(srcSeconds, 1))
    let v = Clip(name: "v", media: m, kind: .video, source: src, start: .zero, link: link,
                 mediaDuration: Time(srcSeconds, 1), speed: speed, reversed: reversed)
    let a = Clip(name: "a", media: m, kind: .audio, source: src, start: .zero, link: link,
                 mediaDuration: Time(srcSeconds, 1), speed: speed, reversed: reversed)
    let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 112, frameDuration: fd),
                      tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])])
    return (tl, m)
}

private func exportSpeed(percent: Double, srcSeconds: Int64, reversed: Bool = false) async throws
    -> (frames: Int, audioSeconds: Double, audioPeak: Float, requested: [Time], timelineSeconds: Double) {
    let (tl, m) = retimedTimeline(percent: percent, srcSeconds: srcSeconds, reversed: reversed)
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("s.mp4")
    var s = smallSettings(codec: .h264)
    s.audio.enabled = true; s.audio.sampleRate = 48_000; s.audio.channels = 2; s.audio.bitrate = 128_000
    let frameCount = Int(tl.duration.frameIndex(frameDuration: fd))
    let provider = RecordingProvider(media: [m])
    let video = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 112, frameDuration: fd, frameCount: frameCount)
    let sine = MemoryAudioSource(mono: (0..<(Int(srcSeconds) * 48_000)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) })
    let audio = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, duration: tl.duration),
                                    resolver: StaticMediaResolver(audio: [m: sine]))
    try await ExportWriter.export(video: video, audio: audio, settings: s, to: url, progress: { _ in })
    let info = try await readVideo(url)
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let dur = try await track.load(.timeRange).duration.seconds
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
    reader.add(out); reader.startReading()
    var peak: Float = 0
    while let sb = out.copyNextSampleBuffer() {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let len = CMBlockBufferGetDataLength(bb)
        var data = [Float](repeating: 0, count: len / 4)
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        peak = max(peak, data.map { abs($0) }.max() ?? 0)
    }
    return (info.frames, dur, peak, provider.requested(m), tl.duration.seconds)
}

private extension Time { var seconds: Double { Double(value) / Double(timescale) } }

@Suite struct ClipSpeedExportTests {
    @Test func doubleSpeedClipExportsHalfTheLengthWithMappedFramesAndAudio() async throws {
        let r = try await exportSpeed(percent: 200, srcSeconds: 2)
        #expect(r.timelineSeconds == 1.0)
        #expect(r.frames == 30)
        #expect(abs(r.audioSeconds - 1.0) < 0.1)
        #expect(r.audioPeak > 0.3, "audio present: \(r.audioPeak)")
        #expect(r.requested.count == 30)
        // Frame i shows source frame 2i: 2 source frames per timeline frame.
        for (i, t) in r.requested.enumerated() { #expect(t == Time(2 * Int64(i), 30), "frame \(i)") }
    }

    @Test func halfSpeedClipExportsTwiceTheLength() async throws {
        let r = try await exportSpeed(percent: 50, srcSeconds: 1)
        #expect(r.timelineSeconds == 2.0)
        #expect(r.frames == 60)
        #expect(abs(r.audioSeconds - 2.0) < 0.1)
        #expect(r.audioPeak > 0.3, "audio present: \(r.audioPeak)")
        for (i, t) in r.requested.enumerated() { #expect(t == Time(Int64(i), 60), "frame \(i)") }
    }

    @Test func reversedClipExportsFramesBackwards() async throws {
        let r = try await exportSpeed(percent: 100, srcSeconds: 1, reversed: true)
        #expect(r.frames == 30 && r.audioPeak > 0.3)
        #expect(r.requested.first == Time(29, 30) && r.requested.last == .zero)
    }
}
