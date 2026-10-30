import Foundation
import SQCore
import SQUIKit

// Portable (Windows builds it too): Edit Curve on the Keystones panel (Mac) and the Keystones card (draw list).

/// The curve popover's source for one keystone's own curve: reads it (or the first segment's ease when it has none) and
/// writes it back to the Library at the end of a handle drag or on a chip click.
@MainActor
public final class KeystoneEaseSource: EaseCurveSource {
    public let model: KeystonesPanelModel
    public let id: UUID
    private var inGesture = false
    private var pending: EaseShape?

    public init(model: KeystonesPanelModel, id: UUID) { self.model = model; self.id = id }

    private var keystone: Keystone? { model.keystones.first { $0.id == id } }

    public var easeReading: EaseReading {
        if let p = pending { return .common(p) }
        guard let k = keystone else { return .empty }
        if let e = k.easing { return .common(EaseShape(interpolation: e.interpolation, out: e.outHandle, in: e.inHandle)) }
        return Self.firstSegment(k).map { .common($0) } ?? .empty
    }

    static func firstSegment(_ k: Keystone) -> EaseShape? {
        func shape<V>(_ t: KeyframeTrack<V>?) -> EaseShape? {
            guard let t, t.keys.count >= 2 else { return nil }
            return EaseShape(interpolation: t.keys[0].interpolation, out: t.keys[0].outHandle, in: t.keys[1].inHandle)
        }
        return shape(k.scale) ?? shape(k.position) ?? shape(k.rotation) ?? shape(k.opacity)
    }

    public func applyEaseShape(_ shape: EaseShape) {
        if inGesture { pending = shape; return }
        save(shape)
    }

    private func save(_ shape: EaseShape) {
        model.setEasing(EasingCurve(name: "Custom", interpolation: shape.interpolation, outHandle: shape.out, inHandle: shape.in), for: id)
    }

    public func beginGesture() { inGesture = true }
    public func endGesture() {
        inGesture = false
        if let p = pending { pending = nil; save(p) }
    }

    public var sessionEasingCurves: [EasingCurve] { [] }
    public func observeEaseInputs() { _ = model.presets }
    public var emptyEaseHint: String { "Select a keystone" }
}
