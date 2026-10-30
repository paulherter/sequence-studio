import Foundation
import SQCore

/// CMX3600 EDL -> `IXSequence`. An EDL carries no frame rate and (usually) no media paths: the rate comes from the
/// caller, the clips are named by `* FROM CLIP NAME:` / `* SOURCE FILE:` comments and come in offline until relinked.
/// Source timecode is taken as media time (the media is assumed to start at 00:00:00:00). Record timecode that begins
/// in hour 1 or later (the 01:00:00:00 convention) has that whole-hour offset removed.
public enum EDLReader {
    struct Event {
        var number: String
        var reel: String
        var trackSpec: String
        var type: String
        var transitionFrames: Int64 = 0
        var srcIn: Int64, srcOut: Int64, recIn: Int64, recOut: Int64
        var motionFPS: String?
        var fromName: String?, toName: String?, sourceFile: String?
    }

    public static func read(_ text: String, name: String, frameDuration fd: Time) throws -> IXSequence {
        var title: String?
        var drop = false
        var events = [Event]()
        var locs = [(tc: String, text: String)]()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true)
        // First pass: the drop-frame flag and the title must be known before any timecode is read.
        for l in lines {
            let line = l.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("FCM:") { drop = line.uppercased().contains("DROP") && !line.uppercased().contains("NON") }
            if line.uppercased().hasPrefix("TITLE:") { title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        }
        let tc = CMXTimecode(frameDuration: fd, preferDrop: false)
        let clock = CMXTimecode(nominalRate: tc.nominalRate, dropFrame: drop)
        var last: Int?
        for l in lines {
            let line = l.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first else { continue }
            if first.hasPrefix("*") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                let upper = body.uppercased()
                if upper.hasPrefix("LOC:") {
                    let rest = body.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
                    if let t = parts.first { locs.append((t, parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : "")) }
                } else if let i = last {
                    func value(_ prefix: String) -> String? {
                        upper.hasPrefix(prefix) ? body.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : nil
                    }
                    if let v = value("FROM CLIP NAME:") { events[i].fromName = v }
                    else if let v = value("TO CLIP NAME:") { events[i].toName = v }
                    else if let v = value("SOURCE FILE:") { events[i].sourceFile = v }
                }
                continue
            }
            if first.uppercased() == "M2", tokens.count >= 3, let i = last {
                events[i].motionFPS = tokens[2]
                continue
            }
            // Event: number reel track type [duration] srcIn srcOut recIn recOut
            guard first.allSatisfy(\.isNumber), tokens.count >= 8 else { continue }
            let stamps = tokens.filter { $0.contains(":") || $0.contains(";") }
            guard stamps.count >= 4 else { continue }
            let t = Array(stamps.suffix(4))
            guard let si = clock.frames(t[0]), let so = clock.frames(t[1]), let ri = clock.frames(t[2]), let ro = clock.frames(t[3]) else { continue }
            var e = Event(number: first, reel: tokens[1], trackSpec: tokens[2].uppercased(), type: tokens[3].uppercased(),
                          srcIn: si, srcOut: so, recIn: ri, recOut: ro)
            if e.type != "C", tokens.count > 4, let n = Int64(tokens[4]) { e.transitionFrames = n }
            events.append(e)
            last = events.count - 1
        }
        guard !events.isEmpty else { throw InterchangeError.empty }

        var seq = IXSequence(name: title.flatMap { $0.isEmpty ? nil : $0 } ?? name, frameDuration: fd)
        seq.report.note("Frame rate", .approximated, "an EDL has no rate: \(clock.nominalRate) fps clock")
        // Hour offset of the record side.
        let hour = clock.frames("01:00:00:00") ?? 1
        let minRec = events.filter { $0.recOut > $0.recIn }.map(\.recIn).min() ?? 0
        let base = hour > 0 ? (minRec / hour) * hour : 0
        func time(_ frames: Int64) -> Time { fd * frames }

        var video = [IXTrack](), audio = [IXTrack]()
        /// First lane (from `preferred`) of `kind` that is free over [start, end).
        func place(_ kind: TrackKind, preferred: Int, start: Time, end: Time) -> Int {
            var lane = preferred
            while true {
                if kind == .video {
                    while video.count <= lane { video.append(IXTrack(kind: .video)) }
                    if !video[lane].clips.contains(where: { $0.start < end && start < $0.end }) { return lane }
                } else {
                    while audio.count <= lane { audio.append(IXTrack(kind: .audio)) }
                    if !audio[lane].clips.contains(where: { $0.start < end && start < $0.end }) { return lane }
                }
                lane += 1
            }
        }

        for e in events {
            let start = time(e.recIn - base), duration = time(e.recOut - e.recIn)
            guard duration > .zero else { continue }   // the zero-length cut that precedes a dissolve
            if e.reel.uppercased() == "BL" { continue }  // black
            let name = e.toName ?? e.fromName ?? e.reel
            let key = e.sourceFile.flatMap { $0.isEmpty ? nil : $0 } ?? (e.fromName ?? e.toName ?? e.reel)
            var speed = ClipSpeed.normal, reversed = false
            if let f = e.motionFPS, let r = Self.ratio(f) {
                speed = ClipSpeed(num: abs(r.num) * fd.value, den: r.den * fd.timescale)
                reversed = r.num < 0
            }
            var srcIn = time(e.srcIn)
            if reversed {   // the listed In is the last frame shown; the range starts below it
                srcIn = max(srcIn - speed.scale(duration), .zero)
            }
            let clip = IXClip(name: name, mediaKey: key, mediaName: (key as NSString).lastPathComponent,
                              start: start, duration: duration, sourceIn: srcIn, speed: speed, reversed: reversed)
            let spec = e.trackSpec
            let wantsVideo = spec == "B" || spec.contains("V") && !spec.hasPrefix("NONE")
            var audioLanes = [Int]()
            if spec == "B" { audioLanes = [0] }
            else if spec.hasPrefix("AA") { audioLanes = [0, 1] }
            else if spec.hasPrefix("A") {
                let digits = spec.dropFirst().prefix { $0.isNumber }
                audioLanes = [max((Int(digits) ?? 1) - 1, 0)]
            }
            if spec.contains("/V") && spec.hasPrefix("A") && audioLanes.isEmpty { audioLanes = [0] }
            if wantsVideo {
                var preferred = 0
                if e.type != "C" {
                    // A dissolve's incoming clip joins the lane of the clip it comes from.
                    if let i = video.firstIndex(where: { $0.clips.contains { $0.end == start } }) { preferred = i }
                }
                let lane = place(.video, preferred: preferred, start: start, end: clip.end)
                video[lane].clips.append(clip)
                if e.type != "C" {
                    let into = video[lane].clips.count - 1
                    let out = video[lane].clips.firstIndex { $0.end == start }
                    if e.transitionFrames > 0 {
                        if e.type.hasPrefix("W") { seq.report.note("Wipe", .approximated, "played as Cross Dissolve") }
                        video[lane].transitions.append(IXTransition(duration: time(e.transitionFrames), alignment: .startAtCut,
                                                                    outgoing: out, incoming: into))
                    }
                }
            }
            for a in audioLanes {
                let lane = place(.audio, preferred: a, start: start, end: clip.end)
                let out = e.type != "C" ? audio[lane].clips.firstIndex { $0.end == start } : nil
                audio[lane].clips.append(clip)
                // An audio dissolve is a crossfade between the clip before and this one.
                if let out, e.transitionFrames > 0 {
                    audio[lane].transitions.append(IXTransition(kind: .constantPower, duration: time(e.transitionFrames),
                                                                alignment: .startAtCut, outgoing: out,
                                                                incoming: audio[lane].clips.count - 1))
                }
            }
        }
        seq.tracks = video + audio
        seq.markers = locs.compactMap { l in
            clock.frames(l.tc).map { IXMarker(time: time(max($0 - base, 0)), name: l.text) }
        }
        return seq
    }

    /// "050.0" / "-24" / "12.5" as a rational (numerator signed, denominator a power of ten).
    static func ratio(_ s: String) -> (num: Int64, den: Int64)? {
        let neg = s.hasPrefix("-")
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = Int64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var frac: Int64 = 0, den: Int64 = 1
        if parts.count == 2 {
            let f = String(parts[1].prefix(6))
            guard f.allSatisfy(\.isNumber) else { return nil }
            frac = Int64(f) ?? 0
            for _ in f { den *= 10 }
        }
        let n = whole * den + frac
        guard n > 0 else { return nil }
        return (neg ? -n : n, den)
    }
}
