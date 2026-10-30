import Foundation
import SQCore

/// Timeline interchange (CMX3600 EDL, Final Cut Pro 7 XML, FCPXML, OpenTimelineIO): the readers produce this neutral sequence, one
/// mapper turns it into the SQCore model. Written from the public format descriptions; no third-party code.
/// All positions are rational `Time`, never Double.
public struct IXMarker: Sendable, Equatable {
    public var time: Time
    public var name: String
    public var comment: String
    public var duration: Time
    /// Nil = the format has no marker colors.
    public var color: MarkerColor?
    public init(time: Time, name: String, comment: String = "", duration: Time = .zero, color: MarkerColor? = nil) {
        self.time = time; self.name = name; self.comment = comment; self.duration = duration; self.color = color
    }
}

public struct IXClip: Sendable, Equatable {
    public var name: String
    /// Path (or, for an EDL without a file name, the clip / reel name) that identifies the media.
    public var mediaKey: String
    public var mediaName: String
    /// Position and length on the timeline.
    public var start: Time
    public var duration: Time
    /// First source frame played, in media time.
    public var sourceIn: Time
    public var speed: ClipSpeed = .normal
    public var reversed = false
    public var mediaDuration: Time?
    /// A frozen frame (media time) instead of playback.
    public var holdFrame: Time?
    /// Explicit link group from the file (xmeml `<link>`): clips of one group move together. Nil = none given.
    public var linkGroup: String?
    /// Channel of the file this audio clip plays (0-based), from the file's own track choice. Nil = not given.
    public var sourceChannel: Int?
    /// A real speed track (ramps, several constant segments) from the file. Nil = `speed` / `reversed` apply. When set,
    /// `duration` equals the track's duration (whole frames) and `sourceIn` is ignored: the track carries its origin.
    public var speedKeys: SpeedKeys?
    public init(name: String, mediaKey: String, mediaName: String? = nil, start: Time, duration: Time, sourceIn: Time,
                speed: ClipSpeed = .normal, reversed: Bool = false, mediaDuration: Time? = nil) {
        self.name = name; self.mediaKey = mediaKey; self.mediaName = mediaName ?? name
        self.start = start; self.duration = duration; self.sourceIn = sourceIn
        self.speed = speed; self.reversed = reversed; self.mediaDuration = mediaDuration
    }
    public var end: Time { start + duration }
}

public struct IXTransition: Sendable, Equatable {
    public var kind: TransitionKind
    public var duration: Time
    public var alignment: TransitionAlignment
    /// Indices into the track's `clips` (nil = one-sided).
    public var outgoing: Int?
    public var incoming: Int?
    public init(kind: TransitionKind = .crossDissolve, duration: Time, alignment: TransitionAlignment = .center,
                outgoing: Int?, incoming: Int?) {
        self.kind = kind; self.duration = duration; self.alignment = alignment
        self.outgoing = outgoing; self.incoming = incoming
    }
}

public struct IXTrack: Sendable, Equatable {
    public var kind: TrackKind
    public var clips: [IXClip] = []
    public var transitions: [IXTransition] = []
    public init(kind: TrackKind, clips: [IXClip] = [], transitions: [IXTransition] = []) {
        self.kind = kind; self.clips = clips; self.transitions = transitions
    }
}

public struct IXSequence: Sendable {
    public var name: String
    public var frameDuration: Time
    public var width: Int
    public var height: Int
    public var tracks: [IXTrack] = []
    public var markers: [IXMarker] = []
    /// What the reader approximated or dropped.
    public var report = PRImportReport()
    public init(name: String, frameDuration: Time, width: Int = 1920, height: Int = 1080) {
        self.name = name; self.frameDuration = frameDuration; self.width = width; self.height = height
    }
}

public enum InterchangeError: Error, Equatable, LocalizedError {
    case unsupported(String)
    case malformed(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): "Not a supported interchange file: \(s)"
        case .malformed(let s): "The file could not be read: \(s)"
        case .empty: "The file contains no clips."
        }
    }
}

/// Which format a file holds.
public enum InterchangeFormat: String, Sendable, CaseIterable {
    case edl, finalCutXML, fcpxml, otio

    /// By content first (an `.xml` file is either FCP7 or FCPXML), then by extension.
    public static func detect(data: Data, fileExtension: String) -> InterchangeFormat? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("<fcpxml") { return .fcpxml }
        if head.contains("OTIO_SCHEMA") { return .otio }
        if head.contains("<xmeml") { return .finalCutXML }
        let ext = fileExtension.lowercased()
        if ext == "edl" { return .edl }
        if ext == "fcpxml" { return .fcpxml }
        if ext == "otio" { return .otio }
        if !head.contains("<"),
           head.contains("TITLE:") || head.range(of: #"(?m)^\d{3,6}\s+\S+\s+\S+\s+[CDW]"#, options: .regularExpression) != nil {
            return .edl
        }
        return nil
    }
}

public enum InterchangeReader {
    /// Reads a file into the neutral sequence. `defaultFrameDuration`: the rate of an EDL (it carries none).
    public static func read(data: Data, fileExtension: String, name: String,
                            defaultFrameDuration: Time = Time(1, 25)) throws -> IXSequence {
        guard let format = InterchangeFormat.detect(data: data, fileExtension: fileExtension) else {
            throw InterchangeError.unsupported(fileExtension.isEmpty ? "unknown format" : ".\(fileExtension)")
        }
        let seq: IXSequence
        switch format {
        case .edl: seq = try EDLReader.read(String(decoding: data, as: UTF8.self), name: name, frameDuration: defaultFrameDuration)
        case .finalCutXML: seq = try XMEMLReader.read(data, name: name)
        case .fcpxml: seq = try FCPXMLReader.read(data, name: name)
        case .otio: seq = try OTIOReader.read(data, name: name)
        }
        guard seq.tracks.contains(where: { !$0.clips.isEmpty }) else { throw InterchangeError.empty }
        return seq
    }

    /// Every sequence of the file that has clips (FCPXML projects, xmeml sequences). OTIO collections give one per timeline; one entry for EDL.
    public static func readAll(data: Data, fileExtension: String, name: String,
                               defaultFrameDuration: Time = Time(1, 25)) throws -> [IXSequence] {
        guard let format = InterchangeFormat.detect(data: data, fileExtension: fileExtension) else {
            throw InterchangeError.unsupported(fileExtension.isEmpty ? "unknown format" : ".\(fileExtension)")
        }
        let all: [IXSequence]
        switch format {
        case .fcpxml: all = try FCPXMLReader.readAll(data, name: name)
        case .finalCutXML: all = try XMEMLReader.readAll(data, name: name)
        case .otio: all = try OTIOReader.readAll(data, name: name)
        default: return [try read(data: data, fileExtension: fileExtension, name: name, defaultFrameDuration: defaultFrameDuration)]
        }
        let usable = all.filter { $0.tracks.contains { !$0.clips.isEmpty } }
        guard !usable.isEmpty else { throw InterchangeError.empty }
        return usable
    }

    public static func readAll(url: URL, defaultFrameDuration: Time = Time(1, 25)) throws -> [IXSequence] {
        try readAll(data: Data(contentsOf: url), fileExtension: url.pathExtension,
                    name: url.deletingPathExtension().lastPathComponent, defaultFrameDuration: defaultFrameDuration)
    }

    public static func read(url: URL, defaultFrameDuration: Time = Time(1, 25)) throws -> IXSequence {
        try read(data: Data(contentsOf: url), fileExtension: url.pathExtension,
                 name: url.deletingPathExtension().lastPathComponent, defaultFrameDuration: defaultFrameDuration)
    }
}

/// `IXSequence` -> SQCore `Project` (one sequence). Missing media become offline placeholders until relinked.
public enum InterchangeMapper {
    /// Keys of the media that look like absolute paths (what the caller probes before `map`).
    public static func mediaPaths(_ s: IXSequence) -> [String] { mediaPaths([s]) }

    public static func mediaPaths(_ all: [IXSequence]) -> [String] {
        var seen = Set<String>(), out = [String]()
        for c in all.flatMap({ $0.tracks.flatMap(\.clips) }) where c.mediaKey.hasPrefix("/") || c.mediaKey.contains(":\\") {
            if seen.insert(c.mediaKey).inserted { out.append(c.mediaKey) }
        }
        return out
    }

    public static func map(_ s: IXSequence, name: String? = nil, media probed: [String: MediaRef] = [:]) -> PRImportResult {
        map([s], name: name, media: probed)
    }

    /// One project with a timeline per sequence (the first is active); media shared between them are one item.
    public static func map(_ all: [IXSequence], name: String? = nil, media probed: [String: MediaRef] = [:]) -> PRImportResult {
        var report = PRImportReport()
        var refs = probed, order = [String]()
        var timelines = [Timeline]()
        var channelOf = [UUID: [Int]]()   // media -> channels played
        for s in all {
            for e in s.report.entries { for _ in 0..<e.count { report.note(e.feature, e.status, e.note) } }
            timelines.append(timeline(s, refs: &refs, order: &order, channelOf: &channelOf, report: &report))
        }
        if all.count > 1 { report.note("Sequences", .mapped, "\(all.count)") }
        var project = Project(name: name ?? all.first?.name ?? "Imported", media: order.compactMap { refs[$0] },
                              timelines: timelines, activeTimeline: timelines.first?.id)
        // shortcut: one channel choice per media item; applied only when every audio clip of the file names the same
        // channel above the first and the file is probed, upgrade when clips can carry their own channel map.
        for (id, channels) in channelOf {
            guard let ch = channels.first, ch > 0, channels.allSatisfy({ $0 == ch }), let map = AudioChannelMap.mono(ch) else { continue }
            if !project.setAudioChannelMap(map, for: id) {
                report.note("Audio channel", .approximated, "the file plays channel \(ch + 1) only: set it under source settings after relinking")
            }
        }
        return PRImportResult(project: project, report: report)
    }

    private static func timeline(_ s: IXSequence, refs: inout [String: MediaRef], order: inout [String],
                                 channelOf: inout [UUID: [Int]], report: inout PRImportReport) -> Timeline {
        let fd = s.frameDuration
        func ref(for c: IXClip) -> MediaRef {
            if refs[c.mediaKey] == nil {
                var r = MediaRef(name: c.mediaName, path: c.mediaKey, fingerprint: MediaFingerprint(size: 0))
                r.duration = c.mediaDuration
                refs[c.mediaKey] = r
                report.note("Offline media", .approximated, "not found: placeholder until relinked")
            }
            if !order.contains(c.mediaKey) { order.append(c.mediaKey) }
            return refs[c.mediaKey]!
        }
        var lanes = [[Clip]](), kinds = [TrackKind](), transitions = [[Transition]]()
        var groupOf = [UUID: String]()   // clip -> explicit link group
        for t in s.tracks {
            var clips = [Clip](), idOf = [Int: UUID]()
            for i in t.clips.indices.sorted(by: { t.clips[$0].start < t.clips[$1].start }) {
                let c = t.clips[i]
                let start = c.start.snapped(to: fd)
                let duration = c.speedKeys.map(\.duration) ?? max(c.duration.snapped(to: fd), fd)
                if let last = clips.last, last.timeline.end > start {
                    report.note("Overlapping clip", .dropped, "a clip starting inside the previous one on the same track")
                    continue
                }
                let r = ref(for: c)
                let still = r.info?.isStill ?? Mapping.stillExtensions.contains((r.path as NSString).pathExtension.lowercased())
                var clip = Clip(name: c.name.isEmpty ? c.mediaName : c.name, media: r.id, kind: t.kind,
                                source: TimeRange(start: still ? .zero : c.sourceIn, duration: c.speed.scale(duration)),
                                start: start, mediaDuration: r.duration ?? c.mediaDuration, isStill: still,
                                speed: c.speed, reversed: c.reversed)
                if let keys = c.speedKeys, !still { clip.setSpeedKeys(keys) }
                if let h = c.holdFrame { clip.holdFrame = h }
                idOf[i] = clip.id
                if let g = c.linkGroup { groupOf[clip.id] = g }
                if t.kind == .audio { channelOf[r.id, default: []].append(c.sourceChannel ?? -1) }
                clips.append(clip)
                report.note(t.kind == .video ? "Video clip" : "Audio clip", .mapped)
                if c.speedKeys != nil && !still { report.note("Speed ramp", .mapped, "imported as retime keys") }
                else if !c.speed.isNormal || c.reversed { report.note("Speed", .mapped) }
            }
            lanes.append(clips); kinds.append(t.kind)
            transitions.append(t.transitions.compactMap { x in
                let out = x.outgoing.flatMap { idOf[$0] }, inc = x.incoming.flatMap { idOf[$0] }
                guard out != nil || inc != nil else { return nil }
                report.note("Cross Dissolve", .mapped)
                return Transition(kind: x.kind, duration: max(x.duration.snapped(to: fd), fd), alignment: x.alignment,
                                  outgoing: out, incoming: inc)
            })
        }
        link(&lanes, kinds: kinds, explicit: groupOf)
        var counts = [TrackKind: Int]()
        var tracks = [Track]()
        for (i, clips) in lanes.enumerated() {
            counts[kinds[i], default: 0] += 1
            var track = Track(kind: kinds[i], clips: clips, name: "\(kinds[i] == .video ? "V" : "A")\(counts[kinds[i]]!)")
            track.transitions = transitions[i]
            tracks.append(track)
        }
        let format = SequenceFormat(width: s.width, height: s.height, frameDuration: fd).sanitized()
        var timeline = Timeline(name: s.name, format: format, tracks: tracks)
        timeline.markers = s.markers.map {
            Marker(time: $0.time.snapped(to: fd), name: $0.name, color: $0.color ?? .green, comment: $0.comment, duration: $0.duration.snapped(to: fd))
        }
        if !s.markers.isEmpty { report.note("Sequence markers", .mapped, "\(s.markers.count)") }
        return timeline
    }

    /// Links a video clip and the audio clips of the same media over the same range.
    static func link(_ lanes: inout [[Clip]], kinds: [TrackKind], explicit: [UUID: String] = [:]) {
        // Groups the file names win; clips of a group of one are left to the heuristic below.
        var byGroup = [String: [(Int, Int)]]()
        for (li, lane) in lanes.enumerated() {
            for (ci, c) in lane.enumerated() { if let g = explicit[c.id] { byGroup[g, default: []].append((li, ci)) } }
        }
        for (_, members) in byGroup.sorted(by: { $0.key < $1.key }) where members.count > 1 {
            let id = UUID()
            for (li, ci) in members { lanes[li][ci].link = id }
        }
        struct Key: Hashable { let media: UUID; let start: Time; let end: Time }
        var byKey = [Key: [(Int, Int)]]()
        for (li, lane) in lanes.enumerated() {
            for (ci, c) in lane.enumerated() where c.link == nil {
                byKey[Key(media: c.media, start: c.start, end: c.timeline.end), default: []].append((li, ci))
            }
        }
        for (_, members) in byKey {
            let video = members.filter { kinds[$0.0] == .video }
            guard video.count == 1, members.contains(where: { kinds[$0.0] == .audio }) else { continue }
            let id = UUID()
            for (li, ci) in members { lanes[li][ci].link = id }
        }
    }
}
