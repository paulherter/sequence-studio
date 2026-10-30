import Foundation
import SQCore

/// Final Cut Pro 7 XML (xmeml version 4, the form Premiere and Resolve import) of a sequence: every video and audio
/// track as a `<track>` of clip items (start / end on the sequence, in / out in the file), file definitions once and
/// referenced by id, constant speed and reverse as a Time Remap filter, dissolves and fades as transition items,
/// sequence markers. Titles, generators, nested sequences and disabled clips are skipped and listed in `warnings`.
/// Written from the public xmeml description; no third-party code.
public enum XMEMLWriter {
    public static func render(_ timeline: Timeline, media: [MediaRef]) -> InterchangeExport {
        let fd = timeline.format.frameDuration
        var warnings = [String]()
        func warn(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }
        func frames(_ t: Time) -> Int64 { (t + fd.halved).frameIndex(frameDuration: fd) }
        let byID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // timebase + ntsc flag
        let fps = Double(fd.timescale) / Double(max(fd.value, 1))
        let base = Int64(fps.rounded())
        let ntsc = fd == Time(1001, base * 1000)
        if !ntsc && fd != Time(1, base) { warn("Frame rate is not a whole or NTSC rate; written as \(base) fps") }
        let esc = FCPXMLWriter.escape

        var x = [String]()
        func line(_ depth: Int, _ s: String) { x.append(String(repeating: "  ", count: depth) + s) }
        func rate(_ depth: Int) {
            line(depth, "<rate><timebase>\(base)</timebase><ntsc>\(ntsc ? "TRUE" : "FALSE")</ntsc></rate>")
        }

        func usable(_ c: Clip) -> Bool {
            if c.isGenerator { warn("Text and generator clips are not exported (\"\(c.name)\")"); return false }
            if c.isNested { warn("Nested sequence \"\(c.name)\" is not exported"); return false }
            if !c.isEnabled { warn("Disabled clip \"\(c.name)\" skipped"); return false }
            return true
        }

        var fileIDs = [UUID: String]()
        // Item ids and positions up front, so a clip can name the partners it is linked to on other tracks.
        struct Slot { var id: String; var kind: TrackKind; var trackIndex: Int; var clipIndex: Int }
        var slots = [UUID: Slot]()
        var linkMembers = [UUID: [UUID]]()   // link group -> clip ids in export order
        do {
            var n = 0, v = 0, a = 0
            for t in timeline.tracks {
                if t.kind == .video { v += 1 } else { a += 1 }
                var k = 0
                for c in t.clips where !c.isGenerator && !c.isNested && c.isEnabled {
                    n += 1; k += 1
                    slots[c.id] = Slot(id: "clipitem-\(n)", kind: t.kind, trackIndex: t.kind == .video ? v : a, clipIndex: k)
                    if let l = c.link { linkMembers[l, default: []].append(c.id) }
                }
            }
        }
        var itemCount = 0
        /// Speed as percent text: "200", "33.3333".
        func percent(_ s: ClipSpeed) -> String {
            let whole = s.num * 100
            if whole % s.den == 0 { return "\(whole / s.den)" }
            let scaled = (Int128(s.num) * 1_000_000 + Int128(s.den) / 2) / Int128(s.den)   // percent with 4 decimals
            var text = "\(scaled / 10_000)." + String(format: "%04d", Int(scaled % 10_000))
            while text.hasSuffix("0") { text.removeLast() }
            return text
        }

        func fileElement(_ c: Clip, depth: Int, hasVideo: Bool, hasAudio: Bool) {
            if let id = fileIDs[c.media] { line(depth, "<file id=\"\(id)\"/>"); return }
            let id = "file-\(fileIDs.count + 1)"
            fileIDs[c.media] = id
            let m = byID[c.media]
            if m == nil { warn("Media of a clip is missing from the project; written without a path") }
            line(depth, "<file id=\"\(id)\">")
            line(depth + 1, "<name>\(esc(m?.name ?? c.name))</name>")
            if let p = m?.path, !p.isEmpty {
                line(depth + 1, "<pathurl>\(esc(URL(fileURLWithPath: p).absoluteString))</pathurl>")
            }
            rate(depth + 1)
            if let d = m?.duration ?? m?.info?.duration { line(depth + 1, "<duration>\(frames(d))</duration>") }
            line(depth + 1, "<media>")
            if hasVideo { line(depth + 2, "<video/>") }
            if hasAudio {
                if let ch = m?.info?.audio?.channels, ch > 0 { line(depth + 2, "<audio><channelcount>\(ch)</channelcount></audio>") }
                else { line(depth + 2, "<audio/>") }
            }
            line(depth + 1, "</media>")
            line(depth, "</file>")
        }

        func transitionItem(_ t: Transition, track: Track, clips: [Clip], depth: Int) {
            let out = t.outgoing.flatMap { id in clips.first { $0.id == id } }
            let inc = t.incoming.flatMap { id in clips.first { $0.id == id } }
            var start: Time, alignment = "center"
            switch (out, inc) {
            case (let o?, let i?):
                guard o.timeline.end == i.start else {
                    warn("A transition that is not between two touching clips is not exported"); return
                }
                let cut = i.start
                switch t.alignment {
                case .center: start = cut - t.duration.halved.snapped(to: fd)
                case .startAtCut: start = cut; alignment = "start"
                case .endAtCut: start = cut - t.duration; alignment = "end"
                case .custom: start = cut - t.customBefore
                }
            case (let o?, nil):
                start = o.timeline.end - t.duration; alignment = "end-black"
            case (nil, let i?):
                start = i.start; alignment = "start-black"
            default: return
            }
            var name = "Cross Dissolve", cat = "Dissolve"
            if track.kind == .audio {
                name = t.kind == .constantGain ? "Cross Fade (0dB)" : "Cross Fade (+3dB)"; cat = "Crossfade"
            } else {
                switch t.kind {
                case .crossDissolve, .quickFade: break
                case .dipToBlack: name = "Dip to Black"
                case .dipToWhite: name = "Dip to White"
                default: warn("Transition \"\(t.kind.rawValue)\" written as Cross Dissolve")
                }
            }
            let s = max(frames(start), 0)
            line(depth, "<transitionitem>")
            line(depth + 1, "<start>\(s)</start><end>\(s + max(frames(t.duration), 1))</end>")
            line(depth + 1, "<alignment>\(alignment)</alignment>")
            rate(depth + 1)
            line(depth + 1, "<effect><name>\(name)</name><effectid>\(name)</effectid><effectcategory>\(cat)</effectcategory><effecttype>transition</effecttype><mediatype>\(track.kind == .audio ? "audio" : "video")</mediatype></effect>")
            line(depth, "</transitionitem>")
        }

        func trackElement(_ t: Track, depth: Int) {
            let clips = t.clips.filter(usable)
            line(depth, "<track>")
            for (i, c) in clips.enumerated() {
                // A transition in front of the clip goes before it (cut between two clips, or a fade-in).
                for tr in t.transitions where tr.incoming == c.id {
                    if tr.outgoing == nil || (i > 0 && clips[i - 1].id == tr.outgoing) {
                        transitionItem(tr, track: t, clips: clips, depth: depth + 1)
                    }
                }
                itemCount += 1
                line(depth + 1, "<clipitem id=\"\(slots[c.id]?.id ?? "clipitem-\(itemCount)")\">")
                line(depth + 2, "<name>\(esc(c.name))</name>")
                line(depth + 2, "<enabled>TRUE</enabled>")
                let hold = c.holdFrame
                let inF = frames(hold ?? c.source.start)
                let outF = hold != nil ? inF + max(frames(c.duration), 1) : frames(c.source.end)
                if hold != nil { warn("Hold frame on \"\(c.name)\" written as plain playback from that frame") }
                line(depth + 2, "<duration>\(max(frames(c.duration), 1))</duration>")
                rate(depth + 2)
                line(depth + 2, "<start>\(frames(c.start))</start><end>\(frames(c.timeline.end))</end>")
                line(depth + 2, "<in>\(inF)</in><out>\(outF)</out>")
                fileElement(c, depth: depth + 2, hasVideo: t.kind == .video, hasAudio: t.kind == .audio)
                if t.kind == .audio {
                    // The file channel this clip plays (a split channel is a mono map; 1-based in the file).
                    var channel = 0
                    if let map = byID[c.media]?.info?.audio?.channelMap {
                        channel = map.left.first ?? map.right.first ?? 0
                        if map.layout == .custom || map.layout == .dualMono { warn("Channel choice on \"\(c.name)\" written as its first channel") }
                    }
                    line(depth + 2, "<sourcetrack><mediatype>audio</mediatype><trackindex>\(channel + 1)</trackindex></sourcetrack>")
                }
                var speed = c.speed, reversed = c.reversed
                if c.speedKeys != nil {
                    speed = c.averageSpeed; reversed = false
                    warn("Speed ramp on \"\(c.name)\" written at its average speed")
                }
                if hold == nil, !speed.isNormal || reversed {
                    line(depth + 2, "<filter><effect><name>Time Remap</name><effectid>timeremap</effectid><effectcategory>motion</effectcategory><effecttype>motion</effecttype><mediatype>video</mediatype>")
                    line(depth + 3, "<parameter><parameterid>speed</parameterid><name>speed</name><value>\(reversed ? "-" : "")\(percent(speed))</value></parameter>")
                    line(depth + 2, "</effect></filter>")
                }
                if hold == nil {
                    for m in (c.markers ?? []).sorted(by: { $0.time < $1.time }) where m.time >= c.source.start && m.time < c.source.end {
                        let i = frames(m.time)
                        line(depth + 2, "<marker><name>\(esc(m.name))</name><comment>\(esc(m.comment))</comment><in>\(i)</in><out>\(m.duration > .zero ? i + max(frames(m.duration), 1) : -1)</out></marker>")
                    }
                }
                if let g = c.link, let members = linkMembers[g], members.count > 1 {
                    for id in members {
                        guard let sl = slots[id] else { continue }
                        line(depth + 2, "<link><linkclipref>\(sl.id)</linkclipref><mediatype>\(sl.kind == .video ? "video" : "audio")</mediatype><trackindex>\(sl.trackIndex)</trackindex><clipindex>\(sl.clipIndex)</clipindex></link>")
                    }
                }
                line(depth + 1, "</clipitem>")
                for tr in t.transitions where tr.outgoing == c.id && tr.incoming == nil {
                    transitionItem(tr, track: t, clips: clips, depth: depth + 1)
                }
            }
            line(depth, "</track>")
        }

        let video = timeline.tracks.filter { $0.kind == .video }, audio = timeline.tracks.filter { $0.kind == .audio }
        let total = timeline.tracks.flatMap(\.clips).filter { $0.isEnabled && !$0.isGenerator && !$0.isNested }
            .map { $0.timeline.end }.max() ?? .zero
        if total == .zero { warn("The sequence has no clips Final Cut Pro XML can carry") }
        let tc = CMXTimecode(frameDuration: fd)
        let tcFrames = frames(timeline.timecodeStart)

        line(0, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        line(0, "<!DOCTYPE xmeml>")
        line(0, "<xmeml version=\"4\">")
        line(1, "<sequence id=\"sequence-1\">")
        line(2, "<name>\(esc(timeline.name))</name>")
        line(2, "<duration>\(frames(total))</duration>")
        rate(2)
        line(2, "<timecode>")
        rate(3)
        line(3, "<string>\(tc.string(frames: tcFrames))</string><frame>\(tcFrames)</frame><displayformat>\(tc.dropFrame ? "DF" : "NDF")</displayformat>")
        line(2, "</timecode>")
        for m in timeline.markers.sorted(by: { $0.time < $1.time }) {
            let i = frames(m.time)
            line(2, "<marker><name>\(esc(m.name))</name><comment>\(esc(m.comment))</comment><in>\(i)</in><out>\(m.duration > .zero ? i + max(frames(m.duration), 1) : -1)</out></marker>")
        }
        line(2, "<media>")
        line(3, "<video>")
        line(4, "<format><samplecharacteristics>")
        rate(5)
        line(5, "<width>\(timeline.format.width)</width><height>\(timeline.format.height)</height><pixelaspectratio>square</pixelaspectratio>")
        line(4, "</samplecharacteristics></format>")
        for t in video { trackElement(t, depth: 4) }
        line(3, "</video>")
        line(3, "<audio>")
        line(4, "<numOutputChannels>2</numOutputChannels>")
        line(4, "<format><samplecharacteristics><depth>16</depth><samplerate>\(timeline.format.audioSampleRate)</samplerate></samplecharacteristics></format>")
        for t in audio { trackElement(t, depth: 4) }
        line(3, "</audio>")
        line(2, "</media>")
        line(1, "</sequence>")
        line(0, "</xmeml>")
        return InterchangeExport(text: x.joined(separator: "\n") + "\n", warnings: warnings)
    }
}
