import AppKit
import SQCore

extension ProjectItemKind {
    /// Type-default colors (picture first, sound second for video with audio). The panel itself resolves through
    /// `Project.clipLabels(of:)`, which also honors user labels; both come from `LabelColor`, as do the timeline clips.
    public var defaultLabels: [LabelColor] {
        switch self {
        case .video: [.videoDefault]
        case .audio: [.audioDefault]
        case .videoAudio: [.videoDefault, .audioDefault]
        case .image: [.imageDefault]
        case .bin: [.binDefault]
        case .sequence: [.sequenceDefault]
        case .nestedSequence: [.nestedDefault]
        case .text: [.textDefault]
        case .generator: [.generatorDefault]
        }
    }
}

extension ProjectPanelModel {
    /// Colors of an item: same `LabelColor` the timeline clip of it draws in.
    public func tints(of ref: BinItemRef) -> [LabelColor] { project.clipLabels(of: ref) }
}

extension ProjectPanelModel {
    /// Label whose clip fill the item's row / tile label plate wears (list row, icon-view label area). Nil = no plate:
    /// folders keep their folder-colored icon on the plain row, offline items stay plain with red text.
    public func plateLabel(of ref: BinItemRef) -> LabelColor? {
        if case .bin = ref { return nil }
        if case .media(let id) = ref, isOffline(id) { return nil }
        return tints(of: ref).first
    }
}

// `LabelColor.fill` / `onFill` live in SQTimelineUI (LabelColor+ClipFill.swift), next to `ClipStyle`.

/// Small type chip on a thumbnail: filled rounded rect, split into two halves for video with audio.
@MainActor
final class ProjectTypeChip: NSView {
    var tints: [LabelColor] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        guard !tints.isEmpty else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let w = bounds.width / CGFloat(tints.count)
        for (i, t) in tints.enumerated() {
            t.fill.setFill()
            NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.OnPicture.clipBadgeEdge.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
