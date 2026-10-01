import AppKit
import SQCore

public enum VolumeEditPhase: Sendable { case began, changed, ended }

/// State of one rubber band drag (kept in `TimelineView.volumeDrag`).
struct VolumeDrag {
    var gesture: VolumeLineGesture
    var track: Track.ID
    var last: Clip
}

/// State of one fade handle drag (kept in `TimelineView.fadeDrag`).
struct FadeDrag {
    var handle: FadeHandle
    var original: Clip
    var startX: CGFloat
    var startLength: Time
    var rect: CGRect
    var last: Clip
}

/// Mouse handling of the volume rubber band on audio clips. Selection tool only, rows that are tall enough.
extension TimelineView {
    /// Level in dB at seconds since the clip start for the waveform: Volume line plus Audio Gain.
    static func volumeDB(of clip: Clip) -> @Sendable (Double) -> Double {
        let c = clip
        return { sec in
            // `sec` counts source seconds from the clip's source start: map through speed and direction.
            let t = c.timelineTime(forSource: c.source.start + Time(Int64((sec * 1_000_000).rounded()), 1_000_000))
            return AudioGain.db(fromLinear: c.volume(at: t))
        }
    }

    /// The audio clip, its track and its drawn rectangle under a view point, when the rubber band applies there.
    private func volumeTarget(at p: CGPoint) -> (clip: Clip, track: Track.ID, rect: CGRect)? {
        guard toolState.tool == .selection,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == .audio, VolumeLine.isAvailable(rowHeight: row.height),
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        // A key sits on the clip edge half outside: look a few points beyond the clip as well.
        guard let clip = track.clips.first(where: { geometry.x(for: $0.timeline.start) - 6 <= p.x && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        return (clip, track.id, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height))
    }

    /// Clip and key under a view point, for the context menu ("Delete Keyframe").
    public func volumeKey(at p: CGPoint) -> (clip: Clip.ID, key: UUID)? {
        guard let t = volumeTarget(at: p),
              case .key(let id)? = VolumeLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry) else { return nil }
        return (t.clip.id, id)
    }

    /// Fade handles (head and tail squares on the clip) come before the line: they sit at the top, away from it.
    private func beginFadeDrag(at p: CGPoint) -> Bool {
        guard let t = volumeTarget(at: p), t.rect.contains(CGPoint(x: p.x, y: t.rect.midY)),
              let h = VolumeLine.fadeHandle(clip: t.clip, clipRect: t.rect, at: p) else { return false }
        onPointerDown?()
        let len = h == .head ? t.clip.audioFadeIn : t.clip.audioFadeOut
        fadeDrag = FadeDrag(handle: h, original: t.clip, startX: p.x, startLength: len, rect: t.rect, last: t.clip)
        if selection != [t.clip.id] { onSelectionChange?([t.clip.id], []) }
        onVolumeEdit?(t.clip, .began)
        NSCursor.resizeLeftRight.set()
        return true
    }

    private func updateFadeDrag(to p: CGPoint) -> Bool {
        guard var d = fadeDrag else { return false }
        let c = VolumeLine.clip(d.original, dragging: d.handle, from: d.startLength, dx: p.x - d.startX, clipRect: d.rect,
                                frameDuration: timeline.frameDuration)
        guard c != d.last else { return true }
        d.last = c
        fadeDrag = d
        previewClip(c)
        onVolumeEdit?(c, .changed)
        return true
    }

    func beginVolumeDrag(at p: CGPoint, event: NSEvent) -> Bool {
        if beginFadeDrag(at: p) { return true }
        guard let t = volumeTarget(at: p),
              let hit = VolumeLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry) else { return false }
        let cmd = event.modifierFlags.contains(.command)
        if case .key = hit, !cmd, VolumeLine.edgeWins(at: p, clipRect: t.rect) { return false }   // trimming wins at the edges
        if case .line = hit {
            // The edges belong to trimming; Cmd-click is explicit enough to take them.
            if !cmd, case .clip(_, let zone) = geometry.hitTest(p, in: timeline), zone != .body { return false }
        }
        onPointerDown?()
        let g = VolumeLineGesture(clip: t.clip, hit: hit, start: p, clipRect: t.rect, geometry: geometry, addKey: cmd)
        volumeDrag = VolumeDrag(gesture: g, track: t.track, last: t.clip)
        if selection != [t.clip.id] { onSelectionChange?([t.clip.id], []) }
        onVolumeEdit?(t.clip, .began)
        NSCursor.resizeUpDown.set()
        return true
    }

    func updateVolumeDrag(to p: CGPoint) -> Bool {
        if fadeDrag != nil { return updateFadeDrag(to: p) }
        guard var d = volumeDrag else { return false }
        let c = d.gesture.update(to: p)
        guard c != d.last else { return true }
        d.last = c
        volumeDrag = d
        previewClip(c)
        onVolumeEdit?(c, .changed)
        return true
    }

    func endVolumeDrag(at p: CGPoint) -> Bool {
        if let f = fadeDrag {
            _ = updateFadeDrag(to: p)
            onVolumeEdit?(fadeDrag?.last ?? f.last, .ended)
            fadeDrag = nil
            NSCursor.arrow.set()
            return true
        }
        guard volumeDrag != nil else { return false }
        _ = updateVolumeDrag(to: p)
        if let d = volumeDrag { onVolumeEdit?(d.last, .ended) }
        volumeDrag = nil
        NSCursor.arrow.set()
        return true
    }

    /// Shows the edited clip at once; the host applies the same edit to the session.
    private func previewClip(_ c: Clip) {
        var t = timeline
        guard (try? t.replaceClip(c)) != nil else { return }
        setTimeline(t)
    }
}
