import Foundation
import SQCore

/// Final Cut Pro 7 XML (xmeml, also written by Premiere "Export Final Cut Pro XML") -> `IXSequence`: the first
/// sequence, its video and audio tracks (clip items with start / end / in / out, file path, speed from a time-remap
/// filter), transitions with cut position, and sequence / clip markers. Generators and nested sequences are dropped.
enum XMEMLReader {
    static func read(_ data: Data, name: String) throws -> IXSequence {
        guard let first = try readAll(data, name: name).first else { throw InterchangeError.malformed("no sequence") }
        return first
    }

    /// Every sequence of the file, not the ones nested inside a clip item (those play where they are used).
    static func readAll(_ data: Data, name: String) throws -> [IXSequence] {
        let root = try IXNode.parse(data)
        guard root.name == "xmeml" else { throw InterchangeError.unsupported("not a Final Cut Pro XML file") }
        var found = [IXNode]()
        func walk(_ n: IXNode) {
            for c in n.children {
                if c.name == "sequence" { found.append(c) } else if c.name != "clipitem" { walk(c) }
            }
        }
        walk(root)
        if found.isEmpty, let any = root.descendants("sequence").first { found = [any] }
        guard !found.isEmpty else { throw InterchangeError.malformed("no sequence") }
        return found.map { sequence($0, root: root, name: name) }
    }

    private static func sequence(_ sequence: IXNode, root: IXNode, name: String) -> IXSequence {
        let fd = frameDuration(of: sequence.child("rate")) ?? Time(1, 25)
        let format = sequence.child("media")?.child("video")?.child("format")?.child("samplecharacteristics")
        var seq = IXSequence(name: sequence.text("name").flatMap { $0.isEmpty ? nil : $0 } ?? name, frameDuration: fd,
                             width: Int(format?.int("width") ?? 1920), height: Int(format?.int("height") ?? 1080))
        // A file is defined in full once and referenced by id later.
        var files = [String: IXNode]()
        for f in root.descendants("file") {
            guard let id = f.attributes["id"] else { continue }
            if files[id] == nil || f.child("pathurl") != nil { files[id] = f }
        }
        let groups = linkGroups(sequence)
        for (kind, group) in [(TrackKind.video, "video"), (TrackKind.audio, "audio")] {
            for t in sequence.child("media")?.child(group)?.children("track") ?? [] {
                seq.tracks.append(track(t, kind: kind, fd: fd, files: files, groups: groups, seq: &seq))
            }
        }
        for m in sequence.children("marker") {
            guard let t = m.int("in"), t >= 0 else { continue }
            seq.markers.append(IXMarker(time: fd * t, name: m.text("name") ?? "", comment: m.text("comment") ?? "",
                                        duration: duration(m, fd: fd)))
        }
        return seq
    }

    /// timebase + ntsc flag -> frame duration.
    static func frameDuration(of rate: IXNode?) -> Time? {
        guard let base = rate?.int("timebase"), base > 0 else { return nil }
        let ntsc = rate?.text("ntsc")?.uppercased() == "TRUE"
        return ntsc ? Time(1001, base * 1000) : Time(1, base)
    }

    private static func duration(_ marker: IXNode, fd: Time) -> Time {
        guard let i = marker.int("in"), let o = marker.int("out"), o > i, i >= 0 else { return .zero }
        return fd * (o - i)
    }

    /// `<link>` elements: clipitem id -> group name (the smallest id of the connected set).
    static func linkGroups(_ sequence: IXNode) -> [String: String] {
        var parent = [String: String]()
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        for item in sequence.descendants("clipitem") {
            guard let id = item.attributes["id"] else { continue }
            for l in item.children("link") {
                guard let ref = l.text("linkclipref"), !ref.isEmpty else { continue }
                let a = find(id), b = find(ref)
                if a != b { parent[max(a, b)] = min(a, b); parent[min(a, b)] = min(a, b) }
                else { parent[a] = a }
            }
        }
        var out = [String: String]()
        for k in parent.keys { out[k] = find(k) }
        return out
    }

    private static func track(_ t: IXNode, kind: TrackKind, fd: Time, files: [String: IXNode], groups: [String: String],
                              seq: inout IXSequence) -> IXTrack {
        var track = IXTrack(kind: kind)
        let items = t.children.filter { ["clipitem", "transitionitem", "generatoritem"].contains($0.name) }
        /// Where a transition's cut lies, from its alignment.
        func cut(_ tr: IXNode) -> Time? {
            guard let s = tr.int("start"), let e = tr.int("end") else { return nil }
            switch tr.text("alignment")?.lowercased() ?? "center" {
            case "start", "start-black": return fd * s
            case "end", "end-black": return fd * e
            default: return fd * s + (fd * (e - s)).halved.snapped(to: fd)
            }
        }
        var indexOfItem = [Int: Int]()   // item position -> clip index
        for (i, item) in items.enumerated() {
            guard item.name == "clipitem" else {
                if item.name == "generatoritem" { seq.report.note("Generator", .dropped, "titles, bars and solids are not read from XML") }
                continue
            }
            if item.text("enabled")?.uppercased() == "FALSE" {
                seq.report.note("Disabled clip", .dropped); continue
            }
            let file = item.child("file").flatMap { f -> IXNode? in
                if f.child("pathurl") != nil || f.child("name") != nil { return f }
                return f.attributes["id"].flatMap { files[$0] } ?? f
            }
            if item.child("sequence") != nil && file == nil {
                seq.report.note("Nested sequence", .dropped, "not read from XML"); continue
            }
            guard file != nil || item.text("name") != nil else { continue }
            let itemFD = frameDuration(of: item.child("rate")) ?? frameDuration(of: file?.child("rate")) ?? fd
            var start = item.int("start") ?? -1, end = item.int("end") ?? -1
            var startTime = fd * start, endTime = fd * end
            if start < 0, i > 0, items[i - 1].name == "transitionitem", let c = cut(items[i - 1]) { startTime = c; start = 0 }
            if end < 0, i + 1 < items.count, items[i + 1].name == "transitionitem", let c = cut(items[i + 1]) { endTime = c; end = 0 }
            guard start >= 0, end >= 0, endTime > startTime else {
                seq.report.note("Clip without position", .dropped); continue
            }
            let inFrame = item.int("in") ?? 0
            var speed = ClipSpeed.normal, reversed = false
            var retimed = false
            for f in item.children("filter") {
                guard f.child("effect")?.text("effectid")?.lowercased() == "timeremap" else { continue }
                for p in f.child("effect")?.children("parameter") ?? [] {
                    switch p.text("parameterid")?.lowercased() {
                    case "speed":
                        if let v = p.text("value").flatMap(EDLReader.ratio), v.num != 0 {
                            // percent: num/den % -> num/(den*100)
                            speed = ClipSpeed(num: abs(v.num), den: v.den * 100); retimed = true
                            if v.num < 0 { reversed = true }
                        }
                    case "reverse": if p.text("value")?.uppercased() == "TRUE" { reversed = true; retimed = true }
                    default: break
                    }
                }
            }
            if retimed { seq.report.note("Speed", .mapped) }
            var key: String, mediaName: String
            if let p = file?.text("pathurl"), !p.isEmpty {
                key = InterchangePath.path(fromURL: p)
                mediaName = file?.text("name") ?? (key as NSString).lastPathComponent
            } else {
                mediaName = file?.text("name") ?? item.text("name") ?? "Media"
                key = mediaName
            }
            let fileDuration = file?.int("duration").map { (frameDuration(of: file?.child("rate")) ?? itemFD) * $0 }
            let clipName = item.text("name") ?? mediaName
            indexOfItem[i] = track.clips.count
            var ixClip = IXClip(name: clipName, mediaKey: key, mediaName: mediaName, start: startTime,
                                duration: endTime - startTime, sourceIn: itemFD * inFrame, speed: speed,
                                reversed: reversed, mediaDuration: fileDuration)
            ixClip.linkGroup = item.attributes["id"].flatMap { groups[$0] }
            if kind == .audio, let idx = item.child("sourcetrack")?.int("trackindex"), idx >= 1 {
                ixClip.sourceChannel = Int(idx) - 1
            }
            track.clips.append(ixClip)
            // Clip markers (source time) land on the timeline where the clip shows that frame.
            for m in item.children("marker") {
                guard let at = m.int("in"), at >= inFrame else { continue }
                let local = speed.unscale(itemFD * (at - inFrame))
                guard local < endTime - startTime else { continue }
                seq.markers.append(IXMarker(time: startTime + local, name: m.text("name") ?? "", comment: m.text("comment") ?? ""))
            }
        }
        // Transitions between the clip items before and after them.
        for (i, item) in items.enumerated() where item.name == "transitionitem" {
            guard let s = item.int("start"), let e = item.int("end"), e > s, let c = cut(item) else { continue }
            let out = (0..<i).reversed().first { indexOfItem[$0] != nil }.flatMap { indexOfItem[$0] }
            let inc = ((i + 1)..<max(items.count, i + 1)).first { indexOfItem[$0] != nil }.flatMap { indexOfItem[$0] }
            let label = (item.child("effect")?.text("name") ?? item.child("effect")?.text("effectid") ?? "").lowercased()
            var kind = TransitionKind.crossDissolve
            if track.kind == .audio {
                kind = label.contains("0db") ? .constantGain : .constantPower
            } else if label.contains("dip") && label.contains("white") { kind = .dipToWhite }
            else if label.contains("dip") || label.contains("fade") { kind = .dipToBlack }
            else if !label.isEmpty && !label.contains("dissolve") {
                seq.report.note("Transition \(item.child("effect")?.text("name") ?? label)", .approximated, "played as Cross Dissolve")
            }
            let length = fd * (e - s)
            var alignment = TransitionAlignment.center
            if c == fd * s { alignment = .startAtCut } else if c == fd * e { alignment = .endAtCut }
            track.transitions.append(IXTransition(kind: kind, duration: length, alignment: alignment, outgoing: out, incoming: inc))
        }
        return track
    }
}
