import AppKit
import SQCore

/// Dropping an effect or preset from the Effects panel / Library onto Effect Controls adds it to the clip shown there
/// (Premiere accepts the drop here as well as on the timeline clip). Transitions are not effects: refused.
extension EffectControlsView {
    /// What a drag carries for this panel; nil for anything else (media, transitions).
    enum DropPayload: Equatable { case effects([String]), preset(UUID), keystone(Keystone) }

    static func dropPayload(from pb: NSPasteboard) -> DropPayload? {
        if let s = pb.string(forType: .sequencePresetID), let id = UUID(uuidString: s) { return .preset(id) }
        if let k = KeystoneDrag.read(from: pb) { return .keystone(k) }
        // One effect, or several when a folder was dragged; transitions are not effects.
        if let s = pb.string(forType: .sequenceEffectID) {
            let ids = EffectDragPayload.decodeDrag(s).filter { EffectDragPayload.transitionKind(forID: $0) == nil }
            if !ids.isEmpty { return .effects(ids) }
        }
        return nil
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model.clip != nil && Self.dropPayload(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard model.clip != nil, let payload = Self.dropPayload(from: sender.draggingPasteboard) else { return false }
        switch payload {
        case .effects(let kinds): for kind in kinds { onDropEffect?(kind) }
        case .preset(let id): onDropPreset?(id)
        case .keystone(let k): onDropKeystone?(k)
        }
        return true
    }
}
