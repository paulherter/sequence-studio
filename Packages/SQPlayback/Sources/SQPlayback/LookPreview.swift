import Foundation
import Synchronization
import SQCore
import SQText

/// A display-only override of how text is drawn in the Program monitor while the pointer rests on a Look tile.
/// It never touches the timeline, the project or the export: the render loop only swaps what it draws.
public enum LookPreview: Sendable, Equatable {
    /// The text `layer` inside `container` drawn from `to` instead of `from`. A text clip is its own layer
    /// (`container == layer`); a graphic text item is a layer of the graphics clip `container`.
    case text(container: Clip.ID, layer: UUID, from: GeneratorRef, to: GeneratorRef)
    /// Every caption drawn in `style`; `animation` and `karaoke` replace the captions' own when non-nil.
    case captions(style: TextStyle, animation: KeyframeTemplate?, karaoke: KaraokeStyle?)
}

/// The preview the render loop reads. One lock-guarded value; the text swap is a comparison, the caption library is
/// derived once per preview (never per frame).
final class LookPreviewState: Sendable {
    private struct Box { var preview: LookPreview?; var captions: CaptionPresetLibrary? }
    private let box = Mutex(Box())

    /// Returns whether the preview changed.
    func set(_ preview: LookPreview?) -> Bool {
        box.withLock { b in
            guard b.preview != preview else { return false }
            b.preview = preview; b.captions = nil
            return true
        }
    }

    /// The ref to draw for `ref` of the text in `container`.
    func text(_ ref: GeneratorRef, container: Clip.ID, layer: UUID) -> GeneratorRef {
        box.withLock { b in
            if case .text(let c, let l, let from, let to)? = b.preview, c == container, l == layer, from == ref { return to }
            return ref
        }
    }

    /// The highlight of a caption track: the preview's when it has one.
    func karaoke(_ own: KaraokeStyle?) -> KaraokeStyle? {
        box.withLock { b in
            if case .captions(_, _, let k?)? = b.preview { return k }
            return own
        }
    }

    /// `base` with every style (and animation) id resolving to the preview's; `base` itself without a caption preview.
    func captionLibrary(over base: CaptionPresetLibrary) -> CaptionPresetLibrary {
        box.withLock { b in
            guard case .captions(let style, let animation, _)? = b.preview else { return base }
            if let derived = b.captions { return derived }
            var lib = CaptionPresetLibrary(styles: base.styles.mapValues { _ in style },
                                           animations: animation.map { a in base.animations.mapValues { _ in a } } ?? base.animations,
                                           defaultStyleID: base.defaultStyleID, defaultAnimationID: base.defaultAnimationID)
            lib.position = base.position
            b.captions = lib
            return lib
        }
    }
}

extension RenderLoop {
    func setLookPreview(_ preview: LookPreview?) {
        if lookPreview.set(preview) { invalidate() }
    }
}

extension PlaybackEngine {
    /// Draws the text of the monitor as `preview` says until it is set to nil. Display only: no timeline rebuild, no
    /// undo step, no project change; the export is not affected. The frame is redrawn.
    /// Ignored while Export Frame renders (it must never bake a preview into the picture).
    public func setLookPreview(_ preview: LookPreview?) { loop.setLookPreview(isExportingFrame ? nil : preview) }
}
