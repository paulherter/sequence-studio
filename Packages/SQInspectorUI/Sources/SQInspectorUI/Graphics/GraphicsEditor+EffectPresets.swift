import Foundation
import SQCore

/// Effect presets of a graphics layer: the same `EffectPreset` payload the Library stores for clips, effects only
/// (no Motion). Keys stay clip-local as saved.
extension GraphicsEditor {
    /// The effects a preset of the selected layer would hold (generator-owned looks, e.g. the shape's own drop shadow
    /// row, stay out).
    public var presetEffects: [ClipEffect] {
        selectedLayer?.effects.filter { !EffectCatalog.isGeneratorOwned($0.kind) && !$0.isAudio } ?? []
    }

    /// A preset of the selected layer's effects; nil when the layer has none.
    public func layerEffectPreset() -> EffectPreset? {
        let fx = presetEffects
        guard !fx.isEmpty, let c = clip else { return nil }
        return EffectPreset(anchor: .start, referenceDuration: c.duration, effects: fx, frameSize: canvas)
    }

    /// Appends the preset's effects (fresh ids, also for every key) to `layer` (default the selected one) as one undo step.
    /// Kinds a layer refuses are skipped; the first refusal is returned when nothing was added. Motion values of the
    /// preset are ignored: layers keep their own transform.
    @discardableResult
    public func applyEffectPreset(_ preset: EffectPreset, name: String, to layer: UUID? = nil) -> EffectDrop {
        guard let id = layer ?? selectedLayer?.id, let target = document?.layer(id) else { return .refused("Select a layer first.") }
        if target.isLocked { return .refused("The layer is locked.") }
        var added: [ClipEffect] = [], refusal: String?
        for fx in preset.effects {
            if let why = Self.refusalForEffect(fx.kind) { refusal = refusal ?? why; continue }
            added.append(Self.freshCopy(fx.upgradingLegacyShadowColor()))
        }
        guard !added.isEmpty else { return .refused(refusal ?? "“\(name)” has no layer effects.") }
        edit("Apply Preset “\(name)”") { $0.update(id) { $0.effects += added } }
        return .added
    }

    private static func freshCopy(_ fx: ClipEffect) -> ClipEffect {
        func fresh<V>(_ p: AnimatedProperty<V>) -> AnimatedProperty<V> {
            var c = p
            c.track = KeyframeTrack(keys: p.track.keys.map { var k = $0; k.id = UUID(); return k })
            return c
        }
        var e = fx
        e.id = UUID()
        e.parameters = e.parameters.mapValues(fresh)
        e.colors = e.colors.mapValues(fresh)
        e.points = e.points.mapValues(fresh)
        return e
    }
}
