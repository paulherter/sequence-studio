import Foundation
import SQCore
import SQText

/// Create tools and the Type tool: what a click or drag on the Program monitor does.
extension GraphicsEditor {
    /// The Graphic a new item goes into (`Timeline.graphicCreateTarget`), selected when it was found through the targeted
    /// track. With `convertingTextOrShape`, a selected old text or shape clip under the playhead becomes a Graphic first
    /// (`Project.convertToGraphics`, the "Make Graphic" conversion). False: there is none.
    @discardableResult
    public func adoptCreateTarget(convertingTextOrShape: Bool = false) -> Bool {
        guard let t = session.activeTimeline else { return false }
        if let target = t.graphicCreateTarget(selection: session.selection, at: session.playhead) {
            if session.singleSelectedClip?.id != target { session.select(clips: [target]) }
            sync()
            return clip?.id == target
        }
        if convertingTextOrShape, let c = session.singleSelectedClip, c.timeline.contains(session.playhead), session.makeGraphic() {
            sync()
            return clip?.id == c.id
        }
        return false
    }

    /// Create tool item: `make` builds the layer from the Graphic's Motion at the playhead and the canvas size. It goes into
    /// the Graphic that takes it (a selected old text or shape clip is converted first); one undo step ("Make Graphic" and the
    /// item fold into `name`). False: no Graphic takes it, the caller makes a new Graphic clip.
    @discardableResult
    public func addCreatedItem(named name: String, _ make: (GraphicsCanvasMapping, Vec2) -> GraphicsLayer?) -> Bool {
        let depth = session.undoDepth
        guard adoptCreateTarget(convertingTextOrShape: true), let map = mapping else {
            if session.undoDepth > depth { session.rewindUndo(toDepth: depth); sync() }
            return false
        }
        guard let layer = make(map, canvas) else {
            if session.undoDepth > depth { session.rewindUndo(toDepth: depth); sync() }
            return true   // a Graphic takes it, the gesture just gave nothing
        }
        add(layer, name: name)
        if session.undoDepth > depth + 1 { session.foldUndo(fromDepth: depth, name: name) }
        return true
    }

    /// What a Type tool click (no `box`) or drag (`box`, sequence px) at a point does.
    public enum TypeToolOutcome: Equatable {
        case editLayer(UUID)                       // over a text layer of the selected Graphic
        case addLayer(at: Vec2, box: TextBox?)     // empty canvas in the selected Graphic (canvas px; area text with a box)
        case editTextClip(Clip.ID)                 // over an old text clip
        case newGraphic(at: Vec2, box: TextBox?)   // empty canvas, no Graphic: a new Graphic with one text layer (box in sequence px)
    }

    /// The decision behind the Type tool at `point` (sequence px). A Graphic selected under the playhead takes the text;
    /// otherwise `textClipHit` (the old text clip under the point) / `hitIsPointText` decide. A drag over a text layer or
    /// point text edits it like a click; a drag over area text starts a new one.
    public func typeToolOutcome(at point: Vec2, box: TextBox?, textClipHit: Clip.ID?, hitIsPointText: Bool) -> TypeToolOutcome {
        if let c = clip, c.timeline.contains(session.playhead), let map = mapping {
            let p = map.canvasPoint(fromSequence: point)
            if let layer = textLayer(at: p) { return .editLayer(layer) }
            let canvasBox = box.map { b -> TextBox in
                let d = map.canvasDelta(fromSequence: Vec2(b.width, b.height))
                return TextBox(width: abs(d.x), height: abs(d.y))
            }
            return .addLayer(at: p, box: canvasBox)
        }
        if let hit = textClipHit, box == nil || hitIsPointText { return .editTextClip(hit) }
        return .newGraphic(at: point, box: box)
    }
}
