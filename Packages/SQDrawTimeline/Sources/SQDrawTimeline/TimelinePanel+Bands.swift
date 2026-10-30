import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI

/// One rubber band drag: translated from `VolumeDrag`, `FadeDrag` and `OpacityDrag` of the Mac view.
struct BandDrag {
    enum Kind {
        case volume(VolumeLineGesture)
        case opacity(OpacityLineGesture)
        case fade(handle: FadeHandle, original: Clip, startX: CGFloat, startLength: Time, rect: CGRect)
    }
    var kind: Kind
    var last: Clip
    /// The clip before the drag: Esc puts it back.
    var original: Clip
    /// The undo name the Mac host's `TimelineLineGesture` gives the step ("Volume" also covers the fade handles).
    var name: String
}

/// The volume and opacity rubber bands, translated from TimelineView+VolumeLine.swift and +OpacityLine.swift: the same
/// targets and hit rules; `onVolumeEdit` / `onOpacityEdit` and the host's `TimelineLineGesture` become `.replaceClip`
/// (the first change opens the undo step, later ones continue it) and one `.endGesture` when the drag ends.
extension TimelinePanel {
    /// Clip, track and drawn rectangle under `p` on an audio row tall enough for the volume line (`volumeTarget`).
    func volumeTarget(at p: CGPoint) -> (clip: Clip, track: Track.ID, rect: CGRect)? {
        bandTarget(at: p, kind: .audio) { VolumeLine.isAvailable(rowHeight: $0) }
    }

    /// The same for the opacity line: the line must be shown there and the speed band must not be (`opacityTarget`).
    func opacityTarget(at p: CGPoint) -> (clip: Clip, track: Track.ID, rect: CGRect)? {
        guard let t = bandTarget(at: p, kind: .video, { OpacityLine.isAvailable(rowHeight: $0) }),
              let row = rows.first(where: { $0.track == t.track }),
              OpacityLine.isVisible(clip: t.clip, selected: selection.contains(t.clip.id), rowHeight: row.height),
              !speedBandClips.contains(t.clip.id) else { return nil }
        return t
    }

    private func bandTarget(at p: CGPoint, kind: TrackKind, _ available: (CGFloat) -> Bool)
        -> (clip: Clip, track: Track.ID, rect: CGRect)? {
        guard toolState.timelineTool == .selection, p.x >= TimelineGeometry.contentOriginX,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == kind, available(row.height),
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        // A key sits on the clip edge half outside: look a few points beyond the clip as well.
        guard let clip = track.clips.first(where: { geometry.x(for: $0.timeline.start) - 6 <= p.x && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        return (clip, track.id, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height))
    }

    /// Clip and volume key under `p`, for the "Delete Keyframe" menu.
    public func volumeKey(at p: CGPoint) -> (clip: Clip.ID, key: UUID)? {
        guard let t = volumeTarget(at: p),
              case .key(let id)? = VolumeLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry) else { return nil }
        return (t.clip.id, id)
    }

    /// Clip, handle and current curve of the fade handle under `p`, for the curve menu (curve nil: no fade yet).
    public func fadeHandleHit(at p: CGPoint) -> (clip: Clip.ID, handle: FadeHandle, curve: FadeCurve?)? {
        guard let t = volumeTarget(at: p),
              let h = VolumeLine.fadeHandle(clip: t.clip, clipRect: t.rect, at: p, hidden: hiddenFadeHandles(of: t.clip)) else { return nil }
        return (t.clip.id, h, h == .head ? t.clip.audioFadeInCurve : t.clip.audioFadeOutCurve)
    }

    /// An audio transition on an edge replaces the fade handle there.
    func hiddenFadeHandles(of clip: Clip) -> Set<FadeHandle> {
        var h: Set<FadeHandle> = []
        if timeline.hasAudioTransition(clip: clip.id, head: true) { h.insert(.head) }
        if timeline.hasAudioTransition(clip: clip.id, head: false) { h.insert(.tail) }
        return h
    }

    // MARK: Press

    /// Fade handles first, then the volume line, then the opacity line (`beginVolumeDrag`, `beginOpacityDrag`).
    /// nil: the press is not on a band.
    mutating func bandDown(_ p: CGPoint, command: Bool, shift: Bool) -> [TimelineAction]? {
        if let t = volumeTarget(at: p), t.rect.contains(CGPoint(x: p.x, y: t.rect.midY)),
           let h = VolumeLine.fadeHandle(clip: t.clip, clipRect: t.rect, at: p, hidden: hiddenFadeHandles(of: t.clip)) {
            let len = h == .head ? t.clip.audioFadeIn : t.clip.audioFadeOut
            return beginBand(.fade(handle: h, original: t.clip, startX: p.x, startLength: len, rect: t.rect),
                             clip: t.clip, name: "Volume", key: nil)
        }
        if let t = volumeTarget(at: p), let hit = VolumeLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry),
           takesBand(hit.isKey, at: p, rect: t.rect, command: command) {
            let g = VolumeLineGesture(clip: t.clip, hit: hit, start: p, clipRect: t.rect, geometry: geometry, addKey: command)
            let key = hit.keyID.map { (LineKeyRef(clip: t.clip.id, property: .volume, key: $0), shift) }
            return beginBand(.volume(g), clip: t.clip, name: "Volume", key: key)
        }
        // A transition box sits on the clip edge and wins over the opacity line underneath it.
        if TransitionLayout.hitTest(p, in: timeline, geometry: geometry) == nil, let t = opacityTarget(at: p),
           let hit = OpacityLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry) {
            // A plain 100 % line only answers Cmd-click: a drag near the top of the picture must still move the clip.
            let opacity = t.clip.animation.opacity
            let plain = !opacity.isAnimated && opacity.value == 1
            if (command || !plain), takesBand(hit.isKey, at: p, rect: t.rect, command: command) {
                let g = OpacityLineGesture(clip: t.clip, hit: hit, start: p, clipRect: t.rect, geometry: geometry, addKey: command)
                let key = hit.keyID.map { (LineKeyRef(clip: t.clip.id, property: .opacity, key: $0), shift) }
                return beginBand(.opacity(g), clip: t.clip, name: "Opacity", key: key)
            }
        }
        return nil
    }

    /// Trimming wins at the clip edges unless Cmd is held (keys inside the edge zone, the line in a trim zone).
    private func takesBand(_ isKey: Bool, at p: CGPoint, rect: CGRect, command: Bool) -> Bool {
        if command { return true }
        if isKey { return !VolumeLine.edgeWins(at: p, clipRect: rect) }
        if case .clip(_, let zone) = geometry.hitTest(p, in: timeline), zone != .body { return false }
        return true
    }

    private mutating func beginBand(_ kind: BandDrag.Kind, clip: Clip, name: String,
                                    key: (LineKeyRef, Bool)?) -> [TimelineAction] {
        var out: [TimelineAction] = []
        if lineStepOpen { out.append(.endGesture); lineStepOpen = false }   // a lost release: close its step first
        if selection != [clip.id] {
            selection = [clip.id]
            interaction.setSelection([clip.id])
            out.append(.select(clips: [clip.id], captions: []))
        }
        if let (ref, extend) = key { out.append(.lineKeyClick(ref, extend: extend)) }
        gesture = .band(BandDrag(kind: kind, last: clip, original: clip, name: name))
        return out
    }

    // MARK: Drag and release

    mutating func bandDragged(_ d: BandDrag, to p: CGPoint) -> [TimelineAction] {
        var d = d
        let c: Clip
        switch d.kind {
        case .volume(var g): c = g.update(to: p); d.kind = .volume(g)
        case .opacity(var g): c = g.update(to: p); d.kind = .opacity(g)
        case .fade(let h, let original, let startX, let len, let rect):
            c = VolumeLine.clip(original, dragging: h, from: len, dx: p.x - startX, clipRect: rect,
                                frameDuration: timeline.frameDuration, defaultCurve: DefaultFadeCurve.current())
        }
        guard c != d.last else { gesture = .band(d); return [] }
        d.last = c
        gesture = .band(d)
        _ = try? timeline.replaceClip(c)               // the preview; the session applies the same clip
        let continues = lineStepOpen
        lineStepOpen = true
        return [.replaceClip(c, undoName: d.name, continues: continues)]
    }

    /// Esc during a band drag: the clip goes back to what it was before the drag, which drops the drag's undo step (the
    /// session's coalesced step returns to its start). The panel's preview reverts in `cancelGesture`.
    mutating func cancelBandDrag() -> [TimelineAction] {
        guard case .band(let d) = gesture, lineStepOpen else { return [] }
        lineStepOpen = false
        return [.replaceClip(d.original, undoName: d.name, continues: true), .endGesture]
    }

    mutating func bandUp(_ d: BandDrag, at p: CGPoint) -> [TimelineAction] {
        var out = bandDragged(d, to: p)
        if lineStepOpen { out.append(.endGesture); lineStepOpen = false }
        return out
    }
}

extension VolumeLine.Hit {
    var isKey: Bool { keyID != nil }
    var keyID: UUID? { if case .key(let id) = self { id } else { nil } }
}

extension OpacityLine.Hit {
    var isKey: Bool { keyID != nil }
    var keyID: UUID? { if case .key(let id) = self { id } else { nil } }
}
