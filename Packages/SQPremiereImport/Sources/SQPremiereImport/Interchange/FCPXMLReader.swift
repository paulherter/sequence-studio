import Foundation
import SQCore

/// FCPXML 1.x (Final Cut Pro X and compatible exporters) -> `IXSequence`: the first project's sequence, its primary
/// storyline (asset clips, clips, video / audio items, gaps, cross dissolves), connected clips (lane > 0 on video
/// tracks above, lane < 0 and the audio of video clips on audio tracks), retiming from `timeMap`, and markers.
/// Titles, compound / multicam clips and generators are dropped into the report.
enum FCPXMLReader {
    struct Asset {
        var name: String
        var path: String
        var start: Time
        var duration: Time?
        var hasVideo: Bool
        var hasAudio: Bool
    }

    /// "1001/30000s", "5s", "0s" (also a plain decimal such as "2.5s") as a rational.
    static func time(_ s: String?) -> Time? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasSuffix("s") { t.removeLast() }
        let parts = t.split(separator: "/", omittingEmptySubsequences: false)
        func int(_ x: Substring) -> Int64? { Int64(x) }
        if parts.count == 2, let n = int(parts[0]), let d = int(parts[1]), d > 0 { return Time(n, d) }
        if parts.count == 1 {
            if let n = int(parts[0]) { return Time(n, 1) }
            if let r = EDLReader.ratio(String(parts[0])) { return Time(t.hasPrefix("-") ? -abs(r.num) : r.num, r.den) }
        }
        return nil
    }

    static func read(_ data: Data, name: String) throws -> IXSequence {
        guard let first = try readAll(data, name: name).first else { throw InterchangeError.malformed("no sequence") }
        return first
    }

    /// Every project's sequence (or, without projects, every sequence outside the resources: compound clips live there).
    static func readAll(_ data: Data, name: String) throws -> [IXSequence] {
        let root = try IXNode.parse(data)
        guard root.name == "fcpxml" else { throw InterchangeError.unsupported("not an FCPXML file") }
        var assets = [String: Asset](), formats = [String: IXNode]()
        for r in root.child("resources")?.children ?? [] {
            guard let id = r.attributes["id"] else { continue }
            switch r.name {
            case "format": formats[id] = r
            case "asset":
                let src = r.attributes["src"] ?? r.child("media-rep")?.attributes["src"] ?? ""
                let path = InterchangePath.path(fromURL: src)
                assets[id] = Asset(name: r.attributes["name"] ?? (path as NSString).lastPathComponent, path: path,
                                   start: time(r.attributes["start"]) ?? .zero, duration: time(r.attributes["duration"]),
                                   hasVideo: r.attributes["hasVideo"] != "0", hasAudio: r.attributes["hasAudio"] != "0")
            default: break
            }
        }
        var found = [(project: IXNode?, sequence: IXNode)]()
        for p in root.descendants("project") { if let q = p.child("sequence") { found.append((p, q)) } }
        if found.isEmpty {
            for c in root.children where c.name != "resources" { for q in c.descendants("sequence") { found.append((nil, q)) } }
        }
        guard !found.isEmpty else { throw InterchangeError.malformed("no sequence") }
        return try found.map { try sequence($0.sequence, project: $0.project, root: root, assets: assets, formats: formats, name: name) }
    }

    private static func sequence(_ sequence: IXNode, project: IXNode?, root: IXNode, assets: [String: Asset],
                                 formats: [String: IXNode], name: String) throws -> IXSequence {
        let format = sequence.attributes["format"].flatMap { formats[$0] }
        let fd = time(format?.attributes["frameDuration"]) ?? Time(1, 25)
        var seq = IXSequence(name: project?.attributes["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name, frameDuration: fd,
                             width: Int(format?.attributes["width"] ?? "") ?? 1920,
                             height: Int(format?.attributes["height"] ?? "") ?? 1080)
        guard let spine = sequence.child("spine") else { throw InterchangeError.malformed("no spine") }
        var w = Walker(assets: assets, fd: fd, tcStart: time(sequence.attributes["tcStart"]) ?? .zero)
        w.spine(spine)
        seq.tracks = w.video + w.audio
        seq.markers = w.markers
        for e in w.report.entries { for _ in 0..<e.count { seq.report.note(e.feature, e.status, e.note) } }
        return seq
    }

    struct Walker {
        let assets: [String: Asset]
        let fd: Time
        let tcStart: Time
        var video = [IXTrack](), audio = [IXTrack]()
        var markers = [IXMarker]()
        var report = PRImportReport()
        /// A transition waiting for the next primary clip.
        var pending: (lane: Int, outgoing: Int, duration: Time, name: String)?

        init(assets: [String: Asset], fd: Time, tcStart: Time) { self.assets = assets; self.fd = fd; self.tcStart = tcStart }

        mutating func place(_ kind: TrackKind, preferred: Int, start: Time, end: Time) -> Int {
            var lane = max(preferred, 0)
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

        mutating func spine(_ s: IXNode) {
            for n in s.children {
                if n.name == "transition" {
                    guard let d = FCPXMLReader.time(n.attributes["duration"]) else { continue }
                    // Joined to the clips on either side when the next clip arrives.
                    if let last = lastPrimary { pending = (last.lane, last.index, d, n.attributes["name"] ?? "") }
                    continue
                }
                guard let off = FCPXMLReader.time(n.attributes["offset"]) else { continue }
                let pos = off >= tcStart ? off - tcStart : off
                item(n, at: pos, lane: 0, primary: true)
            }
        }

        var lastPrimary: (lane: Int, index: Int)?

        mutating func item(_ n: IXNode, at pos: Time, lane: Int, primary: Bool) {
            let duration = FCPXMLReader.time(n.attributes["duration"]) ?? .zero
            let localStart = FCPXMLReader.time(n.attributes["start"]) ?? .zero
            switch n.name {
            case "asset-clip", "clip", "video", "audio":
                if duration > .zero { media(n, at: pos, lane: lane, primary: primary, duration: duration) }
            case "gap":
                break
            case "title", "caption":
                report.note("Title", .dropped, "titles are not read from FCPXML")
            case "ref-clip", "mc-clip", "sync-clip":
                report.note("Compound or multicam clip", .dropped, "not read from FCPXML")
            default:
                return
            }
            for c in n.children {
                switch c.name {
                case "marker", "chapter-marker":
                    guard let s = FCPXMLReader.time(c.attributes["start"]) else { continue }
                    let at = pos + (s - localStart)
                    guard at >= .zero else { continue }
                    markers.append(IXMarker(time: at, name: c.attributes["value"] ?? "", comment: c.attributes["note"] ?? "",
                                            duration: c.name == "marker" ? (FCPXMLReader.time(c.attributes["duration"]).flatMap { $0 > fd ? $0 : nil } ?? .zero) : .zero))
                default:
                    guard let l = c.attributes["lane"].flatMap({ Int($0) }), l != 0,
                          let o = FCPXMLReader.time(c.attributes["offset"]) else { continue }
                    item(c, at: pos + (o - localStart), lane: l, primary: false)
                }
            }
        }

        mutating func media(_ n: IXNode, at pos: Time, lane: Int, primary: Bool, duration: Time) {
            // A `clip` container holds its media as a video / audio child.
            var carrier = n
            if n.name == "clip" {
                guard let inner = n.children.first(where: { ($0.name == "video" || $0.name == "audio") && $0.attributes["ref"] != nil }) else {
                    report.note("Clip without media", .dropped); return
                }
                carrier = inner
            }
            guard let ref = carrier.attributes["ref"], let asset = assets[ref] else {
                report.note("Generator", .dropped, "effects, solids and generators are not read from FCPXML"); return
            }
            if n.attributes["enabled"] == "0" { report.note("Disabled clip", .dropped); return }
            let clipStart = FCPXMLReader.time(n.attributes["start"]) ?? FCPXMLReader.time(carrier.attributes["start"]) ?? asset.start
            var sourceIn = clipStart - asset.start
            var speed = ClipSpeed.normal, reversed = false
            var duration = duration
            var keys: SpeedKeys?
            if let map = n.child("timeMap") {
                let pts = map.children("timept").compactMap { p -> (Time, Time)? in
                    guard let t = FCPXMLReader.time(p.attributes["time"]), let v = FCPXMLReader.time(p.attributes["value"]) else { return nil }
                    return (t, v)
                }
                let smooth = map.children("timept").contains { ($0.attributes["interp"] ?? "linear") != "linear" }
                if pts.count > 2, let k = FCPXMLReader.speedKeys(points: pts, duration: duration, fd: fd, assetStart: asset.start) {
                    keys = k
                    duration = k.duration
                    sourceIn = k.hull.start
                    report.note("Speed", smooth ? .approximated : .mapped,
                                smooth ? "eased ramp imported as constant steps" : "speed ramp imported as retime keys")
                } else if let a = pts.first, let b = pts.last, b.0 > a.0, b.1 != a.1 {
                    let dv = b.1 - a.1, dt = b.0 - a.0
                    reversed = dv < .zero
                    speed = ClipSpeed(source: reversed ? -dv : dv, over: dt)
                    sourceIn = min(a.1, b.1) - asset.start
                    report.note("Speed", pts.count > 2 ? .approximated : .mapped, pts.count > 2 ? "speed ramp played at its average speed" : "")
                }
            }
            if sourceIn < .zero { sourceIn = .zero }
            let name = n.attributes["name"] ?? asset.name
            let baseClip = IXClip(name: name, mediaKey: asset.path, mediaName: asset.name, start: pos, duration: duration,
                              sourceIn: sourceIn, speed: speed, reversed: reversed, mediaDuration: asset.duration)
            var clip = baseClip
            clip.speedKeys = keys
            let audioOnly = n.name == "audio" || carrier.name == "audio" || !asset.hasVideo
            if !audioOnly {
                let l = place(.video, preferred: lane, start: pos, end: pos + duration)
                video[l].clips.append(clip)
                let idx = video[l].clips.count - 1
                if primary {
                    if let p = pending, p.lane == l, p.outgoing < idx {
                        video[l].transitions.append(IXTransition(
                            kind: .crossDissolve, duration: p.duration, alignment: .center, outgoing: p.outgoing, incoming: idx))
                        if !p.name.isEmpty && !p.name.lowercased().contains("dissolve") {
                            report.note("Transition \(p.name)", .approximated, "played as Cross Dissolve")
                        }
                    }
                    pending = nil
                    lastPrimary = (l, idx)
                }
            }
            // A `video` element is the picture alone (the writer emits it when the sound is not on the timeline).
            if audioOnly || (asset.hasAudio && n.name != "video" && carrier.name != "video") {
                let l = place(.audio, preferred: abs(lane), start: pos, end: pos + duration)
                var sound = clip
                sound.sourceChannel = FCPXMLReader.sourceChannel(of: n) ?? FCPXMLReader.sourceChannel(of: carrier)
                audio[l].clips.append(sound)
            }
        }
    }

    /// The one file channel (0-based) an `audio-channel-source` picks, from `srcCh="2"`. Nil when none is given, when it
    /// lists several channels (stereo and pairs play as the file does), or when several different active ones are named.
    static func sourceChannel(of n: IXNode) -> Int? {
        let active = n.children("audio-channel-source").filter { $0.attributes["active"] != "0" }
        var channels = Set<Int>()
        for a in active {
            let list = (a.attributes["srcCh"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard list.count == 1, let ch = list.first, ch >= 1 else { return nil }
            channels.insert(ch - 1)
        }
        return channels.count == 1 ? channels.first : nil
    }

    /// A timeMap with three or more points as a speed track: one constant segment per point pair (FCP keys are linear in
    /// media time, so the segments are exact), boundaries on whole frames, the length of the clip. Nil when a pair is
    /// a freeze or runs backwards in time: the caller then plays the average speed.
    static func speedKeys(points: [(Time, Time)], duration: Time, fd: Time, assetStart: Time) -> SpeedKeys? {
        let total = duration.snapped(to: fd)
        guard let first = points.first, total > .zero else { return nil }
        var segments = [SpeedSegment]()
        var cursor = Time.zero
        var speeds = Set<ClipSpeed>()
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.0 - a.0, dv = b.1 - a.1
            guard dt > .zero, dv != .zero else { return nil }
            let end = min((b.0 - first.0).snapped(to: fd), total)
            guard end > cursor else { continue }
            let speed = ClipSpeed(source: dv < .zero ? .zero - dv : dv, over: dt)
            speeds.insert(speed)
            segments.append(SpeedSegment(duration: end - cursor, from: speed, reversed: dv < .zero))
            cursor = end
            if cursor >= total { break }
        }
        guard !segments.isEmpty else { return nil }
        if cursor < total {
            // The map ends before the clip does: the last speed goes on.
            segments[segments.count - 1].duration += total - cursor
        }
        let reversed = segments.map(\.reversed)
        guard speeds.count > 1 || Set(reversed).count > 1 else { return nil }   // one constant speed: plain speed fields
        let origin = first.1 - assetStart
        return SpeedKeys(segments: segments, origin: origin < .zero ? .zero : origin)
    }
}
