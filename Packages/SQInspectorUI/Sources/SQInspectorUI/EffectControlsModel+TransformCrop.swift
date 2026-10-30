import Foundation
import SQCore

/// Transform's Crop rows (Left, Right, Top, Bottom, Softness). They are not a second crop: they edit the clip's first Crop
/// effect, whose own section is therefore not shown (a second Crop keeps its section). A clip without a Crop shows the rows
/// at 0 under a placeholder id (`pendingCropID`); the first edit that changes a value adds the Crop with that id, in the
/// same undo step. Multi-select maps the rows to each clip's first Crop and adds one where a clip has none.
extension EffectControlsModel {
    nonisolated static let transformCropKeys = [ClipEffect.cropLeftKey, ClipEffect.cropRightKey, ClipEffect.cropTopKey,
                                                ClipEffect.cropBottomKey, ClipEffect.cropSoftnessKey]

    /// Id the Crop of `clip` gets when Transform's Crop rows add it: fixed per clip, so the rows keep their identity
    /// (expanded state, focus) across the add.
    nonisolated static func pendingCropID(for clip: Clip.ID) -> ClipEffect.ID {
        var b = clip.uuid
        b.0 ^= 0x5C; b.5 ^= 0xC5; b.10 ^= 0x5C; b.15 ^= 0xC5
        return UUID(uuid: b)
    }

    /// The Crop Transform's rows edit: the clip's first Crop, or the placeholder id. nil for sound clips.
    nonisolated static func transformCropID(in c: Clip) -> ClipEffect.ID? {
        guard c.kind != .audio else { return nil }
        return c.effects.first { $0.kind == ClipEffect.cropKind }?.id ?? pendingCropID(for: c.id)
    }

    /// The Crop rows under Transform for the shown clip (empty for sound clips and when nothing is shown).
    public var transformCropProperties: [EffectProperty] {
        guard let c = clip, let id = Self.transformCropID(in: c) else { return [] }
        return Self.transformCropKeys.map { .fx(id, kind: ClipEffect.cropKind, key: $0) }
    }

    /// The rows of a section as the panel shows them: Transform carries the Crop rows.
    public func properties(of s: EffectSection) -> [EffectProperty] {
        s == .motion ? s.properties + transformCropProperties : s.properties
    }

    /// Every property row of the visible sections, in panel order.
    var panelProperties: [EffectProperty] { visibleSections.flatMap { properties(of: $0) } }

    /// True when `p` is a Crop row of `c` whose Crop is not on the clip yet.
    nonisolated static func isPendingCrop(_ p: EffectProperty, in c: Clip) -> Bool {
        guard case .fx(let id, let kind, _) = p, kind == ClipEffect.cropKind, id == pendingCropID(for: c.id) else { return false }
        return !c.effects.contains { $0.id == id }
    }

    /// `body` on a Crop row of `c` whose Crop is not there yet: the Crop is added (at the end, like an applied effect) only
    /// when `body` leaves it different from a fresh one, so a reset or a no-op adds nothing.
    nonisolated static func withPendingCrop(_ c: inout Clip, _ p: EffectProperty, _ body: (inout AnimatedProperty<Double>) -> Void) {
        guard case .fx(let id, _, let key) = p, var e = ClipEffect.make(kind: ClipEffect.cropKind) else { return }
        e = ClipEffect(id: id, kind: e.kind, parameters: e.parameters)
        let fresh = e
        var v = e.parameters[key] ?? AnimatedProperty(EffectCatalog.param(ClipEffect.cropKind, key)?.defaultValue ?? 0)
        body(&v)
        e.parameters[key] = v
        if e != fresh { c.effects.append(e) }
    }
}
