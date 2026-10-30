import Foundation
import SQCore
import SQDrawKit

/// W6.7 MasksV1: the minimal editing hooks for clip masks (add, delete, drag a vertex in the Program monitor).
extension EffectControlsModel {
    /// Enabled masks of the clip with their paths at the playhead, for the Program monitor overlay. Subject masks (W9.8, a
    /// person matte) have no path to show or drag, so they get no outline and no handles.
    public var maskOverlays: [MaskOverlay] {
        guard let c = clip else { return [] }
        let local = localPlayhead, active = activeMaskID
        return c.masks.filter { $0.enabled && $0.source == .path }
            .map { MaskOverlay(id: $0.id, path: $0.path.value(atLocal: local), active: $0.id == active) }
    }

    /// The mask the pen handles edit: the one selected in Effect Controls, else the clip's only enabled path mask.
    public var activeMaskID: ClipMask.ID? {
        guard let c = clip else { return nil }
        let paths = c.masks.filter { $0.enabled && $0.source == .path }
        if case .mask(let id)? = selectedSection, paths.contains(where: { $0.id == id }) { return id }
        return paths.count == 1 ? paths[0].id : nil
    }

    /// Edits the path shown at the playhead (a key there when animated; nothing outside the clip then). Inside a gesture
    /// `body` starts from the gesture base, so a drag is one undo step.
    private func editMaskPathAtPlayhead(_ id: ClipMask.ID, _ name: String, _ body: (inout MaskPath) -> Bool) {
        guard var c = workingClip, let m = c.mask(id) else { return }
        if m.path.isAnimated, !playheadInClip { return }
        let local = localPlayhead
        var path = m.path.value(atLocal: local)
        guard body(&path) else { return }
        c.setMaskPath(id, path, atLocal: local)
        commit(c, name)
    }

    /// True when editing this mask's path would do nothing: it is animated and the playhead is outside the clip (no key to write).
    public func maskEditNeedsPlayhead(_ id: ClipMask.ID) -> Bool {
        guard let m = clip?.mask(id) else { return false }
        return m.path.isAnimated && !playheadInClip
    }

    /// Drags a tangent handle to `offset` (from its vertex); the other side mirrors unless `independent` (Option).
    public func moveMaskTangent(_ id: ClipMask.ID, index: Int, out: Bool, to offset: Vec2, independent: Bool) {
        editMaskPathAtPlayhead(id, "Move Mask Handle") { p in
            guard p.vertices.indices.contains(index) else { return false }
            p.setTangent(index, out: out, to: offset, independent: independent)
            return true
        }
    }

    /// Moves the whole mask by `d` (frame fractions) from where the gesture began.
    public func moveMask(_ id: ClipMask.ID, by d: Vec2) {
        editMaskPathAtPlayhead(id, "Move Mask") { p in p = p.translated(by: d); return true }
    }

    /// Option-click on a vertex: corner <-> smooth.
    public func toggleMaskVertexSmooth(_ id: ClipMask.ID, index: Int) {
        editMaskPathAtPlayhead(id, "Convert Mask Vertex") { p in
            guard p.vertices.indices.contains(index) else { return false }
            p = p.togglingSmooth(index)
            return true
        }
    }

    /// Click on the outline: a vertex there, in the static path and every key (keys keep blending).
    public func insertMaskVertex(_ id: ClipMask.ID, segment: Int, at t: Double) {
        guard var c = workingClip, c.mask(id) != nil else { return }
        c.insertMaskVertex(id, segment: segment, at: t)
        commit(c, "Add Mask Vertex")
    }

    /// Pen: press on the outline places a vertex, dragging pulls its handles to `handle` (offset from the point; mirrored
    /// unless `independent`). Inside a gesture every call starts from the gesture base, so a drag is one undo step.
    public func placeMaskVertex(_ id: ClipMask.ID, segment: Int, at t: Double, handle: Vec2, independent: Bool) {
        guard var c = workingClip, let m = c.mask(id) else { return }
        if m.path.isAnimated, !playheadInClip { return }
        c.placeMaskVertex(id, segment: segment, at: t, handle: handle, independent: independent, atLocal: localPlayhead)
        commit(c, "Add Mask Vertex")
    }

    /// Command-click on a vertex: deletes it from the path and every key (a mask keeps at least three).
    public func removeMaskVertex(_ id: ClipMask.ID, index: Int) {
        guard var c = workingClip, c.removeMaskVertex(id, index) else { onNotice?("A mask needs at least three points."); return }
        commit(c, "Delete Mask Vertex")
    }

    /// Frames per tracker call: a stopped track keeps every finished chunk (each chunk starts on the shape the one before ended on).
    static let trackChunk = 60

    /// Track Forward / Backward: follows the mask (what `maskTrackMode` says) from the playhead to the clip's last (first) frame and keys the
    /// path on every frame, one undo step. Stops where the tracker loses the object. Returns the keys written. When the task is
    /// cancelled the frames done so far are written (same undo step) and `MaskTrackStopped` says how many. The result goes to the
    /// tracked clip by id (`clipByID` finds it when another clip is shown meanwhile). `mayWrite` is asked right before the
    /// project changes: false (the run lost its slot: its mask was removed, another run started) writes nothing.
    public func trackMask(_ id: ClipMask.ID, forward: Bool, tracker: any MaskTracking,
                          clipByID: ((Clip.ID) -> Clip?)? = nil,
                          mayWrite: (@MainActor () -> Bool)? = nil,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        guard let c = clip, let m = c.mask(id), m.source == .path, playheadInClip else { return 0 }
        let times = c.maskTrackTimes(fromLocal: localPlayhead.snapped(to: frameDuration), forward: forward,
                                     frameDuration: frameDuration)
        guard !times.isEmpty else { return 0 }
        // Between the path keys already set the track re-anchors: each stretch starts from its key and the drift at its end
        // is spread over it (DECISIONS 2026-10-06 "Mask tracking re-anchors").
        let segments = c.maskTrackSegments(id, times: times)
        var motions: [[MaskMotion?]] = []
        var written: [Range<Int>] = []
        var stopped = false
        segmentLoop: for (i, seg) in segments.enumerated() {
            let base = m.path.value(atLocal: times[seg.lowerBound])
            let lo = Double(i) / Double(segments.count), span = 1 / Double(segments.count)
            var acc: [MaskMotion?] = []
            var pos = seg.lowerBound
            var region = base.polygon()
            while true {
                let end = min(pos + Self.trackChunk, seg.upperBound)
                let from = pos - seg.lowerBound, count = Double(max(seg.count - 1, 1)), len = Double(end - pos - 1)
                let got: [MaskMotion?]
                do {
                    got = try await tracker.track(region: region, mode: maskTrackMode,
                                                  sourceTimes: times[pos..<end].map { c.sourceInstant(atLocal: $0) },
                                                  progress: progress.map { p in { @Sendable f in p(lo + span * (Double(from) + f * len) / count) } })
                } catch is CancellationError {
                    stopped = true
                    if acc.count > 1 { motions.append(acc); written.append(seg.lowerBound..<(seg.lowerBound + acc.count)) }
                    break segmentLoop
                }
                // A chunk's motion is relative to its first frame; carry the motion reached so far in front of it.
                let carry: MaskMotion? = acc.last.flatMap { $0 }
                for (k, g) in got.enumerated() where acc.isEmpty || k > 0 {
                    acc.append(g.map { g in carry.map { $0.then(g) } ?? g })
                }
                let lost = got.contains { $0 == nil }
                if lost || end >= seg.upperBound { break }
                pos = end - 1
                region = base.transformed(by: acc[acc.count - 1] ?? MaskMotion(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])).polygon()
            }
            // A lost object ends the chunk loop early: only the frames reached are written (as for a stopped track).
            motions.append(acc); written.append(seg.lowerBound..<(seg.lowerBound + acc.count))
            if acc.contains(where: { $0 == nil }) { break }          // lost: the run ends here
        }
        // The clip may have changed meanwhile: apply to its current state, found by id, even when another clip is shown now.
        if let mayWrite, !mayWrite() {
            if stopped { throw MaskTrackStopped(frames: 0) }
            return 0
        }
        let shown = clip?.id == c.id
        guard var now = shown ? clip : clipByID?(c.id), now.mask(id) != nil else { return 0 }
        let n = now.applyMaskTrack(id, times: times, segments: written, motions: motions)
        if n > 0 {
            if shown { commit(now, "Track Mask") } else { onEdit?(now, "Track Mask", false) }
        }
        if stopped { throw MaskTrackStopped(frames: n) }
        return n
    }

    /// Adds a centered Rectangle or Ellipse mask (Premiere's defaults: half the frame, feather 10). Returns its id.
    @discardableResult
    public func addMask(_ kind: MaskShapeKind) -> ClipMask.ID? {
        guard var c = workingClip else { return nil }
        let m = ClipMask.make(kind, name: c.nextMaskName)
        c.masks.append(m)
        commit(c, "Add Mask")
        return m.id
    }

    public func removeMask(_ id: ClipMask.ID) {
        guard var c = workingClip, c.mask(id) != nil else { return }
        c.removeMask(id)            // also drops it from every effect's input
        forgetRemovedMasks([id])
        commit(c, "Delete Mask")
    }

    /// Deletes every mask of the clip, one undo step.
    public func removeAllMasks() {
        guard var c = workingClip, !c.masks.isEmpty else { return }
        let ids = c.masks.map(\.id)
        for id in ids { c.removeMask(id) }
        forgetRemovedMasks(ids)
        commit(c, "Delete Masks")
    }

    /// Moves one vertex of the path at the playhead (a key there when the path is animated; nothing outside the clip then).
    /// Inside a gesture every call starts from the gesture base, one undo step per drag.
    public func moveMaskVertex(_ id: ClipMask.ID, index: Int, to p: Vec2) {
        guard var c = workingClip, let m = c.mask(id) else { return }
        if m.path.isAnimated, !playheadInClip { return }
        let local = localPlayhead
        var path = m.path.value(atLocal: local)
        guard path.vertices.indices.contains(index) else { return }
        path.moveVertex(index, to: p)
        c.setMaskPath(id, path, atLocal: local)
        commit(c, "Move Mask Vertex")
    }

    /// W9.8: subject masks of the clip, top first: one Effect Controls entry each under Opacity.
    public var subjectMaskIDs: [ClipMask.ID] {
        clip?.masks.filter { $0.source == .subject }.map(\.id) ?? []
    }

    /// C6: Picture masks of the clip (their rows differ: a track and a channel instead of a path, no Feather / Expansion).
    public var pictureMaskIDs: Set<ClipMask.ID> {
        Set(clip?.masks.filter { $0.source == .picture }.map(\.id) ?? [])
    }

    public func setMaskInverted(_ id: ClipMask.ID, _ on: Bool) {
        guard var c = workingClip, let m = c.mask(id), m.inverted != on else { return }
        c.updateMask(id) { $0.inverted = on }
        commit(c, "Invert Mask")
    }

    public func setMaskMode(_ id: ClipMask.ID, _ mode: MaskMode) {
        guard var c = workingClip, let m = c.mask(id), m.mode != mode else { return }
        c.updateMask(id) { $0.mode = mode }
        commit(c, "Change Mask Mode")
    }

    /// Stopwatch of a mask's path at the playhead.
    public func setMaskPathAnimated(_ id: ClipMask.ID, _ on: Bool) {
        guard var c = workingClip else { return }
        c.setMaskPathAnimated(id, on, atLocal: localPlayhead)
        commit(c, on ? "Animate Mask Path" : "Stop Animating Mask Path")
    }

    /// Clip-local key times of a mask's path, sorted.
    func maskPathKeyTimes(_ id: ClipMask.ID) -> [Time] {
        (clip?.mask(id)?.path.track.keys.map(\.time) ?? []).sorted()
    }

    /// The Path row's `KeyframeControls` (ring on a key, prev / diamond / next).
    public func maskPathKeyframeState(_ id: ClipMask.ID) -> KeyframeControlState {
        let times = maskPathKeyTimes(id), l = localPlayhead
        return KeyframeControlState.resolve(animated: !times.isEmpty, onKey: times.contains(l),
                                            hasPrevious: times.contains { $0 < l }, hasNext: times.contains { $0 > l },
                                            playheadInRange: playheadInClip)
    }

    public func goToPreviousMaskPathKey(_ id: ClipMask.ID) {
        guard let t = maskPathKeyTimes(id).last(where: { $0 < localPlayhead }) else { return }
        let g = t + (clip?.start ?? .zero)
        revealPlayhead(g); onSeek?(g)
    }

    public func goToNextMaskPathKey(_ id: ClipMask.ID) {
        guard let t = maskPathKeyTimes(id).first(where: { $0 > localPlayhead }) else { return }
        let g = t + (clip?.start ?? .zero)
        revealPlayhead(g); onSeek?(g)
    }

    /// Adds or removes the mask path key at the playhead.
    public func toggleMaskPathKeyAtPlayhead(_ id: ClipMask.ID) {
        guard var c = workingClip, playheadInClip, let m = c.mask(id), m.path.isAnimated else { return }
        let on = maskPathKeyTimes(id).contains(localPlayhead)
        c.toggleMaskPathKey(id, atLocal: localPlayhead)
        commit(c, on ? "Remove Mask Path Keyframe" : "Add Mask Path Keyframe")
    }
}

/// A mask track cancelled by the user; `frames` keys of the finished part were written.
public struct MaskTrackStopped: Error, Equatable { public let frames: Int }
