import AppKit
import SQCore
import SQEditorSession
import SQUIKit

/// VoiceOver tree of the timeline: one group per track row, the track's clips as children. Built on demand from the model
/// and the laid-out rows (pure, `TimelineAccessibility.tracks`); the strings come from `SQAccessibilityText`.
public struct TimelineAccessibility {
    public struct ClipItem: Equatable {
        public var id: Clip.ID
        public var label: String
        /// In timeline view coordinates.
        public var frame: CGRect
        public var selected: Bool
    }

    public struct TrackItem: Equatable {
        public var id: Track.ID
        public var label: String
        public var frame: CGRect
        public var clips: [ClipItem]
    }

    /// - Parameters:
    ///   - position: formats a position on the sequence ("00:00:01:00").
    ///   - length: formats a duration.
    public static func tracks(timeline: Timeline, rows: [TrackRow], geometry: TimelineGeometry, viewWidth: CGFloat,
                              selection: Set<Clip.ID>, offline: Set<UUID> = [],
                              position: (Time) -> String, length: (Time) -> String) -> [TrackItem] {
        rows.compactMap { row in
            guard let track = timeline.track(row.track) else { return nil }
            let kind = track.kind == .video ? "Video" : "Audio"
            let label = SQAccessibilityText.track(kind: kind, label: row.label, clipCount: track.clips.count,
                                                  locked: track.isLocked, muted: track.kind == .audio && track.isMuted,
                                                  hidden: track.kind == .video && !track.isVisible)
            let clips = track.clips.map { c -> ClipItem in
                let x0 = geometry.x(for: c.start), x1 = geometry.x(for: c.start + c.duration)
                return ClipItem(id: c.id,
                                label: SQAccessibilityText.clip(name: c.name, start: position(c.start), length: length(c.duration),
                                                                offline: offline.contains(c.media)),
                                frame: CGRect(x: x0, y: row.y, width: max(x1 - x0, 1), height: row.height),
                                selected: selection.contains(c.id))
            }
            return TrackItem(id: track.id, label: label, frame: CGRect(x: 0, y: row.y, width: viewWidth, height: row.height),
                             clips: clips)
        }
    }
}

extension TimelineView {
    private func screenFrame(_ r: CGRect) -> CGRect {
        guard let window else { return r }
        return window.convertToScreen(convert(r, to: nil))
    }

    func accessibilityTrackItems() -> [TimelineAccessibility.TrackItem] {
        let fd = geometry.frameDuration
        var position = TimecodeFormat(frameDuration: fd)
        position.startFrame = timecodeStart.frameIndex(frameDuration: fd)
        position.framesOnly = timecodeFramesOnly
        var length = TimecodeFormat(frameDuration: fd)
        length.framesOnly = timecodeFramesOnly
        return TimelineAccessibility.tracks(
            timeline: timeline, rows: layoutRows(), geometry: geometry, viewWidth: bounds.width, selection: selection,
            offline: offlineMedia, position: { position.string(for: $0, frameDuration: fd) },
            length: { length.string(for: $0, frameDuration: fd) })
    }

    public override func isAccessibilityElement() -> Bool { false }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { SQAccessibilityText.timelineLabel }
    public override func accessibilityHelp() -> String? { SQAccessibilityText.timelineHelp }
    public override func accessibilityValue() -> Any? {
        let fd = geometry.frameDuration
        var f = TimecodeFormat(frameDuration: fd)
        f.startFrame = timecodeStart.frameIndex(frameDuration: fd)
        f.framesOnly = timecodeFramesOnly
        return SQAccessibilityText.timelinePlayhead(f.string(for: playhead, frameDuration: fd))
    }

    /// Tracks (with their clips as children) after the header, ruler and zoom bar subviews.
    public override func accessibilityChildren() -> [Any]? {
        var result: [Any] = super.accessibilityChildren() ?? []
        for t in accessibilityTrackItems() {
            let group = NSAccessibilityElement()
            group.setAccessibilityRole(.group)
            group.setAccessibilityLabel(t.label)
            group.setAccessibilityParent(self)
            group.setAccessibilityFrameInParentSpace(t.frame)
            group.setAccessibilityFrame(screenFrame(t.frame))
            let kids: [NSAccessibilityElement] = t.clips.map { c in
                let e = NSAccessibilityElement()
                e.setAccessibilityRole(.button)
                e.setAccessibilityLabel(c.label)
                e.setAccessibilityParent(group)
                e.setAccessibilityFrameInParentSpace(c.frame)
                e.setAccessibilityFrame(screenFrame(c.frame))
                e.setAccessibilitySelected(c.selected)
                return e
            }
            group.setAccessibilityChildren(kids)
            result.append(group)
        }
        return result
    }
}
