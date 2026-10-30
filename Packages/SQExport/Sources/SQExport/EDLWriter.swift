import Foundation
import SQCore

/// Text of an interchange file plus what could not be carried (shown to the user after the export).
public struct InterchangeExport: Sendable, Equatable {
    public var text: String
    public var warnings: [String]
    /// Set when the text could not be produced; `write(to:)` then throws instead of writing a broken file.
    public var failure: String?
    public init(text: String, warnings: [String], failure: String? = nil) {
        self.text = text; self.warnings = warnings; self.failure = failure
    }

    /// Writes the file. Throws when the text is incomplete or the disk write fails, so the caller never reports an
    /// export that did not happen.
    public func write(to url: URL) throws {
        if let failure { throw InterchangeExportError.failed(failure) }
        let data = Data(text.utf8)
        do { try data.write(to: url, options: .atomic) } catch { throw InterchangeExportError.writeFailed(url.lastPathComponent, "\(error)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard size == data.count else { throw InterchangeExportError.writeFailed(url.lastPathComponent, "the file is incomplete") }
    }
}

public enum InterchangeExportError: Error, Equatable, LocalizedError {
    case failed(String)
    case writeFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .failed(let s): "The file could not be created: \(s)"
        case .writeFailed(let name, let why): "Could not write \(name): \(why)"
        }
    }
}

/// CMX3600 EDL of a sequence: the first video track as `V` events, every audio track as `A` / `A2` ... events, record
/// timecode starting at the sequence's timecode start, source timecode as media time. Dissolves are written the usual
/// way (a zero-length cut plus a `D` event). Constant speed and reverse go into an `M2` line. Markers become `* LOC:`.
/// An EDL cannot carry layers, effects, titles or nested sequences: those are skipped and listed in `warnings`.
/// A video track above V1 is not in this file: `layerFiles` renders one more EDL per such track (its clips as `V`).
public enum EDLWriter {
    /// Video tracks above V1 that hold at least one clip an EDL can carry: (track number counted over video tracks, so
    /// V2 = 1, its name for the file).
    public static func layerFiles(_ timeline: Timeline, media: [MediaRef]) -> [(label: String, export: InterchangeExport)] {
        var out = [(String, InterchangeExport)]()
        var index = 0
        for t in timeline.tracks where t.kind == .video {
            defer { index += 1 }
            guard index > 0, t.clips.contains(where: usableQuiet) else { continue }
            out.append(("V\(index + 1)", render(timeline, media: media, videoLayer: index)))
        }
        return out
    }

    /// `videoLayer` 0 = the sequence EDL (V1, all audio, markers). N > 0 = only the Nth video track, as `V`, no audio.
    public static func render(_ timeline: Timeline, media: [MediaRef], videoLayer: Int = 0) -> InterchangeExport {
        let fd = timeline.format.frameDuration
        let tc = CMXTimecode(frameDuration: fd)
        let paths = Dictionary(media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        var warnings = [String]()
        func warn(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }
        func frames(_ t: Time) -> Int64 { (t + fd.halved).frameIndex(frameDuration: fd) }
        let base = frames(timeline.timecodeStart)
        func stamp(_ f: Int64) -> String { tc.string(frames: f) }

        var out = ["TITLE: " + clean(timeline.name) + (videoLayer > 0 ? " V\(videoLayer + 1)" : ""), "FCM: " + (tc.dropFrame ? "DROP FRAME" : "NON-DROP FRAME"), ""]
        var number = 0

        func event(_ n: Int, _ track: String, _ type: String, _ si: Int64, _ so: Int64, _ ri: Int64, _ ro: Int64) -> String {
            String(format: "%03d", n) + "  " + pad("AX", 8) + " " + pad(track, 5) + " " + pad(type, 8) + " "
                + [stamp(si), stamp(so), stamp(ri + base), stamp(ro + base)].joined(separator: " ")
        }

        /// Source in / out (in frames) and the M2 rate of a clip.
        func source(_ c: Clip) -> (inF: Int64, outF: Int64, fps: String?) {
            if let h = c.holdFrame { let f = frames(h); return (f, f, "000.0") }
            var speed = c.speed, reversed = c.reversed
            if c.speedKeys != nil {
                speed = c.averageSpeed; reversed = false
                warn("Speed ramp on \"\(c.name)\" written at its average speed")
            }
            let a = frames(c.source.start), b = frames(c.source.end)
            let rate = speed.isNormal && !reversed ? nil : fps(speed, fd: fd, reversed: reversed)
            return reversed ? (b, a, rate) : (a, b, rate)
        }

        func comments(_ c: Clip, to: Bool = false) {
            out.append((to ? "* TO CLIP NAME: " : "* FROM CLIP NAME: ") + clean(c.name))
            if let p = paths[c.media], !p.isEmpty { out.append("* SOURCE FILE: " + clean(p)) }
        }

        func usable(_ c: Clip) -> Bool {
            if c.isGenerator { warn("Text and generator clips are not exported (\"\(c.name)\")"); return false }
            if c.isNested { warn("Nested sequence \"\(c.name)\" is not exported"); return false }
            if !c.isEnabled { warn("Disabled clip \"\(c.name)\" skipped"); return false }
            return true
        }

        var videoIndex = 0, audioIndex = 0
        for t in timeline.tracks {
            let clips = t.clips.filter(usable)
            if t.kind == .video {
                defer { videoIndex += 1 }
                if videoIndex != videoLayer {
                    if videoLayer == 0, !clips.isEmpty {
                        warn("Video tracks above V1 are not in this EDL (an EDL has one video track): one more EDL is written per layer")
                    }
                    continue
                }
                var previous: Clip?
                for c in clips {
                    number += 1
                    let s = source(c)
                    let ri = frames(c.start), ro = frames(c.timeline.end)
                    if let p = previous, let tr = t.transitions.first(where: { $0.incoming == c.id && $0.outgoing == p.id }),
                       p.timeline.end == c.start, p.generator == nil {
                        let dur = max(frames(tr.duration), 1)
                        let prior = source(p)
                        out.append(event(number, "V", "C", prior.outF, prior.outF, ri, ri))
                        comments(p)
                        out.append(event(number, "V", "D    " + String(format: "%03d", dur), s.inF, s.outF, ri, ro))
                        if let r = s.fps { out.append(m2(r, s.inF, tc)) }
                        comments(c, to: true)
                        if tr.kind != .crossDissolve { warn("Transition \"\(tr.kind.rawValue)\" written as a dissolve") }
                        if tr.alignment != .startAtCut { warn("Dissolves are written starting at the cut") }
                    } else {
                        out.append(event(number, "V", "C", s.inF, s.outF, ri, ro))
                        if let r = s.fps { out.append(m2(r, s.inF, tc)) }
                        comments(c)
                    }
                    previous = c
                }
                for tr in t.transitions where tr.outgoing == nil || tr.incoming == nil {
                    warn("Fade at a clip edge is not exported")
                    break
                }
            } else {
                if videoLayer > 0 { continue }
                let lane = audioIndex; audioIndex += 1
                let spec = lane == 0 ? "A" : "A\(lane + 1)"
                var previous: Clip?
                for c in clips {
                    number += 1
                    let s = source(c)
                    let ri = frames(c.start), ro = frames(c.timeline.end)
                    if let p = previous, let tr = t.transitions.first(where: { $0.incoming == c.id && $0.outgoing == p.id }),
                       p.timeline.end == c.start, p.generator == nil {
                        let prior = source(p)
                        out.append(event(number, spec, "C", prior.outF, prior.outF, ri, ri))
                        comments(p)
                        out.append(event(number, spec, "D    " + String(format: "%03d", max(frames(tr.duration), 1)), s.inF, s.outF, ri, ro))
                        if let r = s.fps { out.append(m2(r, s.inF, tc)) }
                        comments(c, to: true)
                        if tr.alignment != .startAtCut { warn("Dissolves are written starting at the cut") }
                    } else {
                        out.append(event(number, spec, "C", s.inF, s.outF, ri, ro))
                        if let r = s.fps { out.append(m2(r, s.inF, tc)) }
                        comments(c)
                    }
                    previous = c
                }
                if t.transitions.contains(where: { $0.outgoing == nil || $0.incoming == nil }) {
                    warn("Audio fade at a clip edge is not exported")
                }
            }
        }
        // Clip markers are written where the clip shows them (an EDL has no marker on a clip).
        var markers = videoLayer > 0 ? [] : timeline.markers
        for t in timeline.tracks where videoLayer == 0 {
            for c in t.clips where usableQuiet(c) {
                markers += c.visibleMarkers(frameDuration: fd).map {
                    Marker(time: c.start + $0.time, name: $0.name, color: $0.color, comment: $0.comment)
                }
            }
        }
        for m in markers.sorted(by: { $0.time < $1.time }) {
            out.append("* LOC: \(stamp(frames(m.time) + base)) \(color(m.color)) \(clean(m.name))")
        }
        if number == 0 { warn("The sequence has no clips an EDL can carry") }
        return InterchangeExport(text: out.joined(separator: "\n") + "\n", warnings: warnings)
    }

    private static func usableQuiet(_ c: Clip) -> Bool { !c.isGenerator && !c.isNested && c.isEnabled }

    private static func m2(_ rate: String, _ srcIn: Int64, _ tc: CMXTimecode) -> String {
        "M2   AX       " + pad(rate, 20) + " " + tc.string(frames: srcIn)
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    /// One line, no control characters.
    private static func clean(_ s: String) -> String {
        s.unicodeScalars.map { $0.value < 32 ? " " : String($0) }.joined().trimmingCharacters(in: .whitespaces)
    }

    private static func color(_ c: MarkerColor) -> String {
        switch c {
        case .red: "RED"
        case .green: "GREEN"
        case .blue: "BLUE"
        case .cyan: "CYAN"
        case .purple: "MAGENTA"
        case .yellow, .orange: "YELLOW"
        case .white: "WHITE"
        }
    }

    /// Frames per second the clip plays at (speed x sequence rate), exact to 6 decimals: "050.0", "-029.97003".
    static func fps(_ speed: ClipSpeed, fd: Time, reversed: Bool) -> String {
        let den = Int128(speed.den) * Int128(max(fd.value, 1))
        let scaled = (Int128(speed.num) * Int128(fd.timescale) * 1_000_000 + den / 2) / max(den, 1)
        let whole = scaled / 1_000_000, frac = scaled % 1_000_000
        var f = String(frac)
        f = String(repeating: "0", count: 6 - f.count) + f
        while f.count > 1, f.hasSuffix("0") { f.removeLast() }
        let w = String(whole)
        return (reversed ? "-" : "") + String(repeating: "0", count: max(3 - w.count, 0)) + w + "." + f
    }
}
