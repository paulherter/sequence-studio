import Foundation

/// Controls shows one item (layer) of a graphics clip through the same rows as a clip: the item as a plain text or shape
/// clip with the graphic's timing. Keyframes of an item live in Controls only (DECISIONS: one system); the Graphics
/// panel edits values at the playhead.
extension Clip {
    /// Item `layerID` of this graphics clip as a plain clip under the graphics clip's own id (so the shown clip, its
    /// timing and its twirl state stay the same). nil when this is no graphics clip or has no such item.
    public func graphicsItemProjection(_ layerID: UUID) -> Clip? {
        guard isGraphics, let layer = graphics?.layer(layerID) else { return nil }
        var c = graphicsLayerClip(layer)
        c.id = id
        c.media = media
        c.link = nil
        return c
    }

    /// This graphics clip with the item `layerID` taking Motion, Opacity, effects and blend mode from `edited` (a clip
    /// made by `graphicsItemProjection`; also a text item's text). A locked or missing item, or another clip, leaves the graphic as it is.
    public func applyingItemProjection(_ edited: Clip, layer layerID: UUID) -> Clip {
        guard isGraphics, var doc = graphics, let i = doc.index(of: layerID), !doc.layers[i].isLocked else { return self }
        doc.layers[i].animation = edited.animation
        doc.layers[i].effects = edited.effects
        doc.layers[i].blendMode = edited.blendMode
        // Text edits of the shown item (the text generator's payload) belong to the item's content.
        if case .text = doc.layers[i].content, let g = edited.generator, g.kind == GeneratorRef.text {
            doc.layers[i].content = .text(ref: g)
        }
        var c = self
        c.graphics = doc
        return c
    }
}

extension GraphicsDocument {
    /// Entries of the Controls item picker, front-most item first (the order of the Graphics panel list).
    public var itemPickerEntries: [(id: UUID, name: String)] {
        layers.reversed().map { ($0.id, $0.name) }
    }

    /// The item Controls shows for a layer selection: the one selected item, nil (the whole graphic) for none, several
    /// or an item the document no longer has.
    public func shownItem(selection: Set<UUID>) -> UUID? {
        guard selection.count == 1, let id = selection.first, layer(id) != nil else { return nil }
        return id
    }
}
