import Foundation
import SQCore

/// One Fast Cut verb (SQCore Timeline+MagneticOps.swift), replayable like any `TimelineEdit`. Built by
/// `TimelineEdit.fastCut(_:in:keepAttached:)` from what a gesture or command would do in Normal.
public enum FastCutEdit: Sendable, Equatable {
    /// Delete: main-track clips close up with their attached clips (`keepAttached`: those stay on their frame).
    case delete([Clip.ID], keepAttached: Bool)
    /// Replace with Spacer: main-track clips leave a hole, attached clips stay.
    case replaceWithSpacer([Clip.ID])
    case rippleTrim(Clip.ID, edge: ClipEdge, by: Time)
    case roll(Clip.ID, by: Time)
    case slip(Clip.ID, by: Time, keyframes: SlipKeyframes)
    case slide(Clip.ID, by: Time)
    /// A main-track clip dragged along V1 (`to`: pre-edit time; it lands on the nearest V1 edit).
    case rearrange(Clip.ID, to: Time, keepAttached: Bool)
    /// An attached clip dragged (any track but V1); nothing else moves.
    case moveAttached(Clip.ID, to: Time, track: Track.ID?)
    /// A main-track clip dragged onto another track: V1 closes, the clip becomes attached.
    case dragOff(Clip.ID, track: Track.ID, to: Time, keepAttached: Bool)
    /// An attached clip dragged onto V1: inserted at the nearest edit (`overwrite`: covers from `at`).
    case dragOnto(Clip.ID, at: Time, overwrite: Bool)
    /// Cut at `at`: the given clips, or (empty) the main clip under `at` with its own sound.
    case addEdit(at: Time, clips: [Clip.ID])
    case addEditAll(at: Time)
    case nudge([Clip.ID], by: Time)
    /// Delete on a spacer (a hole of V1) under `at`.
    case deleteSpacer(at: Time, keepAttached: Bool)
    /// Several main-track clips dragged at once by `by`: along V1 (`track` nil or V1) one run at the nearest edit
    /// (`magneticRearrangeBlock`), else off V1 onto `track` (`dragOffMainTrack`).
    case moveBlock([Clip.ID], by: Time, track: Track.ID?, keepAttached: Bool)
    /// Option-drag / Cmd+Option-drag copies by `by` (`magneticCopy`): onto V1 inserted, elsewhere attached.
    case copy([MagneticCopy], by: Time)
    /// Close Gap on a track other than V1: only that lane (and linked partners off V1) moves.
    case closeLaneGap(Track.ID, at: Time)
    case rateStretch(Clip.ID, edge: ClipEdge, by: Time)
    /// Speed/Duration or Reverse: main-track clips ripple V1 whatever the Ripple setting.
    case speed([Clip.ID], SpeedChange)
    /// Create Storyline: the clips join the lane of the earliest one (`Timeline.createStoryline`).
    case createStoryline([Clip.ID])
    /// Ripple delete inside a storyline: the later connected clips of the run close up (`Timeline.storylineRippleDelete`).
    case storylineRippleDelete(Clip.ID)
    /// A storyline clip dragged along its lane: the run reorders and closes up (`Timeline.storylineRearrange`).
    case storylineRearrange(Clip.ID, to: Time)
    /// Position tool: the clip (with partners, `partners` = their target tracks) lands at `to` overwriting, leaves a hole.
    case positionMove(Clip.ID, to: Time, track: Track.ID?, partners: [Clip.ID: Track.ID])
    /// Any other edit run with the Fast Cut rules (`Timeline.magneticEdit`): attached clips follow or `stay`.
    case run([TimelineEdit], involving: [Clip.ID], stay: MagneticStay)

    public func apply(to t: inout Timeline) throws {
        switch self {
        case let .delete(ids, keep): try t.magneticDelete(Set(ids), keepAttached: keep)
        case .replaceWithSpacer(let ids): try t.replaceWithSpacer(Set(ids))
        case let .rippleTrim(id, edge, d): try t.magneticRippleTrim(id, edge: edge, by: d)
        case let .roll(id, d): try t.magneticRoll(id, by: d)
        case let .slip(id, d, keys): try t.magneticSlip(id, by: d, keyframes: keys)
        case let .slide(id, d): try t.magneticSlide(id, by: d)
        case let .rearrange(id, to, keep): try t.magneticRearrange(id, to: to, keepAttached: keep)
        case let .moveAttached(id, to, track): try t.moveAttached(id, to: to, track: track)
        case let .dragOff(id, track, to, keep): try t.dragOffMainTrack(id, to: track, at: to, keepAttached: keep)
        case let .dragOnto(id, at, overwrite): try t.dragOntoMainTrack(id, at: at, overwrite: overwrite)
        case let .addEdit(at, ids): try t.magneticAddEdit(at: at, selection: Set(ids))
        case .addEditAll(let at): try t.magneticAddEditAll(at: at)
        case let .nudge(ids, d): try t.magneticNudge(Set(ids), by: d)
        case let .deleteSpacer(at, keep): try t.deleteSpacer(at: at, keepAttached: keep)
        case let .moveBlock(ids, d, track, keep):
            if let track, track != t.mainTrackID {
                try t.dragOffMainTrack(Set(ids), to: track, by: d, keepAttached: keep)
            } else {
                try t.magneticRearrangeBlock(Set(ids), by: d, keepAttached: keep)
            }
        case let .copy(items, d): try t.magneticCopy(items, by: d)
        case let .closeLaneGap(track, at): try t.closeLaneGap(on: track, at: at)
        case let .rateStretch(id, edge, d): try t.magneticRateStretch(id, edge: edge, by: d)
        case let .speed(ids, change): try t.magneticApply(change, to: ids)
        case .createStoryline(let ids): try t.createStoryline(Set(ids))
        case .storylineRippleDelete(let id): try t.storylineRippleDelete(id)
        case let .storylineRearrange(id, to): try t.storylineRearrange(id, to: to)
        case let .positionMove(id, to, track, partners):
            // shortcut: with retargeted partners (a drag onto another lane) the main-track end clamp of
            // `Timeline.positionMove` is skipped; upgrade when SQCore's positionMove takes `retarget`.
            if partners.isEmpty { try t.positionMove(id, to: to, track: track) } else {
                try t.magneticEdit(involving: [id], stay: .all) { _ = try $0.move(id, to: to, track: track, retarget: partners) }
            }
        case let .run(edits, ids, stay):
            try t.magneticEdit(involving: Set(ids), stay: stay) { w in for e in edits { try e.apply(to: &w) } }
        }
    }
}

/// Fast Cut (docs/ARCHITECTURE.md "Fast Cut operations"): what a gesture's or command's edits become in a sequence whose
/// edit mode is Fast Cut. Normal sequences never go through here. Sync lock plays no part in Fast Cut: who follows whom is
/// the stored attachments' job (`Timeline.magneticEdit`).
extension TimelineEdit {
    /// `edits` as Fast Cut does them in `t` (unchanged when `t` is not in Fast Cut). `keepAttached` (hold `) keeps the
    /// attached clips of the deleted or dragged main-track clips on their frame.
    /// - Delete (lift / ripple delete) -> `magneticDelete`; trims -> ripple trims of V1 (attached clips alone);
    ///   roll, slip, slide, nudge, add edit -> their Fast Cut verbs.
    /// - Drag of ONE main-track clip: along V1 -> rearrange at the nearest edit, onto another track -> drag off V1 (it
    ///   becomes attached). Its attached clips travel with it, so their own moves are dropped. Drag of an attached clip:
    ///   onto V1 -> insert there, elsewhere -> moved without covering anything.
    /// - Several main-track clips dragged at once -> one block (`moveBlock`): along V1 one run at the nearest edit, else
    ///   off V1. Option-drag / Cmd+Option-drag copies -> `copy` (onto V1 inserted at the nearest edit, else attached).
    /// - Close Gap off V1 -> only that lane closes. Rate stretch and speed -> their Fast Cut verbs (V1 ripples).
    /// - Extend edit and split edits run inside `magneticEdit` with the attached clips on their frame.
    public static func fastCut(_ edits: [TimelineEdit], in t: Timeline, keepAttached: Bool = false,
                               position: Bool = false) -> [TimelineEdit] {
        guard t.isFastCut, let main = t.mainTrackID else { return edits }
        // Position tool: plain drags overwrite where they land and leave a hole; copies and the rest go the usual way.
        if position {
            var rest: [TimelineEdit] = [], moves: [TimelineEdit] = []
            for e in edits {
                switch e {
                case let .move(id, to, track): moves.append(.fastCut(.positionMove(id, to: to, track: track, partners: [:])))
                case let .moveGroup(id, to, track, partners):
                    moves.append(.fastCut(.positionMove(id, to: to, track: track, partners: partners)))
                default: rest.append(e)
                }
            }
            return fastCut(rest, in: t, keepAttached: keepAttached) + moves
        }
        func isMainMove(_ e: TimelineEdit) -> Bool {
            switch e {
            case let .move(id, _, _), let .moveGroup(id, _, _, _), let .moveInsert(id, _, _), let .insertMove(id, _, _):
                t.mainClip(of: id) != nil
            default: false
            }
        }
        func clip(_ id: Clip.ID) -> Clip? { t.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }
        let mainMoves = edits.filter(isMainMove)
        let mains = Set(mainMoves.compactMap { $0.movedClip.flatMap(t.mainClip(of:)) })
        // The rearranged / dragged-off main clips carry their attached clips: their own moves would double them.
        let carried: Set<Clip.ID> = keepAttached ? [] : Set(t.attachedClips(of: mains))
        // Several main-track clips at once: one block. The V1 clips' destination is the dragged clip's own track when it
        // is the V1 clip, else its partner destination.
        let block: TimelineEdit? = mains.count > 1 ? mainMoves.first.flatMap { e -> TimelineEdit? in
            guard let id = e.movedClip, let m = t.mainClip(of: id), let c = clip(id) else { return nil }
            let target: Track.ID?
            switch e {
            case let .move(_, _, track), let .moveInsert(_, _, track), let .insertMove(_, _, track): target = id == m ? track : nil
            case let .moveGroup(_, _, track, partners): target = id == m ? track : partners[m]
            default: target = nil
            }
            guard let to = e.moveTarget else { return nil }
            let ordered = mains.sorted { (clip($0)?.start ?? .zero) < (clip($1)?.start ?? .zero) }
            return .fastCut(.moveBlock(ordered, by: to - c.start, track: target, keepAttached: keepAttached))
        } : nil
        // Copies: all of one gesture go into one `copy` (one delta), emitted where the first one was.
        let copies: [MagneticCopy] = edits.compactMap { e in
            switch e {
            case let .copyGroup(id, _, track, partners, spec): MagneticCopy(clip: id, track: track, partners: partners, spec: spec)
            case let .insertCopy(id, _, track, spec): MagneticCopy(clip: id, track: track, spec: spec)
            default: nil
            }
        }
        let copyDelta: Time? = edits.lazy.compactMap { e -> Time? in
            switch e {
            case let .copyGroup(id, to, _, _, _), let .insertCopy(id, to, _, _): clip(id).map { to - $0.start }
            default: nil
            }
        }.first
        var emittedBlock = false, emittedCopy = false
        // A main clip dragged with its linked sound arrives as two move edits: one rearrange (or drag off) per main clip.
        var movedMains: Set<Clip.ID> = []
        var lineHandled: Set<Clip.ID> = []

        func map(_ e: TimelineEdit) -> [TimelineEdit] {
            switch e {
            case .lift(let ids), .rippleDelete(let ids):
                return [.fastCut(.delete(ids, keepAttached: keepAttached))]
            case let .trim(id, edge, d), let .rippleTrim(id, edge, d):
                return [.fastCut(.rippleTrim(id, edge: edge, by: d))]
            case let .roll(id, d): return [.fastCut(.roll(id, by: d))]
            case let .slip(id, d, keys): return [.fastCut(.slip(id, by: d, keyframes: keys))]
            case let .slide(id, d): return [.fastCut(.slide(id, by: d))]
            case let .nudge(ids, d): return [.fastCut(.nudge(ids, by: d))]
            case let .move(id, to, track), let .moveGroup(id, to, track, _), let .moveInsert(id, to, track),
                 let .insertMove(id, to, track):
                if let block, t.mainClip(of: id) != nil {
                    if emittedBlock { return [] }
                    emittedBlock = true
                    return [block]
                }
                if let m = t.mainClip(of: id), let c = clip(id), let mc = clip(m) {
                    // The partner's move would rearrange the same clip again, against the already changed layout.
                    if !movedMains.insert(m).inserted { return [] }
                    let target = id == m ? track : nil          // camera audio dragged: its main clip moves along V1
                    if let target, target != main {
                        return [.fastCut(.dragOff(m, track: target, to: to, keepAttached: keepAttached))]
                    }
                    return [.fastCut(.rearrange(m, to: mc.start + (to - c.start), keepAttached: keepAttached))]
                }
                if carried.contains(id) || lineHandled.contains(id) { return [] }
                // A storyline clip dragged along its own lane reorders the run (Fast Cut storylines are gapless).
                if let line = t.storyline(containing: id), track == nil || track == line.track {
                    lineHandled.insert(id)
                    if let l = clip(id)?.link {      // linked partners travel with it
                        lineHandled.formUnion(t.tracks.flatMap(\.clips).filter { $0.link == l }.map(\.id))
                    }
                    return [.fastCut(.storylineRearrange(id, to: to))]
                }
                if track == main { return [.fastCut(.dragOnto(id, at: to, overwrite: false))] }
                return [.fastCut(.moveAttached(id, to: to, track: track))]
            case .copyGroup, .insertCopy:
                guard !emittedCopy, let d = copyDelta else { return [] }
                emittedCopy = true
                return [.fastCut(.copy(copies, by: d))]
            case let .addEdit(at, ids):
                guard let ids else { return [.fastCut(.addEditAll(at: at))] }
                let under = t.tracks.filter { ids.contains($0.id) }.flatMap { $0.clips.filter { $0.start < at && $0.timeline.contains(at) } }
                return under.isEmpty ? [] : [.fastCut(.addEdit(at: at, clips: under.map(\.id)))]
            case let .closeGap(track, at):
                if track == main { return [.fastCut(.deleteSpacer(at: at, keepAttached: keepAttached))] }
                return [.fastCut(.closeLaneGap(track, at: at))]
            case let .only(list, inner):
                // The partners held back are detached while the edit runs, so the inner edits are mapped against that
                // layout: a sound dragged alone is a lone clip (not a rearrange of its video), V1 stays gapless.
                var detached = t, probe = t
                try? probe.editing(only: Set(list)) { detached = $0 }
                return [.only(list, fastCut(inner, in: detached, keepAttached: keepAttached))]
            case let .rateStretch(id, edge, d):
                return [.fastCut(.rateStretch(id, edge: edge, by: d))]
            case let .speed(ids, change):
                return [.fastCut(.speed(ids, change))]
            case .extendEdit, .splitEditAudio:
                return [.fastCut(.run([e], involving: [], stay: .all))]
            case .addTrack, .link, .unlink, .moveCaption, .trimCaption, .deleteCaption, .retimeCaptionWord, .fastCut:
                return [e]
            }
        }
        return edits.flatMap(map)
    }

    /// Where a move edit puts the dragged clip.
    var moveTarget: Time? {
        switch self {
        case let .move(_, to, _), let .moveGroup(_, to, _, _), let .moveInsert(_, to, _), let .insertMove(_, to, _): to
        default: nil
        }
    }

    /// The clip a move edit drags.
    var movedClip: Clip.ID? {
        switch self {
        case let .move(id, _, _), let .moveGroup(id, _, _, _), let .moveInsert(id, _, _), let .insertMove(id, _, _): id
        default: nil
        }
    }

    /// Delete or ripple delete (what the Delete keys build).
    var isDelete: Bool {
        switch self {
        case .lift, .rippleDelete: true
        default: false
        }
    }
}
