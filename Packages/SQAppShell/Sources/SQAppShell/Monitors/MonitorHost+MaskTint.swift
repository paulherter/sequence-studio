import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQInspectorUI

/// Mask Tint on the shared Program monitor (the Mac `EditorPanels+MaskTint.swift`): the evaluated Magic mattes of the
/// shown clip, tinted yellow over the layer, so a tracked mask is visible without leaving the Mask tool. On by default
/// (the Mac `sq.showMaskTint` key); Program monitor menu > Mask Tint. The platform's segmenter reads the stored mattes
/// (`AppMagicMasks.maskTint`); the picture goes to image slot 1, which the Slip two-up only uses while the overlay is
/// not drawn. Subject and Picture mattes only exist inside the render pipeline, so they get no tint (as on the Mac).
extension MonitorHost {
    public static let maskTintKey = "sq.showMaskTint"
    /// The image slot of the tint (shared with `SlipTwoUpHost.slot`: the two-up replaces the picture and its overlay).
    public static let maskTintSlot = SlipTwoUpHost.slot

    /// Default on: the key only exists once the user turned it off.
    public var showsMaskTint: Bool {
        get { maskTintDefaults.object(forKey: Self.maskTintKey) as? Bool ?? true }
        set { maskTintDefaults.set(newValue, forKey: Self.maskTintKey) }
    }

    /// Per frame (`updateMaskTint`): the matte of every enabled Magic mask of the shown clip at the playhead's source
    /// frame, while the Mask tool is on or a mask is selected in Effect Controls; nothing while playing.
    /// The Mac draws the active mask's pick instead of its tint in Magic mode; the shared overlay draws no pick yet
    /// (`MacMagicMasks`), so the tint covers it too.
    func syncMaskTint(isPlaying: Bool) {
        let o = panel.overlay
        var maskSelected = false
        if case .mask? = effects?.selectedSection { maskSelected = true }
        guard showsMaskTint, !isPlaying, let magic, let fx = effects, let c = fx.clip, c.id == overlayTarget?.clip,
              fx.playheadInClip, o.maskTool != nil || maskSelected, !hidesTransformBox else {
            maskTint = nil
            o.maskTintSlot = nil
            return
        }
        let fd = fx.frameDuration
        let local = min(fx.localPlayhead.snapped(to: fd), max(c.duration - fd, .zero))
        let t = c.shownSourceTime(atLocal: local, frameDuration: fd)      // the picture's frame, not the instant
        let pts = Double(t.value) / Double(max(t.timescale, 1))
        let masks = c.masks.filter { $0.enabled && $0.source == .magic }.map(\.id)
        let answer = masks.isEmpty && !magic.hasHover ? MaskTintPicture() : magic.maskTint(masks: masks, pts: pts)
        // A tint still being read keeps the previous one on screen (no flicker while scrubbing).
        if answer.waiting && answer.image == nil && maskTint != nil { return }
        maskTint = answer.image.map { (Self.maskTintSlot, $0.0, 2_000_000 + $0.generation) }
        o.maskTintSlot = maskTint == nil ? nil : Self.maskTintSlot
    }
}
