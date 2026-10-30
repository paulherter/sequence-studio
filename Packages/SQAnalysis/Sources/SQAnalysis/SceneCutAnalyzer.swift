import AVFoundation
import Foundation
import SQCore

/// Reads a file's frames at low resolution (decoder-scaled) and returns the times, in media time, where the shot changes.
/// Runs off the calling actor and stops when the task is canceled.
public enum SceneCutAnalyzer {
    public enum AnalyzeError: Error, LocalizedError {
        case noVideo, unreadable

        public var errorDescription: String? {
            switch self {
            case .noVideo: "The file has no video track."
            case .unreadable: "The file could not be read."
            }
        }
    }

    private static let bins = 32
    private static let side = (width: 96, height: 54)

    /// `range`: media time to look at (nil = whole file). `progress`: 0...1, called from the reading thread.
    public static func detect(url: URL, range: TimeRange? = nil, settings: SceneCutDetector.Settings = .init(),
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Time] {
        let work = Task.detached(priority: .utility) {
            try read(url: url, range: range, settings: settings, progress: progress)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func read(url: URL, range: TimeRange?, settings: SceneCutDetector.Settings,
                             progress: (@Sendable (Double) -> Void)?) throws -> [Time] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw AnalyzeError.noVideo }
        let (reader, output) = try AnalysisFields.start(asset: asset, track: track, order: nil, size: side,
                                                     timeRange: range.map { CMTimeRange(start: cm($0.start), duration: cm($0.duration)) })
        defer { reader.cancelReading() }
        let total = range.map { Double($0.duration.value) / Double($0.duration.timescale) } ?? asset.duration.seconds
        var times: [Time] = []
        var diffs: [Double] = []
        var previous: [Int]?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let h = histogram(pb)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            times.append(Time(pts.value, Int64(max(pts.timescale, 1))))
            diffs.append(previous.map { SceneCutDetector.histogramDifference($0, h) } ?? 0)
            previous = h
            if total > 0, times.count % 30 == 0, let progress { progress(min(1, pts.seconds / total)) }
        }
        if reader.status == .failed { throw AnalyzeError.unreadable }
        return SceneCutDetector.cutIndices(differences: diffs, settings: settings).map { times[$0] }
    }

    private static func cm(_ t: Time) -> CMTime { CMTime(value: t.value, timescale: Int32(clamping: t.timescale)) }

    private static func histogram(_ pb: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var h = [Int](repeating: 0, count: bins)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return h }
        let w = CVPixelBufferGetWidth(pb), ht = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<ht {
            for x in 0..<w {
                let o = y * stride + x * 4                       // BGRA
                let l = (Int(p[o]) * 29 + Int(p[o + 1]) * 150 + Int(p[o + 2]) * 77) >> 8      // Rec.601 luma, 0...255
                h[min(bins - 1, l * bins / 256)] += 1
            }
        }
        return h
    }
}
