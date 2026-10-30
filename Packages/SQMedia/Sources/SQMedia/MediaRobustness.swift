import CoreVideo
import Foundation
import SQCore

/// W6.3: robustness check of one media file through the engine's own import and decode path (MediaImporter, AVDemuxer,
/// VTVideoDecoder, AssetAudioSource). Used by the SQMedia corpus tests and `EngineBench validate`.
public enum MediaRobustness {
    public struct AudioReport: Sendable {
        /// `AssetAudioSource.isMono` (playback duplicates mono onto both sides).
        public var isMono: Bool
        /// A block at the start and one shortly before the end were read on both output channels.
        public var readable: Bool
        /// Output channel 0 and 1 carried identical samples in both reads (required for mono).
        public var channelsIdentical: Bool
    }

    /// Sequence-frame walk of the media (looped back to back) on a sequence of another rate, through `Clip.sourceTime`
    /// and the render loop's frame pick (`SampleIndex.frame(at:)`, clamped).
    public struct Conform: Sendable {
        public var sequenceFrames = 0
        /// Largest (sequence time - shown frame's start), in frames of the shown frame. < 1 = never a frame behind.
        public var maxLagFrames = 0.0
        /// Lag at the last sequence frame (drift at the end of `length`).
        public var endDriftFrames = 0.0
        /// Media frames shown twice in a row (slower media rate) / never shown (faster media rate).
        public var repeatedFrames = 0, skippedFrames = 0
    }

    public struct Report: Sendable {
        public var url: URL
        public var info: MediaInfo
        public var frameCount = 0
        /// Container duration (asset) and frame-table duration (sum of frames).
        public var containerDuration: Time
        public var indexDuration: Time = .zero
        /// |container - index| in nominal frames.
        public var durationErrorFrames = 0.0
        public var firstFrame: DecodedFrame?, lastFrame: DecodedFrame?
        public var decodedPixelFormat: OSType?
        public var hardwareDecode = false
        public var audio: AudioReport?
        public var conform: Conform?
        /// Human-readable failures; empty = file is sound.
        public var problems: [String] = []
        public var isSound: Bool { problems.isEmpty }
    }

    /// Imports `url`, decodes its first and last frame, compares durations, reads audio at both ends and, when
    /// `conformOnto` is given, walks `conformLength` of a sequence at that frame duration.
    public static func check(_ url: URL, conformOnto sequenceFrameDuration: Time? = nil,
                             conformLength: Time = Time(600, 1)) async throws -> Report {
        let (_, info) = try await MediaImporter.probe(url)
        var r = Report(url: url, info: info, containerDuration: info.duration)

        if let v = info.video, !info.isStill {
            let demux = try await AVDemuxer(url: url)
            let idx = demux.index
            r.frameCount = idx.count
            r.indexDuration = idx.duration
            r.durationErrorFrames = ratio(abs(info.duration - idx.duration), v.nominalFrameDuration)
            if r.durationErrorFrames > 1 {
                r.problems.append("duration: container \(seconds(info.duration)) s vs frames \(seconds(idx.duration)) s (\(fmt(r.durationErrorFrames)) frames)")
            }
            // First and last frame actually shown (an edit list may hide samples, SampleIndex).
            if let first = idx.entries.firstIndex(where: { $0.duration > .zero }),
               let last = idx.entries.lastIndex(where: { $0.duration > .zero }) {
                let dec = try makeVideoDecoder(demuxer: demux, media: UUID())
                r.hardwareDecode = dec.isHardware
                do {
                    r.firstFrame = try await dec.decode(first...first).first
                    dec.invalidate()   // fresh start for the last frame (a real seek, as the playhead would do)
                    r.lastFrame = try await dec.decode(last...last).first
                } catch {
                    r.problems.append("decode: \(error)")
                }
                dec.invalidate()
                for (name, f, e) in [("first", r.firstFrame, idx.entries[first]), ("last", r.lastFrame, idx.entries[last])] {
                    guard let f else { r.problems.append("\(name) frame: not decoded"); continue }
                    if f.pts != e.pts { r.problems.append("\(name) frame: pts \(f.pts) != \(e.pts)") }
                    let w = CVPixelBufferGetWidth(f.pixelBuffer), h = CVPixelBufferGetHeight(f.pixelBuffer)
                    if w != v.width || h != v.height { r.problems.append("\(name) frame: \(w)x\(h), expected \(v.width)x\(v.height)") }
                }
                r.decodedPixelFormat = r.firstFrame.map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
                if let s = sequenceFrameDuration { r.conform = conform(index: idx, sequenceFrameDuration: s, length: conformLength) }
            } else {
                r.problems.append("no video frames")
            }
        }

        if let a = info.audio {
            r.audio = try await audioReport(url, channels: a.channels, duration: info.duration, problems: &r.problems)
        }
        return r
    }

    private static func audioReport(_ url: URL, channels: Int, duration: Time, problems: inout [String]) async throws -> AudioReport {
        let rate = 48_000
        let src: AssetAudioSource
        do { src = try await AssetAudioSource.open(url: url, sampleRate: rate) } catch {
            problems.append("audio: cannot open (\(error))")
            return AudioReport(isMono: false, readable: false, channelsIdentical: false)
        }
        if src.isMono != (channels == 1) { problems.append("audio: \(channels) channels but isMono=\(src.isMono)") }
        let total = duration.value * Int64(rate) / duration.timescale
        let n = 4800
        var readable = true, identical = true
        for start in [Int64(0), max(0, total - Int64(rate) / 2)] {
            var l = [Float](repeating: 0, count: n), rr = [Float](repeating: 0, count: n)
            let nl = try l.withUnsafeMutableBufferPointer { try src.read(from: start, count: n, into: $0.baseAddress!, channel: 0) }
            let nr = try rr.withUnsafeMutableBufferPointer { try src.read(from: start, count: n, into: $0.baseAddress!, channel: 1) }
            if nl == 0 || nr == 0 { readable = false; problems.append("audio: nothing read at frame \(start) (\(nl)/\(nr))") }
            if nl != nr || l[0..<nl] != rr[0..<nr] { identical = false }
        }
        if channels == 1 && !identical { problems.append("audio: mono source differs between output channels") }
        return AudioReport(isMono: src.isMono, readable: readable, channelsIdentical: identical)
    }

    /// See `Conform`. The media is placed as back-to-back copies (each `index.duration` long) from time 0.
    public static func conform(index: SampleIndex, sequenceFrameDuration fd: Time, length: Time) -> Conform {
        var c = Conform()
        guard index.count > 0, index.duration > .zero, fd > .zero else { return c }
        let d = index.duration
        var copy: Int64 = 0
        var clip = Clip(name: "conform", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: d),
                        start: .zero, mediaDuration: d)
        var prev: Int64?
        var n: Int64 = 0
        while fd * n < length {
            let t = fd * n
            while t >= clip.start + d { copy += 1; clip.start = d * copy }
            let s = clip.sourceTime(at: t, frameDuration: fd)
            let f = index.frame(at: s) ?? (s < index.entries[0].pts ? 0 : index.count - 1)
            let e = index.entries[f]
            let lag = ratio(s - e.pts, e.duration)
            c.maxLagFrames = max(c.maxLagFrames, Swift.abs(lag))
            c.endDriftFrames = lag
            let g = copy * Int64(index.count) + Int64(f)
            if let p = prev {
                if g == p { c.repeatedFrames += 1 } else if g > p + 1 { c.skippedFrames += Int(g - p - 1) }
            }
            prev = g
            n += 1
        }
        c.sequenceFrames = Int(n)
        return c
    }

    private static func abs(_ t: Time) -> Time { t < .zero ? -t : t }
    /// a / b as a Double (reporting only; time stays rational).
    private static func ratio(_ a: Time, _ b: Time) -> Double {
        b.value == 0 ? 0 : (Double(a.value) * Double(b.timescale)) / (Double(a.timescale) * Double(b.value))
    }
    private static func seconds(_ t: Time) -> String { fmt(Double(t.value) / Double(t.timescale)) }
    private static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
}
