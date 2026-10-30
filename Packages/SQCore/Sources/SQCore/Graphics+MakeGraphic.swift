import Foundation

// Make Graphic (G9): a text / shape clip becomes a graphics clip with one layer.

extension Clip {
    /// A text or shape generator clip (can become a graphic).
    public var isTextOrShape: Bool { generator?.kind == GeneratorRef.text || generator?.shapeKind != nil }

    /// The clip is rendered over a shutter (Motion shutter open or keyed, a Motion Blur effect or a transform-stage effect).
    var hasMotionBlur: Bool {
        effects.contains { $0.enabled && ($0.kind == ClipEffect.motionBlurKind || movesClip($0)) }
            || motionEnabled && animation.isShutterOpenOrKeyed
    }
}

extension Project {
    /// Why `clipID` cannot become a graphic without changing its picture or behavior; nil when it can. Hints are shown to
    /// the user. Refused: format variants (their conform and per-effect overrides only reach text / clip-level effects),
    /// motion blur (graphic layers are not sampled over the shutter) and a keyed Shape effect (keys on layer effects do not
    /// follow trims and animation zones yet).
    public func makeGraphicBlocker(clipID: Clip.ID) -> String? {
        for t in timelines {
            if let c = t.tracks.lazy.compactMap({ $0.clips.first { $0.id == clipID } }).first { return t.makeGraphicBlocker(c) }
        }
        return "Select a text or shape clip."
    }

    /// True when `clipID` is a text or shape clip that can become a graphic (`makeGraphicBlocker` is nil).
    public func canConvertToGraphics(clipID: Clip.ID) -> Bool { makeGraphicBlocker(clipID: clipID) == nil }

    /// Turns a text or shape clip into a graphics clip with one layer at identity, so evaluation draws the same picture:
    /// the text payload is copied unchanged; a shape's kind and Shape effect move to the layer. The clip keeps its Motion,
    /// other effects, masks, blend mode, zones and markers (they now apply to the graphic as a whole). One mutation = one
    /// undo step. Throws `.clipNotFound` for an unknown clip or one that is not text or shape, `.trackLocked` on a locked track.
    @discardableResult
    public mutating func convertToGraphics(clipID: Clip.ID) throws -> GraphicsLayer {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                guard var c = timelines[ti].tracks[tr].clips.first(where: { $0.id == clipID }) else { continue }
                guard let ref = c.generator, c.isTextOrShape else { throw EditError.clipNotFound }
                if timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
                guard makeGraphicBlocker(clipID: clipID) == nil else { throw EditError.notConvertible }
                let layer: GraphicsLayer
                if let kind = ref.shapeKind {
                    var effects: [ClipEffect] = []
                    if let i = c.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) {
                        effects = [c.effects.remove(at: i)]
                    }
                    layer = GraphicsLayer(name: kind.title, content: .shape(kind: kind), effects: effects)
                } else {
                    layer = GraphicsLayer.text(ref, name: "Text")
                }
                c.generator = GeneratorRef.graphicsClip
                c.graphics = GraphicsDocument(layers: [layer])
                timelines[ti].tracks[tr].replace(c)
                return layer
            }
        }
        throw EditError.clipNotFound
    }
}

extension Timeline {
    /// `Project.makeGraphicBlocker` for clip `c` of this sequence.
    public func makeGraphicBlocker(_ c: Clip) -> String? {
        guard c.isTextOrShape else { return "Only text and shape clips can become graphics." }
        if !c.variantOverrides.isEmpty || (c.generator?.kind == GeneratorRef.text && !variants.isEmpty) {
            return "Remove format variants first."
        }
        if c.hasMotionBlur { return "Turn off motion blur first." }
        if let e = c.effects.first(where: { $0.kind == ClipEffect.shapeEffectKind }),
           e.parameters.values.contains(where: \.isAnimated) || e.colors.values.contains(where: \.isAnimated) {
            return "Remove the keys of the shape first."
        }
        return nil
    }
}
