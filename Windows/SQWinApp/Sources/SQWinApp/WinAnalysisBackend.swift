import Foundation
import SQAnalysis
import SQCore
import SQEditorSession
import SQFrame
import SQMedia
import SQMediaFFmpeg

/// The analysis commands on Windows: Find Scene Changes reads the clip's frames through FFmpeg (software decode, reduced
/// four times on download) and runs the portable `SceneCutDetector` over their luma histograms. Auto Reframe and Stabilize
/// need the Mac's Vision; they stay "not available on this computer yet" (`offersReframe` / `offersStabilize` false).
/// shortcut: scene changes decode every frame of the range in software; upgrade to the hardware decoder with a
/// reduced-size copy when long clips feel slow. Unverified on the PC until scripts/win-test.sh runs (docs/FEATURE-PARITY.md).
struct WinAnalysisBackend: AnalysisBackend {
    private static let bins = 32
    private static let chunk = 24

    func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? {
        let work = Task.detached(priority: .utility) { try await Self.read(url: url, range: range, progress: progress) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func read(url: URL, range: TimeRange, progress: @Sendable (Double) -> Void) async throws -> [Time] {
        let demuxer = try FFmpegDemuxer(url: url)
        let decoder = try FFmpegVideoDecoder(demuxer: demuxer, media: UUID(), hardware: false)
        let entries = demuxer.index.entries
        let inRange = entries.indices.filter { entries[$0].pts >= range.start && entries[$0].pts < range.end }
        guard let first = inRange.first, let last = inRange.last else { return [] }
        var times: [Time] = [], diffs: [Double] = []
        var previous: [Int]?
        var at = first
        while at <= last {
            try Task.checkCancellation()
            let hi = min(at + chunk - 1, last)
            for f in try await decoder.decode(at...hi) {
                guard let h = histogram(f.frame) else { continue }
                times.append(f.pts)
                diffs.append(previous.map { SceneCutDetector.histogramDifference($0, h) } ?? 0)
                previous = h
            }
            progress(Double(hi - first + 1) / Double(last - first + 1))
            at = hi + 1
        }
        return SceneCutDetector.cutIndices(differences: diffs, settings: .init()).map { times[$0] }
    }

    /// Luma histogram of a decoded picture (NV12 or P010, planes packed: luma first), limited range stretched to 0...255.
    private static func histogram(_ frame: SQFrame) -> [Int]? {
        guard let ff = frame.storage as? FFmpegFrame else { return nil }
        let bytes: [UInt8], w: Int, h: Int
        if let r = try? ff.download(divisor: 4) {
            (bytes, w, h) = (r.bytes, r.width, r.height)
        } else if let b = try? ff.download() {
            (bytes, w, h) = (b, frame.width, frame.height)
        } else { return nil }
        let wide = bytes.count >= w * h * 3          // P010: 16-bit samples, high byte second
        let full = frame.pixelFormat == .nv12FullRange || frame.pixelFormat == .p010FullRange
        var hist = [Int](repeating: 0, count: bins)
        for i in 0..<(w * h) {
            var y = Int(wide ? bytes[i * 2 + 1] : bytes[i])
            if !full { y = min(255, max(0, (y - 16) * 255 / 219)) }
            hist[min(bins - 1, y * bins / 256)] += 1
        }
        return hist
    }
}
