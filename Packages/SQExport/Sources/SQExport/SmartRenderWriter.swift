import AVFoundation
import CoreMedia
import Foundation
import SQCore

/// Smart Render writer (the design notes 2026-10-22): the runs `SmartRender.plan` marks as passthrough are copied from the
/// source files as compressed samples; everything between them is encoded as usual. The pieces are joined by the same
/// seam logic as parallel segments (`ExportWriter.join`). Correctness first: every copied run is checked against the file
/// before anything is written (opening sync sample on the grid, one sample per frame at exactly the frame distance, the
/// next sample is a sync sample, same codec and size as the encoder writes); a run that fails the check is encoded, and
/// a smart export that fails anywhere falls back to the plain export.
public struct SmartExportResult: Sendable {
    public var report: LoudnessReport?
    /// Output frames copied from the sources without re-encoding.
    public var copiedFrames: Int
    /// True when the smart path failed and the whole sequence was encoded the plain way.
    public var fellBack: Bool
}

public extension ExportWriter {
    /// Exports like `export`, copying the plan's passthrough runs. `mediaURLs`: the source file of each media in the plan.
    /// Only H.264 and HEVC (ProRes has no GOPs to align). The plan must be for exactly `video.frameCount` frames at the
    /// export frame duration, and the source of `video` must be what `SmartRender.plan` analyzed.
    @discardableResult
    static func exportSmart(video: any SegmentableFrameSource, audio: (any AudioSource)?, settings: ExportSettings,
                            plan: SmartRenderPlan, mediaURLs: [UUID: URL], to url: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> SmartExportResult {
        func plain(_ fellBack: Bool) async throws -> SmartExportResult {
            let r = try await export(video: video, audio: audio, settings: settings, to: url, progress: progress)
            return SmartExportResult(report: r, copiedFrames: 0, fellBack: fellBack)
        }
        let issues = settings.validate()
        guard issues.isEmpty else { throw ExportError.invalidSettings(issues) }
        guard !settings.video.codec.isMastering, settings.frameOutput == nil, settings.audioOnly == nil,
              plan.totalFrames == video.frameCount, !plan.passthrough.isEmpty else { return try await plain(false) }
        let fd = settings.video.frameDuration
        let codec = settings.video.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var copies: [(run: SmartRenderRun, url: URL)] = []
        for run in plan.passthrough.sorted(by: { $0.frames.lowerBound < $1.frames.lowerBound }) {
            guard let src = mediaURLs[run.media], copies.last.map({ $0.run.frames.upperBound <= run.frames.lowerBound }) ?? true,
                  await verifiedCopy(run, url: src, frameDuration: fd, size: (settings.video.width, settings.video.height),
                                     codec: codec) else { continue }
            copies.append((run, src))
        }
        guard !copies.isEmpty else { return try await plain(false) }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        let dir = url.deletingLastPathComponent().appendingPathComponent(".sq-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        if !hasRoomForSegments(at: dir, settings: settings, frames: video.frameCount) { return try await plain(false) }

        // Pieces in output order: encode the gaps, copy the runs.
        var parts: [SmartPart] = []
        var at = 0
        for (run, src) in copies {
            if run.frames.lowerBound > at { parts.append(.encode(at..<run.frames.lowerBound, dir.appendingPathComponent("gap-\(parts.count).mov"))) }
            parts.append(.copy(run, src))
            at = run.frames.upperBound
        }
        if at < video.frameCount { parts.append(.encode(at..<video.frameCount, dir.appendingPathComponent("gap-\(parts.count).mov"))) }
        let encodeFrames = parts.reduce(0) { sum, part in
            if case .encode(let r, _) = part { return sum + r.count } else { return sum }
        }
        let copiedFrames = copies.reduce(0) { $0 + $1.run.frames.count }

        let segSettings = { var s = settings; s.audio.enabled = false; return s }()
        let audioSource = settings.audio.enabled ? audio : nil
        if settings.audio.loudness != nil, let a = audioSource, !(a is any RewindableAudioSource) {
            throw ExportError.loudnessNeedsRewindableSource
        }
        let audioFile = audioSource.map { _ in dir.appendingPathComponent("audio.mov") }
        let counter = ProgressCounter(total: encodeFrames, scale: 0.9, report: progress)
        if encodeFrames == 0 { progress(0.9) }
        let encodeParts = parts
        do {
            let report = try await withThrowingTaskGroup(of: LoudnessReport?.self) { group in
                if let audioSource, let audioFile {
                    group.addTask {
                        let (normalized, report) = try await normalizedAudio(audioSource, settings: settings.audio)
                        try await encodeAudio(normalized ?? audioSource, settings: settings.audio, to: audioFile)
                        return report
                    }
                }
                group.addTask {
                    for case .encode(let r, let file) in encodeParts {
                        let source = try video.segment(r)
                        let last = ProgressCounter.Last()
                        let len = r.count
                        try await encode(video: source, audio: nil, settings: segSettings, to: file) { p in
                            counter.advance(last.delta(Int((p * Double(len)).rounded())))
                        }
                    }
                    return nil
                }
                var report: LoudnessReport?
                for try await r in group { if let r { report = r } }
                return report
            }
            let pieces = parts.map { part -> JoinPiece in
                switch part {
                case .encode(let r, let file): JoinPiece(url: file, start: fd * Int64(r.lowerBound))
                case .copy(let run, let src):
                    JoinPiece(url: src, start: fd * Int64(run.frames.lowerBound),
                              copy: CopyRange(from: run.sourceStart, frames: run.frames.count, frameDuration: fd))
                }
            }
            try await join(pieces, audioFile: audioFile, settings: settings, to: url) { progress(0.9 + 0.09 * $0) }
            var verified = report
            if verified != nil { verified?.verified = try? await OutputAudioVerifier.measure(url: url) }
            progress(1.0)
            return SmartExportResult(report: verified, copiedFrames: copiedFrames, fellBack: false)
        } catch is CancellationError {
            try? fm.removeItem(at: url)
            throw CancellationError()
        } catch ExportError.loudnessNeedsRewindableSource {
            throw ExportError.loudnessNeedsRewindableSource
        } catch {
            // Nothing smart may leave a broken file: encode everything the plain way.
            try? fm.removeItem(at: url)
            return try await plain(true)
        }
    }
}

enum SmartPart: Sendable {
    case encode(Range<Int>, URL)
    case copy(SmartRenderRun, URL)
}

extension ExportWriter {
    /// Reads the compressed samples of `run` (no decoding) and says whether they can be copied as they are: the first
    /// sample in decode order is a sync sample at `run.sourceStart`, there are exactly `run.frames.count` samples, none
    /// depends on a sample outside the run, their presentation times are the frame grid from `sourceStart`, the sample
    /// after the run (if any) is a sync sample, and codec and size are what the encoder writes.
    static func verifiedCopy(_ run: SmartRenderRun, url: URL, frameDuration fd: Time, size: (Int, Int),
                             codec: CMVideoCodecType) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = (try? await track.load(.formatDescriptions))?.first,
              CMFormatDescriptionGetMediaSubType(format) == codec else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        guard Int(dims.width) == size.0, Int(dims.height) == size.1,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let n = run.frames.count
        let range = CopyRange(from: run.sourceStart, frames: n, frameDuration: fd)
        reader.timeRange = range.readRange
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        var pts: [CMTime] = []
        while let sb = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) == 1 else { continue }
            let p = CMSampleBufferGetPresentationTimeStamp(sb)
            if pts.isEmpty, !(isSyncSample(sb) && CMTimeCompare(p, range.from.cm) == 0) { continue }
            if CMTimeCompare(p, range.end.cm) >= 0 { return pts.count == n && isSyncSample(sb) && gridMatches(pts, range) }
            pts.append(p)
            if pts.count > n { return false }
        }
        // The run ends where the file ends (no sample after it).
        return reader.status != .failed && pts.count == n && gridMatches(pts, range)
    }

    static func isSyncSample(_ sb: CMSampleBuffer) -> Bool {
        guard let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
              let first = a.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
            && (first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) != true
    }

    private static func gridMatches(_ pts: [CMTime], _ r: CopyRange) -> Bool {
        let sorted = pts.sorted { CMTimeCompare($0, $1) < 0 }
        for (i, p) in sorted.enumerated() where CMTimeCompare(p, (r.from + r.frameDuration * Int64(i)).cm) != 0 { return false }
        return true
    }
}
