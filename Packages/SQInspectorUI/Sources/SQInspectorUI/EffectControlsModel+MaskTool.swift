import Foundation
import SQCore

/// The Mask tool on the Program monitor (Magic / Pen / Ellipse / Rectangle) and how a mask is used: cutting the picture
/// (Opacity) and/or as the input of picture effects.
extension EffectControlsModel {
    /// The Magic mask clicks add to: the one selected in Effect Controls, else the clip's only Magic mask.
    public var activeMagicMaskID: ClipMask.ID? {
        guard let c = clip else { return nil }
        let magic = c.masks.filter { $0.source == .magic }
        if case .mask(let id)? = selectedSection, magic.contains(where: { $0.id == id }) { return id }
        return magic.count == 1 ? magic[0].id : nil
    }

    /// A click of the Mask tool at frame fraction `p` (0...1, origin top left). Magic: picks the object there (adds to the
    /// active Magic mask, `subtract` = Option removes); Pen: a corner point on the active path mask; Ellipse / Rectangle:
    /// a new shape centered there. `newMask` (Shift) starts a new mask. Selects the mask; nil = nothing changed.
    /// A Magic click on another frame than the pick's corrects the pick from there on (`magicClickEdit`).
    @discardableResult
    public func maskToolClick(_ mode: MaskToolMode, at p: Vec2, subtract: Bool, newMask: Bool) -> ClipMask.ID? {
        guard var c = workingClip, playheadInClip else { return nil }
        let id: ClipMask.ID?
        let name: String
        switch mode {
        case .magic:
            return magicClickEdit(at: p, subtract: subtract, newMask: newMask).map { applyMagicClick($0) }
        case .pen:
            id = c.penClick(newMask ? nil : activeMaskID, at: p, atLocal: localPlayhead)
            name = "Add Mask Point"
        case .ellipse:
            id = c.addShapeMask(.ellipse, at: p); name = "Add Mask"
        case .rectangle:
            id = c.addShapeMask(.rectangle, at: p); name = "Add Mask"
        }
        guard let id else { return nil }
        commit(c, name)
        selectedSection = .mask(id)
        return id
    }

    /// What a Magic click changes, not applied yet: a host that has to store a matte for it first applies it only when
    /// that worked, so the project never holds a point without a matte.
    public struct MagicClickEdit {
        let clip: Clip
        public let mask: ClipMask.ID
        let name: String
        /// The mask's points and matte cache key after the click.
        public var points: [MagicPoint] { clip.mask(mask)?.magic?.points ?? [] }
        public let key: String?
    }

    /// A Magic click at frame fraction `p` on the playhead's frame, nil = it changes nothing. Its point is stored at the
    /// clip's source time of that frame (rational); on another frame than the pick's it is a correction.
    public func magicClickEdit(at p: Vec2, subtract: Bool, newMask: Bool) -> MagicClickEdit? {
        guard var c = workingClip, playheadInClip else { return nil }
        let local = min(localPlayhead.snapped(to: frameDuration), max(c.duration - frameDuration, .zero))
        let target = newMask ? nil : activeMagicMaskID
        let here = c.sourceInstant(atLocal: local)
        let anchor = target.flatMap { c.mask($0)?.magic?.anchorTime }
        let picks = anchor == nil || anchor == here
        guard let id = c.magicClick(target, at: p, subtract: subtract, sourceTime: here) else { return nil }
        return MagicClickEdit(clip: c, mask: id,
                              name: subtract ? "Remove from Magic Mask" : (picks ? "Magic Mask Pick" : "Add to Magic Mask"),
                              key: c.mask(id).flatMap { Self.magicCacheKey($0, in: c) })
    }

    /// Applies a Magic click (one undo step) and selects its mask.
    @discardableResult
    public func applyMagicClick(_ e: MagicClickEdit) -> ClipMask.ID {
        commit(e.clip, e.name)
        selectedSection = .mask(e.mask)
        return e.mask
    }

    /// Ellipse / Rectangle drawn by dragging with the Mask tool (`MaskShapeDrag`): one undo step on release; selects it.
    @discardableResult
    public func addDrawnMask(_ kind: MaskShapeKind, path: MaskPath) -> ClipMask.ID? {
        guard var c = workingClip, playheadInClip else { return nil }
        let id = c.addShapeMask(kind, path: path)
        commit(c, "Add Mask")
        selectedSection = .mask(id)
        return id
    }

    /// Selects a mask (its Effect Controls row; the monitor shows its handles). No edit.
    public func selectMask(_ id: ClipMask.ID) {
        guard clip?.mask(id) != nil, selectedSection != .mask(id) else { return }
        clearSelection()
        selectedSection = .mask(id)
    }

    /// Cache key of a Magic mask's mattes (`MagicMatteStore`): changes with every click of the pick. Holds the followed
    /// objects as they are (for a Face / Skin mask made by Anonymize: the whole person).
    public func magicCacheKey(_ id: ClipMask.ID) -> String? {
        guard let c = clip, let m = c.mask(id), m.source == .magic, let sel = m.magic, !sel.points.isEmpty else { return nil }
        return sel.cacheKey(media: c.media)
    }

    /// Cache key of the narrowed mattes a Face / Skin mask made by Anonymize draws; nil for every other mask.
    public func magicPartKey(_ id: ClipMask.ID) -> String? {
        guard let c = clip, let m = c.mask(id), m.source == .magic, let sel = m.magic, !sel.points.isEmpty else { return nil }
        return sel.partKey(media: c.media)
    }

    /// Whether a Magic click on the playhead's frame corrects mask `id` (a frame other than its pick's) rather than picking.
    public func magicClickCorrects(_ id: ClipMask.ID) -> Bool {
        guard let c = clip, playheadInClip, let anchor = c.mask(id)?.magic?.anchorTime else { return false }
        let local = min(localPlayhead.snapped(to: frameDuration), max(c.duration - frameDuration, .zero))
        return c.sourceInstant(atLocal: local) != anchor
    }

    /// Track Forward / Backward of a Magic mask: source seconds from the playhead's frame to the clip's last (first) frame.
    public func magicTrackRange(_ id: ClipMask.ID, forward: Bool) -> (from: Double, to: Double)? {
        guard let c = clip, c.mask(id)?.source == .magic, playheadInClip else { return nil }
        let last = max(c.duration - frameDuration, .zero)
        let local = min(localPlayhead.snapped(to: frameDuration), last)
        func s(_ t: Time) -> Double { let x = c.sourceInstant(atLocal: t); return Double(x.value) / Double(max(x.timescale, 1)) }
        return (s(local), s(forward ? last : .zero))
    }

    /// Whether the mask cuts the clip's picture (Opacity); off = it only limits the effects that use it.
    public func setMask(_ id: ClipMask.ID, usedByOpacity on: Bool) {
        guard var c = workingClip, let m = c.mask(id), m.usedByOpacity != on else { return }
        c.setMask(id, usedByOpacity: on)
        commit(c, "Mask Cuts Picture")
    }

    /// Adds or removes the mask as an input of a picture effect.
    public func setMask(_ id: ClipMask.ID, input on: Bool, ofEffect effectID: ClipEffect.ID) {
        guard var c = workingClip else { return }
        let before = c.effects.first { $0.id == effectID }?.maskInput
        c.setMask(id, input: on, ofEffect: effectID)
        guard c.effects.first(where: { $0.id == effectID })?.maskInput != before else { return }
        commit(c, on ? "Use Mask in Effect" : "Stop Using Mask in Effect")
    }

    /// The clip's effects that can take a mask input, with whether they use mask `id` (the "Use in" menu).
    public func maskInputChoices(_ id: ClipMask.ID) -> [(effect: ClipEffect.ID, title: String, on: Bool)] {
        guard let c = clip else { return [] }
        return c.effects.filter { c.takesMaskInput($0) }.map { ($0.id, EffectCatalog.title(for: $0.kind), $0.maskInput.contains(id)) }
    }
}
