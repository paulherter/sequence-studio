import Foundation

// F7.11 Anonymize: where a cover sits among the clip's effects. A mask that must cover is tracked on the source frame and
// the renderer reads its matte in the clip's frame, never moved along by an earlier effect. So the effects that take such
// a mask (the covers) are pinned in front of every other picture effect, behind the Color effects. A list that has the
// wrong order anyway (hand-edited file, an insert that did not pin) is rendered safely: `Clip.effects(at:)` runs the
// cover on the whole frame.

extension ClipEffect {
    /// Picture kinds that leave every part of the picture where it was (color, grain, light, edges, blocks): one in front
    /// of a cover does not move the person out from under the matte. Every other picture kind counts as moving pixels, a
    /// new kind too until it is listed here.
    static let inPlaceKinds: Set<String> = [
        colorKind, invertKind, posterizeKind, tintKind, blackAndWhiteKind, brightnessContrastKind, vignetteKind, grainKind,
        noiseKind, sharpenKind, unsharpMaskKind, strobeKind, alphaAdjustKind, lightLeakKind, gradientKind, edgeFeatherKind, scanlinesKind, agedFilmKind,
        glowKind, outlineKind, longShadowKind, mosaicKind, halftoneKind, gaussianBlurKind,
        roundedCornersKind, cropKind, dropShadowKind, ultraKeyKind, lumaKeyKind, trackMaskKind,
    ]
}

extension Clip {
    /// A mask made by Anonymize: what it limits has to cover the person on every frame.
    var hasCoverMask: Bool { masks.contains { $0.source == .magic && $0.magic?.mustCover == true } }

    /// `e` takes a mask that must cover as input (on or off): it is a cover.
    public func isCover(_ e: ClipEffect) -> Bool {
        guard !e.maskInput.isEmpty else { return false }
        return masks.contains { $0.source == .magic && $0.magic?.mustCover == true && e.maskInput.contains($0.id) }
    }

    /// A mask that must cover is among `e`'s inputs but switched off: its person would be left open.
    func coverInputIsOff(_ e: ClipEffect) -> Bool {
        masks.contains { !$0.enabled && $0.source == .magic && $0.magic?.mustCover == true && e.maskInput.contains($0.id) }
    }

    /// `e` changes where things are in the picture the next effect reads, at clip-local `t`. Transform, Auto Reframe and
    /// the Standard Stabilizer's motion are stages after every pixel effect and do not count.
    func movesPixels(_ e: ClipEffect, atLocal t: Time) -> Bool {
        switch e.kind {
        case ClipEffect.transformKind: return hasLiveMaskInput(e)             // then a picture warp inside its masks
        case ClipEffect.stabilizeKind: return e.rollingShutterFilter(atLocal: t) != nil || e.stabilizeFillsEdges
        default: return !ClipEffect.inPlaceKinds.contains(e.kind) && !e.isAudio && e.imageFilter(atLocal: t) != nil
        }
    }

    /// Where a new cover goes: behind the Color effects (they stay first), in front of everything else.
    var coverInsertionIndex: Int { effects.prefix(while: \.isColor).count }

    /// Moves every cover in front of the other picture effects (behind the leading Color effects), keeping the order
    /// within both groups. True when the list changed.
    @discardableResult
    public mutating func pinCovers() -> Bool {
        guard hasCoverMask else { return false }
        let lead = coverInsertionIndex
        let rest = effects[lead...]
        let covers = rest.filter { !$0.isColor && isCover($0) }
        guard !covers.isEmpty else { return false }
        let sorted = Array(effects[..<lead]) + covers + rest.filter { $0.isColor || !isCover($0) }
        guard sorted.map(\.id) != effects.map(\.id) else { return false }
        effects = sorted
        return true
    }
}

extension Timeline {
    /// Matte keys of every mask that must cover on this timeline's clips (nested sequences: ask each): playback reads
    /// their files ahead, so a cover never waits on the disk.
    public var coverMatteKeys: Set<String> {
        var out: Set<String> = []
        for t in tracks {
            for c in t.clips {
                for m in c.masks where m.source == .magic {
                    if let sel = m.magic, sel.mustCover { out.formUnion(sel.matteKeys(media: c.media)) }
                }
            }
        }
        return out
    }
}
