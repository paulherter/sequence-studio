import AVFoundation
import CoreMedia
import Foundation
import SQCore

/// Sequential reads of a WebM or MXF file for tools that would otherwise use `AVAssetReader` (proxies, stabilization,
/// transcription), which cannot open these files. Everything goes through `WebMDemuxer` / `VTVideoDecoder` and
/// `WebMAudioSource`.
public enum WebMReadback {
    /// Presentation-order frame indices whose pts lies in `range` (all frames when nil).
    public static func frameIndices(in index: SampleIndex, range: TimeRange?) -> ClosedRange<Int>? {
        let entries = index.entries
        guard !entries.isEmpty else { return nil }
        guard let range else { return 0...(entries.count - 1) }
        let first = entries.firstIndex { $0.pts >= range.start }
        guard let first else { return nil }
        let last = entries.lastIndex { $0.pts < range.end } ?? first
        return first <= last ? first...last : nil
    }

    /// Decodes the video frames of `range` (whole file when nil) in presentation order, `batch` frames per decoder call.
    public static func forEachFrame(url: URL, range: TimeRange? = nil, scale: DecodeScale = .full, batch: Int = 12,
                                    _ body: (DecodedFrame) async throws -> Void) async throws {
        let (demux, deinterlace) = try await openDemuxer(url)
        try await forEachFrame(demuxer: demux, range: range, scale: scale, batch: batch, deinterlace: deinterlace, body)
    }

    /// True for the containers AVFoundation cannot open and this reader covers: WebM / Matroska (MKV) and MXF.
    public static func handles(_ url: URL) -> Bool { WebMFile.isWebM(url) || MXFFile.isMXF(url) }

    /// The demuxer of a WebM / Matroska or MXF file, and the field order an interlaced MXF picture is deinterlaced with.
    public static func openDemuxer(_ url: URL) async throws -> (any Demuxing, FieldOrder?) {
        if MXFFile.isMXF(url) {
            let d = try await MXFDemuxer(url: url)
            return (d, d.file.videoTrack?.picture?.fieldOrder)
        }
        return (try await WebMDemuxer(url: url), nil)
    }

    /// The sound of a WebM / Matroska or MXF file at `sampleRate` (stereo mix, mono stays mono) and its length in frames.
    public static func openAudio(_ url: URL, sampleRate: Int) async throws -> (source: any AudioSource, totalFrames: Int64) {
        if MXFFile.isMXF(url) {
            let a = try await MXFAudioSource.open(url: url, sampleRate: sampleRate)
            return (a, a.totalFrames)
        }
        let a = try await WebMAudioSource.open(url: url, sampleRate: sampleRate)
        return (a, a.totalFrames)
    }

    public static func forEachFrame(demuxer demux: any Demuxing, range: TimeRange? = nil, scale: DecodeScale = .full,
                                    batch: Int = 12, deinterlace: FieldOrder? = nil,
                                    _ body: (DecodedFrame) async throws -> Void) async throws {
        guard let span = frameIndices(in: demux.index, range: range) else { return }
        let decoder = try VTVideoDecoder(demuxer: demux, media: UUID(), scale: scale, deinterlace: deinterlace)
        defer { decoder.invalidate() }
        var lo = span.lowerBound
        while lo <= span.upperBound {
            try Task.checkCancellation()
            let hi = min(span.upperBound, lo + max(1, batch) - 1)
            for frame in try await decoder.decode(lo...hi) { try await body(frame) }
            lo = hi + 1
        }
    }

    /// Writes the audio track as a float CAF (mono stays mono, everything else stereo) at `sampleRate`, for readers that
    /// open `AVAudioFile`s only (speech transcription). Throws `MediaError.unreadable` without audio.
    public static func writeAudioFile(from url: URL, to dest: URL, sampleRate: Int = 48_000,
                                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let (src, totalFrames) = try await openAudio(url, sampleRate: sampleRate)
        let channels: AVAudioChannelCount = src.isMono ? 1 : 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: channels, interleaved: false)
        else { throw MediaError.unreadable }
        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(forWriting: dest, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { throw MediaError.unreadable }
        var pos: Int64 = 0
        while pos < totalFrames {
            try Task.checkCancellation()
            var n = 0
            for c in 0..<Int(channels) {
                n = try src.read(from: pos, count: chunk, into: buf.floatChannelData![c], channel: c)
            }
            if n <= 0 { break }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            pos += Int64(n)
            progress?(min(1, Double(pos) / Double(max(1, totalFrames))))
        }
    }
}
