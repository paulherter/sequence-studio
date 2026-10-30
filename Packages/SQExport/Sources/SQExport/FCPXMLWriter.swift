import Foundation
import SQCore
import SQText

/// FCPXML 1.8 of a sequence: first video track as the primary storyline (gaps between clips), higher video tracks and
/// audio tracks as connected clips on lanes, a video clip with its linked audio as one asset clip, constant speed and
/// reverse as a `timeMap`, adjacent dissolves as `transition`, markers on the item under them. Text clips are written as
/// `title` elements (text, font, size, color, bold, italic, alignment; the rest of the look is not carried). Other
/// generators, nested sequences and effects are not exported (listed in `warnings`).
public enum FCPXMLWriter {
    /// DTD version written. 1.10 and later keep the media path in a `media-rep` child of the asset.
    public enum Version: String, Sendable, CaseIterable {
        case v1_8 = "1.8", v1_10 = "1.10", v1_13 = "1.13"
        var hasMediaRep: Bool { self != .v1_8 }
    }

    /// How times and formats are written. Resolve reads any reduced rational; Final Cut Pro wants frame-aligned
    /// times over the frame rate's own denominator ("10010/30000s", not "1001/3000s") and names the color space.
    public enum Target: String, Sendable, CaseIterable { case resolve, finalCut }

    /// Frame-aligned time over the frame duration's denominator; other times stay reduced.
    static func frameAlignedString(_ t: Time, fd: Time) -> String {
        guard fd.value > 0, fd.timescale > 0, t.timescale > 0 else { return timeString(t) }
        let num = Int128(t.value) * Int128(fd.timescale), den = Int128(t.timescale) * Int128(fd.value)
        guard num % den == 0 else { return timeString(t) }
        let frames = num / den
        if frames == 0 { return "0s" }
        return "\(frames * Int128(fd.value))/\(fd.timescale)s"
    }

    /// Rational time string ("1001/30000s", "5s", "0s"), reduced.
    static func timeString(_ t: Time) -> String {
        var v = t.value, s = t.timescale
        if v == 0 || s == 0 { return "0s" }
        var a = abs(v), b = s
        while b != 0 { (a, b) = (b, a % b) }
        v /= a; s /= a
        return s == 1 ? "\(v)s" : "\(v)/\(s)s"
    }

    static func escape(_ s: String) -> String {
        var r = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "'": r += "&apos;"
            default: if u.value >= 32 || u == "\t" { r.unicodeScalars.append(u) }
            }
        }
        return r
    }

    private struct Asset { var id: String; var media: MediaRef; var hasVideo: Bool; var hasAudio: Bool; var duration: Time }

    /// One element of the storyline or a connected clip, with what hangs off it.
    private struct Node {
        var clip: Clip?              // nil = gap
        var pos: Time
        var duration: Time
        var partner: Clip?           // linked audio folded into an asset clip
        var connected: [(clip: Clip, lane: Int, partner: Clip?)] = []
        var markers: [Marker] = []
    }

    /// The template of a text generator clip; nil for other generators or a payload this build cannot read.
    static func titleText(_ g: GeneratorRef) -> TextTemplate? {
        guard g.kind == GeneratorRef.text, let (t, _) = try? TextGenerator.decode(g) else { return nil }
        return t
    }

    /// FCPXML color attribute: "r g b a", at most 6 decimals, trailing zeros dropped.
    static func colorString(_ c: RGBAColor) -> String {
        func f(_ v: Double) -> String {
            var s = String(format: "%.6f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return "\(f(c.red)) \(f(c.green)) \(f(c.blue)) \(f(c.alpha))"
    }

    public static func render(_ timeline: Timeline, media: [MediaRef], version: Version = .v1_8,
                              target: Target = .resolve) -> InterchangeExport {
        let fd = timeline.format.frameDuration
        func timeString(_ t: Time) -> String { target == .finalCut ? frameAlignedString(t, fd: fd) : FCPXMLWriter.timeString(t) }
        var warnings = [String]()
        func warn(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }
        let byID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func usable(_ c: Clip) -> Bool {
            if let g = c.generator {
                if titleText(g) != nil {
                    if !c.isEnabled { warn("Disabled clip \"\(c.name)\" skipped") }
                    return c.isEnabled
                }
                warn("Generator clip \"\(c.name)\" is not exported"); return false
            }
            if c.isNested { warn("Nested sequence \"\(c.name)\" is not exported"); return false }
            if !c.isEnabled { warn("Disabled clip \"\(c.name)\" skipped"); return false }
            return true
        }
        let videoTracks = timeline.tracks.filter { $0.kind == .video }
        let audioTracks = timeline.tracks.filter { $0.kind == .audio }
        let videoClips = videoTracks.map { $0.clips.filter(usable) }
        var audioClips = audioTracks.map { $0.clips.filter(usable) }

        // A video clip takes the audio clip over the same media range as its sound.
        func partner(of v: Clip) -> Clip? {
            for (ti, list) in audioClips.enumerated() {
                if let i = list.firstIndex(where: {
                    $0.media == v.media && $0.start == v.start && $0.duration == v.duration && $0.source.start == v.source.start
                        && $0.speed == v.speed && $0.reversed == v.reversed
                }) {
                    return audioClips[ti].remove(at: i)
                }
            }
            return nil
        }

        var nodes = [Node]()
        var lanes = [(clip: Clip, lane: Int, partner: Clip?)]()
        for (ti, list) in videoClips.enumerated() {
            for c in list {
                let p = partner(of: c)
                if ti == 0 { nodes.append(Node(clip: c, pos: c.start, duration: c.duration, partner: p)) }
                else { lanes.append((c, ti, p)) }
            }
        }
        for (ti, list) in audioClips.enumerated() { for c in list { lanes.append((c, -(ti + 1), nil)) } }

        let total = (nodes.map { $0.pos + $0.duration } + lanes.map { $0.clip.timeline.end }).max() ?? .zero
        if total == .zero { warn("The sequence has no clips FCPXML can carry") }

        // Gaps between storyline clips, so the spine covers the whole sequence.
        var spine = [Node]()
        var cursor = Time.zero
        for n in nodes {
            if n.pos > cursor { spine.append(Node(clip: nil, pos: cursor, duration: n.pos - cursor, partner: nil)) }
            spine.append(n)
            cursor = n.pos + n.duration
        }
        if cursor < total { spine.append(Node(clip: nil, pos: cursor, duration: total - cursor, partner: nil)) }

        func owner(of t: Time) -> Int? { spine.firstIndex { $0.pos <= t && t < $0.pos + $0.duration } }
        for l in lanes.sorted(by: { ($0.lane, $0.clip.start) < ($1.lane, $1.clip.start) }) {
            if let i = owner(of: l.clip.start) { spine[i].connected.append(l) }
        }
        for m in timeline.markers {
            if let i = owner(of: m.time) { spine[i].markers.append(m) } else { warn("Marker \"\(m.name)\" lies outside the clips") }
        }

        // Resources: assets in the order of the media list, only those used.
        var used = [UUID: (video: Bool, audio: Bool, end: Time)]()
        func note(_ c: Clip, _ partnered: Bool) {
            if c.isGenerator { return }
            var u = used[c.media] ?? (false, false, .zero)
            if c.kind == .video { u.video = true }
            if c.kind == .audio || partnered { u.audio = true }
            u.end = max(u.end, c.source.end)
            used[c.media] = u
        }
        for n in spine {
            if let c = n.clip { note(c, n.partner != nil) }
            for l in n.connected { note(l.clip, l.partner != nil) }
        }
        var assets = [UUID: Asset]()
        var assetOrder = [Asset]()
        var nextID = 2
        func addAsset(_ m: MediaRef) {
            guard assets[m.id] == nil, let u = used[m.id] else { return }
            let video = (m.info?.video != nil) || u.video
            let audio = (m.info?.audio != nil) || u.audio
            let a = Asset(id: "r\(nextID)", media: m, hasVideo: video, hasAudio: audio,
                          duration: m.duration ?? m.info?.duration ?? u.end)
            nextID += 1
            assets[m.id] = a; assetOrder.append(a)
        }
        for m in media { addAsset(m) }
        for id in used.keys where assets[id] == nil {   // clip whose media is not in the list: placeholder asset
            warn("Media of a clip is missing from the project; written as an offline asset")
            addAsset(MediaRef(id: id, name: "Offline", path: "", fingerprint: MediaFingerprint(size: 0)))
        }

        let tcStart = timeline.timecodeStart
        let tcDrop = CMXTimecode(frameDuration: fd).dropFrame
        var x = [String]()
        func line(_ depth: Int, _ s: String) { x.append(String(repeating: "    ", count: depth) + s) }

        var needsDissolveEffect = false
        let needsTitleEffect = (videoClips.flatMap { $0 }).contains { $0.isGenerator }
        let titleFx = "r\(nextID)"
        var styleCount = 0
        func emit(_ n: Node, depth: Int, offset: Time, lane: Int?, partnered: Bool) {
            let hasChildren: Bool
            var attrs: String
            if let c = n.clip, let g = c.generator, let t = titleText(g) {
                styleCount += 1
                let ts = "ts\(styleCount)"
                var attrs = "ref=\"\(titleFx)\""
                if let l = lane { attrs += " lane=\"\(l)\"" }
                attrs += " offset=\"\(timeString(offset))\" name=\"\(escape(c.name))\" start=\"0s\" duration=\"\(timeString(n.duration))\""
                line(depth, "<title \(attrs)>")
                line(depth + 1, "<text><text-style ref=\"\(ts)\">\(t.text.split(separator: "\n", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "&#10;"))</text-style></text>")
                var style = "font=\"\(escape(t.style.fontName))\" fontSize=\"\(timeless(t.style.size))\" fontColor=\"\(colorString(t.style.color))\""
                if t.style.weight >= .bold { style += " bold=\"1\"" }
                if t.style.italic { style += " italic=\"1\"" }
                style += " alignment=\"\(t.style.alignment.rawValue)\""
                line(depth + 1, "<text-style-def id=\"\(ts)\"><text-style \(style)/></text-style-def>")
                children(n, depth: depth + 1, localStart: .zero)
                line(depth, "</title>")
                return
            }
            if let c = n.clip {
                let a = assets[c.media]
                let tag = partnered ? "asset-clip" : (c.kind == .video ? "video" : "audio")
                attrs = "ref=\"\(a?.id ?? "r0")\""
                if let l = lane { attrs += " lane=\"\(l)\"" }
                attrs += " offset=\"\(timeString(offset))\" name=\"\(escape(c.name))\" start=\"\(timeString(c.source.start))\" duration=\"\(timeString(n.duration))\""
                let map = timeMap(c)
                let own = c.holdFrame != nil ? [] : (c.markers ?? []).filter { $0.time >= c.source.start && $0.time < c.source.end }
                    .sorted { $0.time < $1.time }
                let channels = tag == "video" ? [] : channelSources(c)
                hasChildren = map != nil || !n.connected.isEmpty || !n.markers.isEmpty || !own.isEmpty || !channels.isEmpty
                if !hasChildren { line(depth, "<\(tag) \(attrs)/>"); return }
                line(depth, "<\(tag) \(attrs)>")
                if let m = map { for l in m { line(depth + 1, l) } }
                children(n, depth: depth + 1, localStart: c.source.start)
                for m in own { line(depth + 1, markerLine(m, start: m.time)) }
                for l in channels { line(depth + 1, l) }
                line(depth, "</\(tag)>")
            } else {
                attrs = "name=\"Gap\" offset=\"\(timeString(offset))\" start=\"0s\" duration=\"\(timeString(n.duration))\""
                hasChildren = !n.connected.isEmpty || !n.markers.isEmpty
                if !hasChildren { line(depth, "<gap \(attrs)/>"); return }
                line(depth, "<gap \(attrs)>")
                children(n, depth: depth + 1, localStart: .zero)
                line(depth, "</gap>")
            }
        }

        /// A point size without a trailing ".0".
        func timeless(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

        func children(_ n: Node, depth: Int, localStart: Time) {
            for l in n.connected {
                let child = Node(clip: l.clip, pos: l.clip.start, duration: l.clip.duration, partner: l.partner)
                emit(child, depth: depth, offset: localStart + (l.clip.start - n.pos), lane: l.lane, partnered: l.partner != nil)
            }
            for m in n.markers { line(depth, markerLine(m, start: localStart + (m.time - n.pos))) }
        }

        /// The channel choice of a clip's media as `audio-channel-source` (1-based source channel, output L/R). A plain
        /// stereo file or no choice writes nothing.
        func channelSources(_ c: Clip) -> [String] {
            guard let map = byID[c.media]?.info?.audio?.channelMap, !(map.left == [0] && map.right == [1]) else { return [] }
            return Set(map.left + map.right).sorted().map { ch in
                let l = map.left.contains(ch), r = map.right.contains(ch)
                let out = l && r ? "L, R" : (l ? "L" : "R")
                return "<audio-channel-source srcCh=\"\(ch + 1)\" outCh=\"\(out)\" active=\"1\"/>"
            }
        }

        func markerLine(_ m: Marker, start: Time) -> String {
            var s = "<marker start=\"\(timeString(start))\" duration=\"\(timeString(max(m.duration, fd)))\" value=\"\(escape(m.name))\""
            if !m.comment.isEmpty { s += " note=\"\(escape(m.comment))\"" }
            return s + "/>"
        }

        func timeMap(_ c: Clip) -> [String]? {
            if let h = c.holdFrame {
                return ["<timeMap>", "    <timept time=\"0s\" value=\"\(timeString(h))\" interp=\"linear\"/>",
                        "    <timept time=\"\(timeString(c.duration))\" value=\"\(timeString(h))\" interp=\"linear\"/>", "</timeMap>"]
            }
            var reversed = c.reversed
            var from = c.source.start, to = c.source.end
            if c.speedKeys != nil {
                reversed = false
                warn("Speed ramp on \"\(c.name)\" written at its average speed")
            }
            guard !c.speed.isNormal || reversed || c.speedKeys != nil else { return nil }
            if reversed { swap(&from, &to) }
            return ["<timeMap>", "    <timept time=\"0s\" value=\"\(timeString(from))\" interp=\"linear\"/>",
                    "    <timept time=\"\(timeString(c.duration))\" value=\"\(timeString(to))\" interp=\"linear\"/>", "</timeMap>"]
        }

        // Dissolves in the primary storyline: between two storyline clips that touch.
        var transitionAfter = [Int: [String]]()   // spine index -> transition lines placed after it
        if let first = videoTracks.first {
            for tr in first.transitions {
                guard let o = tr.outgoing, let i = tr.incoming,
                      let oi = spine.firstIndex(where: { $0.clip?.id == o }),
                      oi + 1 < spine.count, spine[oi + 1].clip?.id == i else {
                    warn("A transition that is not between two touching clips is not exported")
                    continue
                }
                let cut = spine[oi + 1].pos
                var start = cut
                switch tr.alignment {
                case .center: start = cut - tr.duration.halved.snapped(to: fd)
                case .startAtCut: start = cut
                case .endAtCut: start = cut - tr.duration
                case .custom: start = cut - tr.customBefore
                }
                if tr.kind != .crossDissolve && tr.kind != .quickFade {
                    warn("Transition \"\(tr.kind.rawValue)\" written as Cross Dissolve")
                }
                needsDissolveEffect = true
                transitionAfter[oi] = ["<transition name=\"Cross Dissolve\" offset=\"\(timeString(max(start, .zero) + tcStart))\" duration=\"\(timeString(tr.duration))\">",
                                       "    <filter-video ref=\"rfx\" name=\"Cross Dissolve\"/>", "</transition>"]
            }
        }

        let fx = "r\(nextID + (needsTitleEffect ? 1 : 0))"
        line(0, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        line(0, "<!DOCTYPE fcpxml>")
        line(0, "<fcpxml version=\"\(version.rawValue)\">")
        line(1, "<resources>")
        var formatAttrs = "id=\"r1\" frameDuration=\"\(timeString(fd))\" width=\"\(timeline.format.width)\" height=\"\(timeline.format.height)\""
        if target == .finalCut && version.hasMediaRep { formatAttrs += " colorSpace=\"1-1-1 (Rec. 709)\"" }
        line(2, "<format \(formatAttrs)/>")
        for a in assetOrder {
            let url = a.media.path.isEmpty ? "" : URL(fileURLWithPath: a.media.path).absoluteString
            var s = "<asset id=\"\(a.id)\" name=\"\(escape(a.media.name))\" start=\"0s\" duration=\"\(timeString(a.duration))\""
            s += " hasVideo=\"\(a.hasVideo ? 1 : 0)\" hasAudio=\"\(a.hasAudio ? 1 : 0)\""
            if a.hasVideo { s += " format=\"r1\"" }
            if url.isEmpty { line(2, s + "/>") }
            else if version.hasMediaRep {
                line(2, s + ">")
                line(3, "<media-rep kind=\"original-media\" src=\"\(escape(url))\"/>")
                line(2, "</asset>")
            } else {
                line(2, s + " src=\"\(escape(url))\"/>")
            }
        }
        if needsTitleEffect {
            line(2, "<effect id=\"\(titleFx)\" name=\"Basic Title\" uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>")
        }
        if needsDissolveEffect {
            line(2, "<effect id=\"\(fx)\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>")
        }
        line(1, "</resources>")
        line(1, "<library>")
        line(2, "<event name=\"Sequence Studio\">")
        line(3, "<project name=\"\(escape(timeline.name))\">")
        let rate = timeline.format.audioSampleRate
        line(4, "<sequence format=\"r1\" duration=\"\(timeString(total))\" tcStart=\"\(timeString(tcStart))\" tcFormat=\"\(tcDrop ? "DF" : "NDF")\" audioLayout=\"stereo\" audioRate=\"\(rate == 44_100 ? "44.1k" : rate == 96_000 ? "96k" : "48k")\">")
        line(5, "<spine>")
        for (i, n) in spine.enumerated() {
            emit(n, depth: 6, offset: n.pos + tcStart, lane: nil, partnered: n.partner != nil)
            if let t = transitionAfter[i] { for l in t { line(6, l.replacingOccurrences(of: "rfx", with: fx)) } }
        }
        line(5, "</spine>")
        line(4, "</sequence>")
        line(3, "</project>")
        line(2, "</event>")
        line(1, "</library>")
        line(0, "</fcpxml>")
        return InterchangeExport(text: x.joined(separator: "\n") + "\n", warnings: warnings)
    }
}
