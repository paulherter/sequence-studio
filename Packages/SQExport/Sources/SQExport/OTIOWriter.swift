import Foundation
import SQCore

/// OpenTimelineIO (.otio JSON, schema Timeline.1 / Stack.1 / Track.1 / Clip.2 / Gap.1 / Transition.1 / Marker.2) of a
/// sequence: every video and audio track as a Track.1 with gaps between clips, external media references, constant
/// speed as `LinearTimeWarp.1` (negative scalar = reverse), a hold frame as `FreezeFrame.1`, touching dissolves as
/// `Transition.1`, markers on the Stack. Item lengths are the lengths on the track; `source_range.start_time` is media
/// time. Titles, generators, nested sequences and disabled clips are skipped and listed in `warnings`.
/// Written from the public OTIO file-format description; no third-party code.
public enum OTIOWriter {
    typealias JSON = [String: Any]

    /// Which sequences of a project one export holds (the export dialog's choice).
    public enum Scope: String, Sendable, CaseIterable {
        case activeSequence, allSequences

        public func timelines(in project: Project) -> [Timeline] {
            switch self {
            case .allSequences: return project.timelines
            case .activeSequence:
                let t = project.timelines.first { $0.id == project.activeTimeline } ?? project.timelines.first
                return t.map { [$0] } ?? []
            }
        }
    }

    public static func render(_ timeline: Timeline, media: [MediaRef]) -> InterchangeExport {
        render([timeline], media: media)
    }

    /// Several sequences: one Timeline.1 as is for a single one, else a SerializableCollection.1 holding every Timeline.1
    /// (the reader takes each timeline of a collection as one sequence).
    public static func render(_ timelines: [Timeline], media: [MediaRef]) -> InterchangeExport {
        var warnings = [String]()
        func warn(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }
        let roots = timelines.map { timelineJSON($0, media: media, warn: warn) }
        let root: JSON = roots.count == 1 ? roots[0]
            : ["OTIO_SCHEMA": "SerializableCollection.1", "name": "Sequences", "children": roots, "metadata": JSON()]
        guard JSONSerialization.isValidJSONObject(root) else {
            return InterchangeExport(text: "", warnings: warnings, failure: "a time or name in the sequence cannot be written as JSON")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return InterchangeExport(text: String(decoding: data, as: UTF8.self) + "\n", warnings: warnings)
        } catch {
            return InterchangeExport(text: "", warnings: warnings, failure: "\(error.localizedDescription)")
        }
    }

    private static func timelineJSON(_ timeline: Timeline, media: [MediaRef], warn: (String) -> Void) -> JSON {
        let fd = timeline.format.frameDuration
        let byID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rate = Double(fd.timescale) / Double(max(fd.value, 1))

        func rt(_ t: Time) -> JSON {
            let frames = Double(t.value) * Double(fd.timescale) / (Double(t.timescale) * Double(max(fd.value, 1)))
            return ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": frames]
        }
        func range(_ start: Time, _ duration: Time) -> JSON {
            ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(start), "duration": rt(duration)]
        }
        func usable(_ c: Clip) -> Bool {
            if c.isGenerator { warn("Text and generator clips are not exported (\"\(c.name)\")"); return false }
            if c.isNested { warn("Nested sequence \"\(c.name)\" is not exported"); return false }
            if !c.isEnabled { warn("Disabled clip \"\(c.name)\" skipped"); return false }
            return true
        }
        func color(_ c: MarkerColor) -> String {
            switch c {
            case .green: "GREEN"
            case .red: "RED"
            case .purple: "PURPLE"
            case .orange: "ORANGE"
            case .yellow: "YELLOW"
            case .white: "WHITE"
            case .blue: "BLUE"
            case .cyan: "CYAN"
            }
        }

        func clipJSON(_ c: Clip) -> JSON {
            var ref: JSON
            let m = byID[c.media]
            if m == nil { warn("Media of a clip is missing from the project; written as a missing reference") }
            if let m, !m.path.isEmpty {
                ref = ["OTIO_SCHEMA": "ExternalReference.1", "name": m.name,
                       "target_url": URL(fileURLWithPath: m.path).absoluteString, "metadata": JSON()]
                if let d = m.duration ?? m.info?.duration { ref["available_range"] = range(.zero, d) }
                else { ref["available_range"] = NSNull() }
            } else {
                ref = ["OTIO_SCHEMA": "MissingReference.1", "name": m?.name ?? c.name, "metadata": JSON(),
                       "available_range": NSNull()]
            }
            var effects = [JSON]()
            var start = c.source.start
            if let h = c.holdFrame {
                start = h
                effects.append(["OTIO_SCHEMA": "FreezeFrame.1", "name": "Freeze Frame", "effect_name": "FreezeFrame",
                                "time_scalar": 0.0, "metadata": JSON()])
            } else {
                var speed = c.speed, reversed = c.reversed
                if c.speedKeys != nil {
                    speed = c.averageSpeed; reversed = false
                    warn("Speed ramp on \"\(c.name)\" written at its average speed")
                }
                if !speed.isNormal || reversed {
                    // Reversed: start_time stays the lowest source frame, the negative scalar plays the range backward.
                    let scalar = Double(speed.num) / Double(speed.den) * (reversed ? -1 : 1)
                    effects.append(["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                                    "time_scalar": scalar, "metadata": JSON()])
                }
            }
            // Clip markers sit in media time (what the reader expects), only those inside the played range.
            let clipMarkers: [JSON] = c.holdFrame != nil ? [] : (c.markers ?? [])
                .filter { $0.time >= c.source.start && $0.time < c.source.end }.sorted { $0.time < $1.time }
                .map { ["OTIO_SCHEMA": "Marker.2", "name": $0.name, "color": color($0.color),
                        "marked_range": range($0.time, max($0.duration, .zero)), "comment": $0.comment, "metadata": JSON()] }
            return ["OTIO_SCHEMA": "Clip.2", "name": c.name, "source_range": range(start, c.duration),
                    "media_reference": ref, "effects": effects, "markers": clipMarkers, "metadata": JSON(),
                    "enabled": true]
        }

        func trackJSON(_ t: Track) -> JSON {
            let clips = t.clips.filter(usable).sorted { $0.start < $1.start }
            var children = [JSON]()
            var cursor = Time.zero
            for (i, c) in clips.enumerated() {
                if c.start > cursor {
                    children.append(["OTIO_SCHEMA": "Gap.1", "name": "", "source_range": range(.zero, c.start - cursor),
                                     "effects": [JSON](), "markers": [JSON](), "metadata": JSON()])
                }
                // A dissolve between this clip and the one before sits between the two items.
                if i > 0, clips[i - 1].timeline.end == c.start,
                   let tr = t.transitions.first(where: { $0.outgoing == clips[i - 1].id && $0.incoming == c.id }) {
                    var before: Time
                    switch tr.alignment {
                    case .center: before = tr.duration.halved.snapped(to: fd)
                    case .startAtCut: before = .zero
                    case .endAtCut: before = tr.duration
                    case .custom: before = tr.customBefore
                    }
                    before = min(max(before, .zero), tr.duration)
                    let type = tr.kind == .crossDissolve || tr.kind == .quickFade || tr.kind.trackKind == .audio
                        ? "SMPTE_Dissolve" : "Custom_Transition"
                    if tr.kind != .crossDissolve && tr.kind != .quickFade && tr.kind != .constantPower && tr.kind != .constantGain {
                        warn("Transition \"\(tr.kind.rawValue)\" written as a custom transition named \(tr.kind.name)")
                    }
                    children.append(["OTIO_SCHEMA": "Transition.1", "name": tr.kind.name, "transition_type": type,
                                     "in_offset": rt(before), "out_offset": rt(tr.duration - before), "metadata": JSON()])
                }
                children.append(clipJSON(c))
                cursor = c.timeline.end
            }
            if t.transitions.contains(where: { $0.outgoing == nil || $0.incoming == nil }) {
                warn("Fade at a clip edge is not exported")
            }
            return ["OTIO_SCHEMA": "Track.1", "name": t.name, "kind": t.kind == .video ? "Video" : "Audio",
                    "children": children, "source_range": NSNull(), "effects": [JSON](), "markers": [JSON](),
                    "metadata": JSON(), "enabled": true]
        }

        let tracks = timeline.tracks.map(trackJSON)
        if !timeline.tracks.contains(where: { $0.clips.contains(where: { usable($0) }) }) {
            warn("The sequence has no clips OpenTimelineIO can carry")
        }
        let markers: [JSON] = timeline.markers.sorted { $0.time < $1.time }.map { m in
            ["OTIO_SCHEMA": "Marker.2", "name": m.name, "color": color(m.color),
             "marked_range": range(m.time, max(m.duration, .zero)), "comment": m.comment, "metadata": JSON()]
        }
        let stack: JSON = ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": tracks, "source_range": NSNull(),
                           "effects": [JSON](), "markers": markers, "metadata": JSON(), "enabled": true]
        let root: JSON = ["OTIO_SCHEMA": "Timeline.1", "name": timeline.name, "tracks": stack,
                          "global_start_time": rt(timeline.timecodeStart), "metadata": JSON()]
        return root
    }
}
