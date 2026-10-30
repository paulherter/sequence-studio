import AppKit
import SQUIKit

extension ZoomScrollBar {
    /// Bar for the Effect Controls keyframe area, driven by the model's viewport.
    static func keyframe(model: EffectControlsModel) -> ZoomScrollBar {
        let bar = ZoomScrollBar(accessibilityLabel: "Keyframe zoom")
        bar.isActive = { [unowned model] in model.clip != nil }
        bar.handles = { [unowned model] in model.viewport.handles(duration: model.durationSeconds) }
        bar.onFit = { [unowned model] in model.zoomToFit() }
        bar.onHandle = { [unowned model] lower, f in
            let v = model.viewport, d = model.durationSeconds, m = model.minViewportSpan
            guard d > 0 else { return }
            model.setViewport(lower ? v.settingLowerHandle(f, duration: d, minSpan: m) : v.settingUpperHandle(f, duration: d, minSpan: m))
        }
        bar.onPan = { [unowned model] start in
            let d = model.durationSeconds
            guard d > 0 else { return }
            model.setViewport(KeyframeViewport(start: start * d, span: model.viewport.span).clamped(duration: d, minSpan: model.minViewportSpan))
        }
        return bar
    }
}
