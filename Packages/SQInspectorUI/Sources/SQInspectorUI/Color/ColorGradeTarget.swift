import Foundation
import SQCore

/// What the Color panel, the eyedropper and Auto work on.
public enum ColorTargetResolution: Equatable, Sendable {
    case clip(Clip.ID)
    /// The whole sequence; `layer` is nil until the first edit creates the Timeline grade layer.
    case sequence(Timeline.ID, layer: Clip.ID?)
    /// Nothing gradable: one sentence saying why (shown instead of an empty panel).
    case message(String)
}

/// Which clip the Color panel grades (pure, tested in ColorTargetBarTests / ColorClipsPanelTests).
///
/// Sync rule between the Clips panel and the timeline (DECISIONS 2026-10-03 "Color page + timeline header"):
/// - Picking a source row selects one of its cuts in the timeline (the host moves the playhead onto it when it is
///   elsewhere, so the monitor and scopes show what is graded). Picking "Whole sequence" selects the Timeline grade layer
///   (or nothing before it exists).
/// - Selecting one picture clip in the timeline targets it (also out of "Whole sequence"); selecting the Timeline grade
///   layer targets the whole sequence. An empty timeline selection keeps the target, so clicking into empty timeline
///   space never drops what is being graded.
/// - Audio, several clips, text/graphics or a nested sequence selected in the timeline give a one-line explanation
///   instead of the panel (not while "Whole sequence" is targeted); picking in the list ends that.
public struct ColorTargetState: Equatable, Sendable {
    /// "Whole sequence" is targeted (the Timeline grade).
    public private(set) var wholeSequence = false
    /// The clip the Clips panel points at.
    public private(set) var pick: Clip.ID?
    /// Why the timeline selection cannot be graded (nil = it can, or nothing is selected).
    public private(set) var notice: String?

    public init(pick: Clip.ID? = nil) { self.pick = pick }

    static let audioNotice = "Audio clips have no picture. Select a video clip in the timeline, or a source in Clips."
    static let nestedNotice = "A nested sequence is graded inside: open it and grade its clips, or use an adjustment layer above it."
    static let generatorNotice = "Text and graphics take no grade. Their colors are set in Effect Controls."
    static func multiNotice(_ n: Int) -> String {
        "\(n) clips selected. Pick one source in Clips to grade it; Paste Grade (\u{2318}V) applies the copied grade to all of them."
    }
    static let nothingNotice = "Select a clip in the timeline to grade it."
    static let emptyNotice = "This sequence has no video clips yet."
    static let noSequenceNotice = "Open a sequence to grade it."

    /// The empty state (title, hint) the Color panel shows for a resolution message (INTERACTION-AUDIT §10): what is
    /// missing as the title, the message itself as the hint.
    static func emptyState(_ message: String) -> (title: String, hint: String) {
        switch message {
        case noSequenceNotice: return ("No sequence open", message)
        case emptyNotice: return ("No video clips", "Add clips to the sequence to grade them.")
        case nothingNotice: return ("No clip selected", message)
        case audioNotice: return ("Audio has no picture", message)
        case nestedNotice: return ("Nested sequence", message)
        case generatorNotice: return ("Text or graphic selected", message)
        default: return (message.contains("clips selected") ? "Several clips selected" : "No clip selected", message)
        }
    }

    /// The timeline selection changed.
    public mutating func selectionChanged(_ selection: Set<Clip.ID>, in timeline: Timeline?) {
        guard let timeline, !selection.isEmpty else { notice = nil; return }
        guard let c = timeline.primaryClip(of: selection) else {
            guard !wholeSequence else { return }
            let pictures = timeline.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.kind == .video }
            if pictures.isEmpty { notice = Self.audioNotice } else { notice = Self.multiNotice(pictures.count) }
            return
        }
        if c.isSequenceGrade { wholeSequence = true; notice = nil; return }
        if c.acceptsColor { pick = c.id; wholeSequence = false; notice = nil; return }
        guard !wholeSequence else { return }
        if c.kind == .audio { notice = Self.audioNotice }
        else if c.isNested { notice = Self.nestedNotice }
        else { notice = Self.generatorNotice }
    }

    /// A clip (a source row's cut) was picked in the Clips panel (the host also selects it in the timeline).
    public mutating func listPicked(_ id: Clip.ID) {
        pick = id
        notice = nil
        wholeSequence = false
    }

    /// "Whole sequence" was picked in the Clips panel.
    public mutating func wholeSequencePicked() {
        wholeSequence = true
        notice = nil
    }

    public func resolve(in timeline: Timeline?) -> ColorTargetResolution {
        guard let timeline else { return .message(Self.noSequenceNotice) }
        if wholeSequence { return .sequence(timeline.id, layer: timeline.sequenceGradeClip?.id) }
        if let notice { return .message(notice) }
        if let pick, let c = timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == pick }), c.acceptsColor,
           !c.isSequenceGrade {
            return .clip(pick)
        }
        // Nothing picked or selected: the Whole Sequence is the visible default target (the chip says so; the layer is
        // created on the first change, DECISIONS 2026-10-13 App audit).
        if ColorSourceListItem.items(timeline).isEmpty { return .message(Self.emptyNotice) }
        return .sequence(timeline.id, layer: timeline.sequenceGradeClip?.id)
    }

    /// "On screen: X" when the Program monitor does not show `target` at `playhead` (nil = it does). The picture on screen
    /// is the topmost visible clip there; adjustment layers and the Timeline grade show no picture of their own.
    public static func onScreenHint(target: ColorTargetResolution, timeline: Timeline?, playhead: Time) -> String? {
        guard let timeline, case .clip(let id) = target,
              let clip = timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
        if clip.timeline.contains(playhead) { return nil }
        for track in timeline.tracks.reversed() where track.kind == .video && track.isVisible {
            if let c = track.clips.first(where: { $0.timeline.contains(playhead) && $0.isEnabled && !$0.isAdjustment }) {
                return "On screen: \(c.name)"
            }
        }
        return "On screen: no clip"
    }
}

/// One row of the Clips panel: a source file of the active sequence (all its cuts share one grade while Linked), or an
/// adjustment layer (a row of its own: it has no source).
public struct ColorSourceListItem: Equatable, Sendable {
    /// The source file (an adjustment layer's own id).
    public var media: UUID
    /// The file name from the project's media, else the first cut's clip name.
    public var name: String
    /// The cuts of this source in timeline order (start, then the upper track first).
    public var clips: [Clip.ID]
    /// Any cut carries a grade.
    public var graded: Bool
    public var isAdjustment: Bool
    /// The grade state of its cuts (`ColorClipRow.gradeText`), "Mixed grades" when they differ.
    public var gradeText = "No grade"

    /// The sources of `timeline`'s picture clips that take color, in order of their first cut. The Timeline grade layer
    /// is not listed (it is the "Whole sequence" row).
    public static func items(_ timeline: Timeline?, project: Project? = nil) -> [ColorSourceListItem] {
        guard let timeline else { return [] }
        var cuts: [(Time, Int, Clip)] = []
        for (k, tr) in timeline.tracks.enumerated() where tr.kind == .video {
            for c in tr.clips where c.acceptsColor && !c.isSequenceGrade { cuts.append((c.start, -k, c)) }
        }
        cuts.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [ColorSourceListItem] = []
        var index: [UUID: Int] = [:]
        for (_, _, c) in cuts {
            if let i = index[c.media] {
                out[i].clips.append(c.id)
                if !c.colorGradeEffects.isEmpty { out[i].graded = true }
                if Self.gradeText(of: c) != out[i].gradeText { out[i].gradeText = "Mixed grades" }
                continue
            }
            index[c.media] = out.count
            let file = c.isAdjustment ? nil : project?.media.first(where: { $0.id == c.media })?.name
            out.append(ColorSourceListItem(media: c.media, name: file ?? c.name, clips: [c.id],
                                           graded: !c.colorGradeEffects.isEmpty, isAdjustment: c.isAdjustment,
                                           gradeText: Self.gradeText(of: c)))
        }
        return out
    }

    static func gradeText(of c: Clip) -> String {
        ColorClipRow.gradeText(hasSimple: !c.colorGradeEffects.isEmpty, graph: c.colorGraph)
    }

    /// The cut a pick of this row grades: `picked` when it is one of them, else the first cut that is "Linked" (its grade
    /// is the source's), else the first cut.
    public func clipToGrade(picked: Clip.ID?, in project: Project) -> Clip.ID {
        if let picked, clips.contains(picked) { return picked }
        return clips.first { project.isGradeLinkedToSource($0) } ?? clips[0]
    }
}

/// The clips the timeline outlines on the Color page: the one being graded plus every clip that shares its grade (its
/// grade link, and while "Linked" every other use of its source). The Timeline grade layer outlines itself only.
public enum ColorGradeOutline {
    public static func clips(_ target: ColorTargetResolution, project: Project) -> Set<Clip.ID> {
        switch target {
        case .message: return []
        case .sequence(_, let layer): return layer.map { [$0] } ?? []
        case .clip(let id):
            var out: Set<Clip.ID> = [id]
            out.formUnion(project.gradeLinkMembers(of: id))
            if project.isGradeLinkedToSource(id), let media = project.timelines.lazy.flatMap(\.tracks).flatMap(\.clips).first(where: { $0.id == id })?.media {
                for t in project.timelines { for tr in t.tracks { for c in tr.clips where c.media == media && c.isSourceGradeable && project.isGradeLinkedToSource(c.id) { out.insert(c.id) } } }
            }
            return out
        }
    }
}
