import Foundation
import SQCore
import SQText

/// Program monitor entry points of the selected graphic: text layers created and typed in place.
extension GraphicsEditor {
    /// A new text layer centered on canvas point `p`, selected, one undo step. Returns its ID. With `box` (canvas px) it is
    /// area text: the text wraps inside the box, left aligned.
    @discardableResult
    public func addText(at p: Vec2, string: String = "Text", box: TextBox? = nil) -> UUID? {
        var template = TextTemplate(name: "Text", text: string, style: CaptionPresetLibrary.builtIn.style(for: "title"))
        if let box { template.box = box; template.style.alignment = .left }
        guard let ref = try? TextGenerator.makeRef(template: template, animations: nil) else { return nil }
        var layer = GraphicsLayer.text(ref, name: string)
        var at = p
        if let r = layer.contentRect(atLocal: localTime, text: textMeasure) { at = Vec2(p.x - r.midX, p.y - r.midY) }
        layer.animation.position.set(at, atLocal: localTime)
        let above = selectedLayers.compactMap { document?.index(of: $0) }.max().flatMap { document?.layers[$0].id }
        var newID: UUID?
        guard edit("Add Text", { newID = $0.add(layer, above: above) }), let newID else { return nil }
        select([newID])
        return newID
    }

    /// Select Layer Above / Below. False when no graphic with layers is open; at the end of the stack the selection stays.
    @discardableResult
    public func stepLayerSelection(up: Bool) -> Bool {
        guard let doc = document, !doc.layers.isEmpty else { return false }
        if let id = doc.stepTarget(from: selectedLayers, up: up) { select([id]) }
        return true
    }

    /// Withdraws a layer that was created and left empty: every undo step above `depth` goes, no redo entry stays.
    public func discardNewLayer(rewindingTo depth: Int) {
        if session.undoDepth > depth { session.rewindUndo(toDepth: depth) }
        sync()
        select([])
    }

    /// True while a monitor text edit on `layer` of graphic `clip` still applies: same clip, that layer alone selected.
    public func isEditingValid(layer: UUID, clip id: Clip.ID) -> Bool {
        clip?.id == id && selectedLayers == [layer] && document?.layer(layer) != nil
    }

    /// The topmost text layer under canvas point `p` (nil when something else is on top or it is locked).
    public func textLayer(at p: Vec2) -> UUID? {
        shownDocument?.textLayer(at: p, atLocal: localTime, text: textMeasure)
    }

    /// Where the Program monitor's text field goes for layer `id`: its box as a text overlay target in sequence px
    /// (position = box center, scale and rotation as drawn through the graphic's Motion).
    public func textEditTarget(for id: UUID) -> OverlayTarget? {
        guard let c = clip, let l = shownDocument?.layer(id), case .text = l.content, let map = mapping else { return nil }
        // An empty text measures nothing: the field keeps the layer's anchor with a one-line box instead of vanishing
        // (the caret would otherwise fall back to the clip's canvas-sized group and jump to the top).
        let real = textMeasure
        let measure: GraphicsTextMeasure = { ref, t in
            if let r = real(ref, t), r.width > 0, r.height > 0 { return r }
            let line = (try? TextGenerator.decode(ref).0.style.size) ?? 48
            return GraphicsRect(minX: -1, minY: -line * 0.6, maxX: 1, maxY: line * 0.6)
        }
        guard let r = l.contentRect(atLocal: localTime, text: measure),
              let cs = l.corners(atLocal: localTime, text: measure), cs.count == 4, r.width > 0, r.height > 0 else { return nil }
        let s = cs.map(map.sequenceOffset(fromCanvas:))
        let centre = Vec2((s[0].x + s[2].x) / 2, (s[0].y + s[2].y) / 2)
        let e1 = s[1] - s[0], e2 = s[3] - s[0]
        let transform = ClipTransform(position: centre,
                                      scale: Vec2(hypot(e1.x, e1.y) / r.width, hypot(e2.x, e2.y) / r.height),
                                      rotation: atan2(e1.y, e1.x) * 180 / .pi)
        return OverlayTarget(clip: c.id, size: CGSize(width: r.width, height: r.height), isText: true, baseTransform: transform,
                             shift: .zero, positionTrack: KeyframeTrack<Vec2>())
    }

    /// A text layer of some graphics clip under the playhead, found without that clip being selected.
    public struct TextLayerHit: Equatable, Sendable {
        public var clip: Clip.ID
        public var layer: UUID
        /// Index of the clip's track in the timeline (a higher index lies above).
        public var trackIndex: Int
    }

    /// The topmost unlocked text layer under sequence point `p` over all visible graphics clips at the playhead
    /// (the monitor's click on existing text selects it, whichever graphic is selected). The last video track is the topmost.
    /// shortcut: layer Follow links are not resolved for clips other than the selected one, upgrade when Follow text is clicked often.
    public func textLayerHit(atSequence p: Vec2) -> TextLayerHit? {
        guard let tl = session.displayTimeline else { return nil }
        let frame = canvas
        for (index, track) in tl.tracks.enumerated().reversed() where track.kind == .video && track.isVisible {
            for c in track.clips.reversed() where c.isEnabled && c.isGraphics && c.timeline.contains(session.playhead) {
                guard let doc = c.graphics else { continue }
                let shown = session.displayedClip(c)
                let map = GraphicsCanvasMapping(transform: shown.renderTransform(at: session.playhead, frame: frame))
                let local = min(max(session.playhead - c.start, .zero), c.duration)
                let measure = Self.textMeasure(clipDuration: c.duration, format: tl.format)
                if let id = doc.textLayer(at: map.canvasPoint(fromSequence: p), atLocal: local, text: measure) {
                    return TextLayerHit(clip: c.id, layer: id, trackIndex: index)
                }
            }
        }
        return nil
    }
}
