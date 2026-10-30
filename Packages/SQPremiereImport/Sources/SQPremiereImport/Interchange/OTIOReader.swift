import Foundation
import SQCore

/// OpenTimelineIO JSON (.otio) -> `IXSequence`: the first timeline (`readAll`: every timeline of a collection), its Video and
/// Audio tracks (clips with `source_range`, gaps, transitions with in / out offsets, `LinearTimeWarp` / `FreezeFrame`
/// effects, external media references), and stack / clip markers. The length of an item on a track is its
/// `source_range.duration`; `start_time` is media time. Nested stacks, image sequences and generators are dropped.
/// Written from the public OTIO file-format description; no third-party code.
enum OTIOReader {
    typealias JSON = [String: Any]

    static func read(_ data: Data, name: String) throws -> IXSequence {
        guard let first = try readAll(data, name: name).first else { throw InterchangeError.unsupported("no OpenTimelineIO timeline") }
        return first
    }

    /// Every timeline of the file, in document order: a lone Timeline, or each Timeline (and each bare Stack) found in
    /// the children of a Collection / SerializableCollection, nested collections included.
    static func readAll(_ data: Data, name: String) throws -> [IXSequence] {
        guard let any = try? JSONSerialization.jsonObject(with: data), let root = any as? JSON else {
            throw InterchangeError.malformed("not valid JSON")
        }
        var found = [JSON]()
        collectTimelines(root, into: &found)
        guard !found.isEmpty else { throw InterchangeError.unsupported("no OpenTimelineIO timeline") }
        return try found.map { try sequence($0, name: name) }
    }

    private static func collectTimelines(_ d: JSON, into found: inout [JSON]) {
        let schema = d["OTIO_SCHEMA"] as? String ?? ""
        if schema.hasPrefix("Timeline") { found.append(d); return }
        if schema.hasPrefix("Stack"), isBareStack(d) {
            // A stack held by a collection plays as its own sequence.
            found.append(["name": d["name"] as Any, "tracks": d]); return
        }
        for c in (d["children"] as? [JSON]) ?? [] { collectTimelines(c, into: &found) }
    }

    /// A stack whose children are tracks (not a stack nested in a track).
    private static func isBareStack(_ d: JSON) -> Bool {
        ((d["children"] as? [JSON]) ?? []).contains { ($0["OTIO_SCHEMA"] as? String)?.hasPrefix("Track") == true }
    }

    private static func sequence(_ timeline: JSON, name: String) throws -> IXSequence {
        guard let stack = timeline["tracks"] as? JSON else { throw InterchangeError.malformed("no tracks") }
        let trackList = (stack["children"] as? [JSON]) ?? []

        // The sequence rate: the first rate any item carries.
        var rate: Double?
        func scan(_ v: Any) {
            guard rate == nil else { return }
            if let d = v as? JSON {
                if (d["OTIO_SCHEMA"] as? String)?.hasPrefix("RationalTime") == true, let r = d["rate"] as? Double, r > 0 {
                    rate = r; return
                }
                for k in d.keys.sorted() { scan(d[k]!) }
            } else if let a = v as? [Any] { a.forEach(scan) }
        }
        scan(stack["children"] as Any)
        if rate == nil, let g = timeline["global_start_time"] { scan(g) }
        let fd = rate.map(frameDuration(rate:)) ?? Time(1, 25)
        var seq = IXSequence(name: (timeline["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name, frameDuration: fd)

        for t in trackList {
            let schema = t["OTIO_SCHEMA"] as? String ?? ""
            guard schema.hasPrefix("Track") else {
                seq.report.note("Nested sequence", .dropped, "a stack inside the tracks is not read"); continue
            }
            let kind: TrackKind = (t["kind"] as? String)?.lowercased() == "audio" ? .audio : .video
            seq.tracks.append(track(t, kind: kind, seq: &seq))
        }
        for m in (stack["markers"] as? [JSON]) ?? [] {
            guard let r = timeRange(m["marked_range"]) else { continue }
            seq.markers.append(IXMarker(time: r.start, name: m["name"] as? String ?? "", comment: m["comment"] as? String ?? "",
                                        duration: r.duration, color: markerColor(m["color"] as? String)))
        }
        return seq
    }

    /// Frame duration of a rate: NTSC family exact, whole rates, else a rounded thousandth.
    static func frameDuration(rate: Double) -> Time {
        for base in [24, 30, 48, 60, 120] as [Int64] where abs(rate - Double(base * 1000) / 1001) < 0.01 {
            return Time(1001, base * 1000)
        }
        if abs(rate - rate.rounded()) < 0.001 { return Time(1, max(Int64(rate.rounded()), 1)) }
        return Time(1000, max(Int64((rate * 1000).rounded()), 1))
    }

    /// RationalTime { value, rate } -> exact `Time`.
    static func rationalTime(_ any: Any?) -> Time? {
        guard let d = any as? JSON, let v = number(d["value"]), let r = number(d["rate"]), r > 0, v.isFinite else { return nil }
        let fd = frameDuration(rate: r)               // seconds per unit
        let whole = v.rounded()
        if abs(v - whole) < 1e-6 { return fd * Int64(whole) }
        // A fractional value: thousandths of a unit.
        return Time.scaled(fd * Int64((v * 1000).rounded()), by: 1, over: 1000)
    }

    private static func timeRange(_ any: Any?) -> TimeRange? {
        guard let d = any as? JSON, let s = rationalTime(d["start_time"]), let dur = rationalTime(d["duration"]) else { return nil }
        return TimeRange(start: s, duration: dur)
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func markerColor(_ s: String?) -> MarkerColor? {
        switch s?.uppercased() {
        case "RED": .red
        case "GREEN": .green
        case "BLUE": .blue
        case "CYAN": .cyan
        case "PURPLE", "MAGENTA", "PINK": .purple
        case "ORANGE": .orange
        case "YELLOW": .yellow
        case "WHITE": .white
        default: nil
        }
    }

    private static func track(_ t: JSON, kind: TrackKind, seq: inout IXSequence) -> IXTrack {
        var track = IXTrack(kind: kind)
        var cursor = Time.zero
        var pending = [(offsets: (Time, Time), type: String, name: String, outgoing: Int?)]()
        var lastWasClip = false
        func resolve(incoming: Int?) {
            for p in pending {
                let total = p.offsets.0 + p.offsets.1
                guard total > .zero, p.outgoing != nil || incoming != nil else { continue }
                var alignment = TransitionAlignment.center
                if p.offsets.0 == .zero { alignment = .startAtCut } else if p.offsets.1 == .zero { alignment = .endAtCut }
                else if p.offsets.0 != p.offsets.1 { alignment = .custom }
                var k = TransitionKind.crossDissolve
                if kind == .audio { k = .constantPower }
                else if p.type != "SMPTE_Dissolve" && !p.type.isEmpty {
                    seq.report.note("Transition \(p.name.isEmpty ? p.type : p.name)", .approximated, "played as Cross Dissolve")
                }
                track.transitions.append(IXTransition(kind: k, duration: total, alignment: alignment,
                                                       outgoing: p.outgoing, incoming: incoming))
            }
            pending = []
        }
        for item in (t["children"] as? [JSON]) ?? [] {
            let schema = item["OTIO_SCHEMA"] as? String ?? ""
            let range = timeRange(item["source_range"])
            if schema.hasPrefix("Gap") {
                cursor += range?.duration ?? .zero
                lastWasClip = false
            } else if schema.hasPrefix("Transition") {
                let i = rationalTime(item["in_offset"]) ?? .zero, o = rationalTime(item["out_offset"]) ?? .zero
                pending.append(((i, o), item["transition_type"] as? String ?? "", item["name"] as? String ?? "",
                                lastWasClip ? track.clips.count - 1 : nil))
            } else if schema.hasPrefix("Clip") {
                let ref = item["media_reference"] as? JSON
                let refSchema = ref?["OTIO_SCHEMA"] as? String ?? ""
                let available = timeRange(ref?["available_range"])
                guard let r = range ?? available, r.duration > .zero else {
                    seq.report.note("Clip without range", .dropped); resolve(incoming: nil); lastWasClip = false; continue
                }
                if item["enabled"] as? Bool == false {
                    seq.report.note("Disabled clip", .dropped); cursor += r.duration; resolve(incoming: nil); lastWasClip = false
                    continue
                }
                if refSchema.hasPrefix("GeneratorReference") || refSchema.hasPrefix("ImageSequenceReference") {
                    seq.report.note(refSchema.hasPrefix("Generator") ? "Generator" : "Image sequence", .dropped,
                                    "not read from OpenTimelineIO")
                    cursor += r.duration; resolve(incoming: nil); lastWasClip = false
                    continue
                }
                let clipName = item["name"] as? String ?? ""
                var key = clipName.isEmpty ? "Media" : clipName, mediaName = key
                if let url = ref?["target_url"] as? String, !url.isEmpty {
                    key = InterchangePath.path(fromURL: url)
                    mediaName = (key as NSString).lastPathComponent
                } else if let n = ref?["name"] as? String, !n.isEmpty { key = n; mediaName = n }
                var speed = ClipSpeed.normal, reversed = false, hold: Time?
                for e in (item["effects"] as? [JSON]) ?? [] {
                    let es = e["OTIO_SCHEMA"] as? String ?? ""
                    guard es.hasPrefix("LinearTimeWarp") || es.hasPrefix("FreezeFrame") else {
                        seq.report.note("Effect", .dropped, e["name"] as? String ?? es); continue
                    }
                    let s = es.hasPrefix("FreezeFrame") ? 0 : (number(e["time_scalar"]) ?? 1)
                    if s == 0 { hold = r.start }
                    else if s != 1 {
                        let abs = Swift.abs(s)
                        speed = ClipSpeed(num: Int64((abs * 10_000).rounded()), den: 10_000)
                        reversed = s < 0
                    }
                }
                if hold != nil { seq.report.note("Speed", .mapped, "hold frame") }
                else if !speed.isNormal || reversed { seq.report.note("Speed", .mapped) }
                var clip = IXClip(name: clipName, mediaKey: key, mediaName: mediaName, start: cursor, duration: r.duration,
                                  sourceIn: r.start, speed: speed, reversed: reversed, mediaDuration: available?.duration)
                clip.holdFrame = hold
                resolve(incoming: track.clips.count)
                track.clips.append(clip)
                // Clip markers sit in media time; show them where the clip plays that frame.
                for m in (item["markers"] as? [JSON]) ?? [] {
                    guard let mr = timeRange(m["marked_range"]), mr.start >= r.start else { continue }
                    let local = speed.unscale(mr.start - r.start)
                    guard local < r.duration else { continue }
                    seq.markers.append(IXMarker(time: cursor + local, name: m["name"] as? String ?? "",
                                                comment: m["comment"] as? String ?? "",
                                                color: markerColor(m["color"] as? String)))
                }
                cursor += r.duration
                lastWasClip = true
            } else {
                seq.report.note("Nested sequence", .dropped, "a nested item is not read from OpenTimelineIO")
                cursor += range?.duration ?? .zero
                resolve(incoming: nil)
                lastWasClip = false
            }
        }
        resolve(incoming: nil)
        return track
    }
}
