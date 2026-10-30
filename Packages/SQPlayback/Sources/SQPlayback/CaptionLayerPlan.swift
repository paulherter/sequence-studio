import Foundation
import SQCore
import SQText

/// One caption layer of a Program frame: the text ref to draw, where its box sits, the clip time to animate it at and an
/// extra opacity (a caption handing over fades out under the next one).
public struct CaptionLayerRequest: Sendable, Hashable {
    public var ref: GeneratorRef
    /// Box center relative to the canvas center (sequence px, y down): the layer's base position (`CaptionPreview.position`).
    public var position: Vec2
    public var localTime: Time
    public var duration: Time
    public var opacity: Double
}

/// The caption layers of the visible caption tracks at one time, bottom first: per slot the caption before it while it
/// hands over (plain, then its lit words), the plain caption, then its lit word. The Mac `RenderLoop.captionNodes`
/// draws the same layers (with its raster cache and look-ahead around them); Windows draws these on the portable raster.
/// shortcut: RenderLoop keeps its own copy of this loop (it interleaves its cache checks); move it onto this plan when
/// RenderLoop is touched next.
public enum CaptionLayerPlan {
    /// `units`: the animatable units of a ref (for the hand-over's entrance coverage); `forward`: the playhead's direction.
    public static func layers(_ timeline: Timeline, slots: [CaptionSlot], at t: Time, library: CaptionPresetLibrary,
                              forward: Bool = true, units: (GeneratorRef) -> TextUnits?) -> [CaptionLayerRequest] {
        let canvas = timeline.format.layoutFormat
        var out: [CaptionLayerRequest] = []
        for s in slots {
            let karaoke = timeline.captionTrack(s.track)?.karaoke
            guard let plan = try? CaptionPreview.plan(for: s.item, karaoke: karaoke, canvas: canvas, at: t, library: library,
                                                      held: s.held, forward: forward) else { continue }
            var local = t - s.item.range.start
            if let tail = s.tail, let entering = CaptionPreview.animations(for: s.item, library: library) {
                let d = CaptionHandover.draw(previous: CaptionPreview.animations(for: tail, library: library), entering: entering,
                                             naturalClipTime: local, frameDuration: timeline.format.frameDuration) { units(plan.plain) }
                local = d.clipTime
                if d.tailOpacity > 0, let tp = try? CaptionPreview.plan(for: tail, karaoke: karaoke, canvas: canvas, at: t,
                                                                       library: library, held: true) {
                    let at = CaptionPreview.position(for: tail, canvas: canvas, library: library)
                    for ref in [tp.plain, tp.lit].compactMap({ $0 }) {
                        out.append(CaptionLayerRequest(ref: ref, position: at, localTime: s.tailDuration, duration: s.tailDuration,
                                                       opacity: d.tailOpacity))
                    }
                }
            }
            let at = CaptionPreview.position(for: s.item, canvas: canvas, library: library)
            for ref in [plan.plain, plan.lit].compactMap({ $0 }) {
                out.append(CaptionLayerRequest(ref: ref, position: at, localTime: local, duration: s.duration, opacity: 1))
            }
        }
        return out
    }
}
