import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// FB-B: an effect or preset dragged onto Effect Controls is accepted; transitions and media are not.
@MainActor @Suite struct EffectControlsDropTests {
    @Test func acceptsEffectsAndPresetsButNotMedia() {
        let pb = NSPasteboard(name: NSPasteboard.Name("sq.test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(ClipEffect.gaussianBlurKind, forType: .sequenceEffectID)
        #expect(EffectControlsView.dropPayload(from: pb) == .effects([ClipEffect.gaussianBlurKind]))
        let preset = UUID()
        pb.clearContents()
        pb.setString(preset.uuidString, forType: .sequencePresetID)
        #expect(EffectControlsView.dropPayload(from: pb) == .preset(preset))
        // a dragged folder: several effects, transitions among them are dropped
        pb.clearContents()
        pb.setString(EffectFolderOutline.encodeDrag([ClipEffect.gaussianBlurKind, "transition.quickFade", ClipEffect.glowKind]), forType: .sequenceEffectID)
        #expect(EffectControlsView.dropPayload(from: pb) == .effects([ClipEffect.gaussianBlurKind, ClipEffect.glowKind]))
        pb.clearContents()
        pb.setString("whatever", forType: .sequenceMediaIDs)
        #expect(EffectControlsView.dropPayload(from: pb) == nil)
    }
}
