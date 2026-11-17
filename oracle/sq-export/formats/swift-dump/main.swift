import Foundation
import SQCore
import SQText

// Writes the golden files of crates/sq-export/src/formats: the real Swift writers on fixed scenarios.
// The scenarios are mirrored by crates/sq-export/src/formats/tests.rs; change both together.

public enum RangeSelection { case entireSequence; case inOut(TimeRange) }

let outDir = CommandLine.arguments[1]

func put(_ name: String, _ text: String) {
    try! text.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8)
}
func emit(_ name: String, _ e: InterchangeExport) {
    put(name + ".out", e.text)
    put(name + ".warn", e.warnings.joined(separator: "\n"))
    if let f = e.failure { put(name + ".fail", f) }
}

let fd = Time(1, 25)
let ntsc = Time(1001, 30_000)
func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

let a = MediaRef(id: id(1), name: "A001.mov", path: "/Volumes/Shoot/A001.mov", fingerprint: MediaFingerprint(size: 1))
let b = MediaRef(id: id(2), name: "B & C.mov", path: "/Volumes/Shoot/B & C.mov", fingerprint: MediaFingerprint(size: 1))
let tricky = MediaRef(id: id(3), name: "T\u{EB}st <x>.mov", path: "/Volumes/My Disk/T\u{4E2D}st #1 [a]%20;b'c\"d?e|f\\g^h`i{j}k.mov",
                      fingerprint: MediaFingerprint(size: 1))

func clip(_ m: MediaRef, _ kind: TrackKind, src: Int64, dur: Int64, at: Int64, speed: ClipSpeed = .normal, reversed: Bool = false,
          link: UUID? = nil, name: String? = nil, fd f: Time = fd, cid: Int) -> Clip {
    Clip(id: id(cid), name: name ?? m.name, media: m.id, kind: kind, source: TimeRange(start: f * src, duration: f * dur),
         start: f * at, link: link, speed: speed, reversed: reversed)
}
func timeline(_ name: String, _ tracks: [Track], fd f: Time = fd) -> Timeline {
    Timeline(id: id(900), name: name, format: SequenceFormat(width: 1920, height: 1080, frameDuration: f), tracks: tracks)
}
func all(_ prefix: String, _ tl: Timeline, _ media: [MediaRef]) {
    emit(prefix + "-edl", EDLWriter.render(tl, media: media))
    for (label, e) in EDLWriter.layerFiles(tl, media: media) { emit(prefix + "-edl-" + label, e) }
    emit(prefix + "-xmeml", XMEMLWriter.render(tl, media: media))
    emit(prefix + "-fcpxml", FCPXMLWriter.render(tl, media: media))
    emit(prefix + "-fcpxml-fcp110", FCPXMLWriter.render(tl, media: media, version: .v1_10, target: .finalCut))
    emit(prefix + "-otio", OTIOWriter.render(tl, media: media))
}

// 1 basic
do {
    let link = id(800)
    let v1 = Track(id: id(11), kind: .video, clips: [
        clip(a, .video, src: 250, dur: 125, at: 0, link: link, cid: 101),
        clip(b, .video, src: 0, dur: 100, at: 125, speed: ClipSpeed(num: 2, den: 1), name: "Fast & Loud", cid: 102)])
    let v2 = Track(id: id(12), kind: .video, clips: [clip(b, .video, src: 25, dur: 25, at: 10, cid: 103)])
    let a1 = Track(id: id(13), kind: .audio, clips: [clip(a, .audio, src: 250, dur: 125, at: 0, link: link, cid: 104)])
    let a2 = Track(id: id(14), kind: .audio, clips: [clip(b, .audio, src: 0, dur: 25, at: 0, cid: 105)])
    var tl = timeline("Cut & \"Co\"", [v1, v2, a1, a2])
    tl.markers = [Marker(id: id(201), time: fd * 25, name: "Beat", comment: "drum"),
                  Marker(id: id(202), time: fd * 50, name: "Range <x>", color: .red, comment: "two", duration: fd * 20)]
    all("basic", tl, [a, b])
}

// 2 dissolves, audio crossfade, a fade at an edge
do {
    let c1 = clip(a, .video, src: 0, dur: 50, at: 0, cid: 111), c2 = clip(a, .video, src: 100, dur: 50, at: 50, cid: 112)
    let c3 = clip(b, .video, src: 0, dur: 25, at: 100, cid: 113)
    var v = Track(id: id(21), kind: .video, clips: [c1, c2, c3])
    v.transitions = [Transition(id: id(301), kind: .crossDissolve, duration: fd * 10, alignment: .center, outgoing: c1.id, incoming: c2.id),
                     Transition(id: id(302), kind: .push, duration: fd * 5, alignment: .endAtCut, outgoing: c2.id, incoming: c3.id),
                     Transition(id: id(303), kind: .dipToBlack, duration: fd * 8, alignment: .startAtCut, outgoing: c3.id, incoming: nil)]
    let d1 = clip(a, .audio, src: 0, dur: 50, at: 0, cid: 114), d2 = clip(b, .audio, src: 0, dur: 50, at: 50, cid: 115)
    var au = Track(id: id(22), kind: .audio, clips: [d1, d2])
    au.transitions = [Transition(id: id(304), kind: .constantGain, duration: fd * 10, alignment: .custom, customBefore: fd * 4, outgoing: d1.id, incoming: d2.id),
                      Transition(id: id(305), kind: .constantPower, duration: fd * 6, alignment: .center, outgoing: nil, incoming: d1.id)]
    all("dissolve", timeline("Dissolves", [v, au]), [a, b])
}

// 3 NTSC drop frame, timecode start, reverse, hold, clip markers, channel choice, rational speed
do {
    var m = a
    m.info = MediaInfo(duration: ntsc * 5000, video: nil, audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "AAC", channelMap: AudioChannelMap.mono(1)))
    m.duration = ntsc * 5000
    var dual = b
    dual.info = MediaInfo(duration: ntsc * 900, video: nil, audio: AudioTrackInfo(sampleRate: 48_000, channels: 4, codec: "AAC", channelMap: AudioChannelMap.dualMono(0, 2)))
    var rev = clip(a, .video, src: 100, dur: 30, at: 1800, reversed: true, fd: ntsc, cid: 121)
    rev.markers = [Marker(id: id(211), time: ntsc * 110, name: "Inside", color: .cyan, comment: "c,1"),
                   Marker(id: id(212), time: ntsc * 500, name: "Outside")]
    var held = clip(b, .video, src: 20, dur: 15, at: 1830, fd: ntsc, cid: 122)
    held.holdFrame = ntsc * 24
    let slow = clip(a, .video, src: 0, dur: 30, at: 1845, speed: ClipSpeed(num: 1, den: 3), fd: ntsc, cid: 123)
    let odd = clip(b, .video, src: 0, dur: 30, at: 1900, speed: ClipSpeed(num: 3, den: 2), reversed: true, fd: ntsc, cid: 124)
    let v = Track(id: id(31), kind: .video, clips: [rev, held, slow, odd])
    let au = Track(id: id(32), kind: .audio, clips: [clip(m, .audio, src: 0, dur: 60, at: 1800, fd: ntsc, cid: 125),
                                                     clip(dual, .audio, src: 0, dur: 60, at: 1900, fd: ntsc, cid: 126)])
    var tl = timeline("DF 29.97", [v, au], fd: ntsc)
    tl.timecodeStart = ntsc * 107_892
    tl.markers = [Marker(id: id(213), time: ntsc * 1830, name: "Hit", color: .red), Marker(id: id(214), time: ntsc * 1850, name: "Soft", color: .orange, duration: ntsc * 12)]
    all("ntsc", tl, [m, dual])
}

// 4 what cannot be carried, missing media, odd names and paths
do {
    var off = clip(a, .video, src: 0, dur: 25, at: 0, name: "Off\tline\nname", cid: 131)
    off.isEnabled = false
    let text = Clip(id: id(132), name: "Title", media: id(132), kind: .video, source: TimeRange(start: .zero, duration: fd * 25), start: fd * 25,
                    generator: GeneratorRef(kind: "solid", payload: Data()))
    let nested = Clip(id: id(133), name: "Nest", media: id(133), kind: .video, source: TimeRange(start: .zero, duration: fd * 25), start: fd * 50,
                      sequence: id(901))
    let missing = clip(a, .video, src: 5, dur: 25, at: 75, cid: 134)
    let t1 = clip(tricky, .video, src: 5, dur: 25, at: 100, name: "  T\u{EB}st\u{A0}\u{2003}", cid: 135)
    let ta = clip(tricky, .audio, src: 5, dur: 25, at: 100, cid: 136)
    var v2 = Track(id: id(42), kind: .video, clips: [clip(b, .video, src: 0, dur: 10, at: 0, cid: 137)]); v2.name = "Over \"2\""
    let tl = timeline("Odd / name\u{1}\u{2028}\u{7F}", [Track(id: id(41), kind: .video, clips: [off, text, nested, missing, t1]), v2,
                                              Track(id: id(43), kind: .audio, clips: [ta])])
    all("odd", tl, [tricky, b])
    all("empty", timeline("Empty", []), [])
}

// 5 titles
do {
    func title(_ cid: Int, _ text: String, at: Int64, dur: Int64, size: Double, bold: Bool, italic: Bool, align: TextAlignment) throws -> Clip {
        var st = TextStyle(fontName: "Helvetica Neue", size: size, weight: bold ? .bold : .medium, color: RGBAColor(red: 1, green: 0.5, blue: 0.3333333))
        st.alignment = align; st.italic = italic
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: text, style: st), animations: nil)
        return Clip(id: id(cid), name: "Lower & Third", media: id(cid), kind: .video, source: TimeRange(start: .zero, duration: fd * dur),
                    start: fd * at, generator: ref)
    }
    let c1 = clip(a, .video, src: 0, dur: 50, at: 0, cid: 141)
    let sp = try! title(142, "Hello\nWorld <3 & \"q\"\r\nCRLF", at: 50, dur: 25, size: 72, bold: true, italic: false, align: .center)
    let over = try! title(143, "Over", at: 10, dur: 20, size: 36.5, bold: false, italic: true, align: .left)
    let tl = timeline("Titles", [Track(id: id(51), kind: .video, clips: [c1, sp]), Track(id: id(52), kind: .video, clips: [over])])
    emit("title-fcpxml", FCPXMLWriter.render(tl, media: [a]))
    emit("title-fcpxml-fcp113", FCPXMLWriter.render(tl, media: [a], version: .v1_13, target: .finalCut))
}

// 6 OTIO: several sequences, odd numbers
do {
    let t1 = timeline("One", [Track(id: id(61), kind: .video, clips: [clip(a, .video, src: 3, dur: 30, at: 1799, fd: ntsc, cid: 151)])], fd: ntsc)
    var t2 = timeline("Two", [Track(id: id(62), kind: .video, clips: [clip(b, .video, src: 1, dur: 7, at: 3, speed: ClipSpeed(num: 7, den: 3), cid: 152)])])
    t2.timecodeStart = Time(3600, 1)
    emit("collection-otio", OTIOWriter.render([t1, t2], media: [a, b]))
    emit("none-otio", OTIOWriter.render([], media: []))
    // Numbers JSONSerialization prints: 17 significant digits, exponents, negative values.
    var t3 = timeline("Numbers", [])
    t3.markers = [Marker(id: id(240), time: Time(1, 3), name: "third"), Marker(id: id(241), time: Time(1, 10_000_000), name: "tiny"),
                  Marker(id: id(242), time: Time(1_000_000_000_000_000, 1), name: "huge15"), Marker(id: id(243), time: Time(100_000_000_000_000_000, 1), name: "huge17"),
                  Marker(id: id(244), time: Time(-2, 7), name: "negative", duration: Time(-1, 1)), Marker(id: id(245), time: Time(7, 1000), name: "ms", duration: Time(123_456_789, 1000)),
                  Marker(id: id(246), time: Time(1, 1_000_000_000_000), name: "e-14"), Marker(id: id(247), time: Time(4, 1), name: "four", duration: Time(1, 8))]
    emit("numbers-otio", OTIOWriter.render(t3, media: []))
}

// 7 subtitles
do {
    func cue(_ lines: [String], _ s: Time, _ e: Time) -> SRTCue { SRTCue(lines: lines, range: TimeRange(start: s, duration: e - s)) }
    let cues = [
        cue(["Second & <b>", "line --> two"], Time(5, 2), Time(7, 1)),
        cue(["First"], Time(1, 3), Time(2, 1)),
        cue(["", "  ", "\t"], Time(1, 1), Time(2, 1)),
        cue(["Same start A"], Time(10, 1), Time(11, 1)),
        cue(["Same start B", "", "tail > x"], Time(10, 1), Time(12, 1)),
        cue(["Tiny"], Time(20, 1), Time(20_001, 1000) ),
        cue(["Rounds to nothing"], Time(30, 1), Time(30, 1) + Time(1, 4000)),
        cue(["Late"], Time(3600 + 61, 1) + Time(1, 1000), Time(3600 + 65, 1)),
        cue(["Half ms"], Time(1, 4000) * 3, Time(1, 2) + Time(1, 4000) * 3),
    ]
    let window = TimeRange(start: Time(3, 2), duration: Time(9, 1))
    put("subs-srt.out", SRTWriter.render(cues, range: .entireSequence))
    put("subs-srt-window.out", SRTWriter.render(cues, range: .inOut(window)))
    put("subs-vtt.out", VTTWriter.render(cues, range: .entireSequence))
    put("subs-vtt-window.out", VTTWriter.render(cues, range: .inOut(window)))
    put("subs-itt.out", ITTWriter.render(cues, language: "en-US&<\">", range: .entireSequence))
    put("subs-itt-window.out", ITTWriter.render(cues, language: "de", range: .inOut(window)))
    put("subs-empty-srt.out", SRTWriter.render([], range: .entireSequence))
}

// 8 marker CSV
do {
    var c = clip(a, .video, src: 50, dur: 100, at: 25, name: "Clip, \"one\"", cid: 161)
    c.markers = [Marker(id: id(221), time: fd * 60, name: "=SUM(A1)", color: .red, comment: "line\nbreak"),
                 Marker(id: id(222), time: fd * 10, name: "BeforeIn"),
                 Marker(id: id(223), time: fd * 70, name: "+plus", comment: "crlf\r\nbreak", duration: fd * 5)]
    var tl = timeline("CSV", [Track(id: id(71), kind: .video, clips: [c])])
    tl.markers = [Marker(id: id(224), time: fd * 85, name: "Same time", comment: "say \"hi\", ok"),
                  Marker(id: id(225), time: fd * 5, name: "@at", color: .purple, comment: "-minus"),
                  Marker(id: id(226), time: fd * 85, name: "\tTab", color: .white, comment: "\rCR", duration: fd * 12)]
    tl.timecodeStart = Time(3600, 1)
    emit("csv-ndf", MarkerCSV.export(tl))
    var tl2 = timeline("CSV DF", [Track(id: id(72), kind: .video, clips: [])], fd: ntsc)
    tl2.markers = [Marker(id: id(227), time: ntsc * 1800, name: "Minute", duration: ntsc * 1800)]
    tl2.timecodeStart = ntsc * 107_892
    emit("csv-df", MarkerCSV.export(tl2))
}

// 9 YouTube chapters
do {
    func mk(_ s: Int64, _ n: String, _ t: Int64 = 1) -> Marker { Marker(id: id(230), time: Time(s, t), name: n) }
    let ms = [mk(0, "Start"), mk(75, " Second\nline "), mk(75, "dup"), mk(4000, "Long"), mk(3, "  "), mk(8090, "Late"), mk(9, "Short", 2), mk(12, "Out")]
    var out = ""
    func show(_ title: String, _ r: YouTubeChapters.Result) { out += "== \(title)\n\(r.text)\n-- warnings\n\(r.warnings.joined(separator: "\n"))\n" }
    show("all", YouTubeChapters.make(from: ms))
    show("range", YouTubeChapters.make(from: ms, rangeStart: Time(60, 1), duration: Time(4100, 1)))
    show("none", YouTubeChapters.make(from: []))
    show("short", YouTubeChapters.make(from: [mk(0, "A"), mk(5, "B"), mk(30, "C")], duration: Time(33, 1)))
    put("chapters.out", out)
}

// 10 file URLs through the writers' own path (XMEML pathurl): every ASCII character and some beyond
do {
    var lines = ""
    for c in 32..<127 {
        let s = String(UnicodeScalar(UInt8(c)))
        lines += "\(c)\t" + URL(fileURLWithPath: "/x/a" + s + "b").absoluteString + "\n"
    }
    lines += "u\t" + URL(fileURLWithPath: "/x/\u{E9}\u{4E2D}\u{1F600}.mov").absoluteString + "\n"
    put("urls.tsv", lines)
}
