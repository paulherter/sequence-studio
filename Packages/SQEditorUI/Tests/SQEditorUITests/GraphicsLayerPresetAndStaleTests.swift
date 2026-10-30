import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Layer effect presets (Graphics panel) and the panel's rebuild signature across selection / clip / undo changes.
@MainActor @Suite struct GraphicsLayerPresetAndStaleTests {
    private func rig() -> (EditorSession, GraphicsEditor) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                         tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        return (s, e)
    }

    // MARK: Effect presets

    @Test func presetRoundTripsLayerEffectsWithFreshIds() throws {
        let (s, e) = rig()
        e.addShape(.rectangle)
        let a = try #require(e.selectedLayer?.id)
        #expect(e.addEffect(ClipEffect.gaussianBlurKind) == .added)
        let preset = try #require(e.layerEffectPreset())
        #expect(preset.effects.count == 1 && preset.trackKind == .video)
        e.addShape(.ellipse)
        let b = try #require(e.selectedLayer?.id)
        let depth = s.undoDepth
        #expect(e.applyEffectPreset(preset, name: "Soft") == .added)
        #expect(s.undoDepth == depth + 1)
        let src = try #require(e.document?.layer(a)?.effects.first { $0.kind == ClipEffect.gaussianBlurKind })
        let dst = try #require(e.document?.layer(b)?.effects.first { $0.kind == ClipEffect.gaussianBlurKind })
        #expect(src.id != dst.id)
        #expect(src.parameters.mapValues(\.value) == dst.parameters.mapValues(\.value))
    }

    @Test func lockedLayerAndMissingSelectionRefusePresets() throws {
        let (s, e) = rig()
        e.addShape(.rectangle)
        e.addEffect(ClipEffect.gaussianBlurKind)
        let preset = try #require(e.layerEffectPreset())
        let id = try #require(e.selectedLayer?.id)
        e.setLocked(id, true)
        let depth = s.undoDepth
        #expect(e.applyEffectPreset(preset, name: "X") == .refused("The layer is locked."))
        #expect(s.undoDepth == depth)
        e.select([])
        #expect(e.applyEffectPreset(preset, name: "X") == .refused("Select a layer first."))
    }

    @Test func layerWithoutEffectsHasNoPreset() {
        let (_, e) = rig()
        e.addShape(.rectangle)
        #expect(e.layerEffectPreset() == nil)
    }

    @Test func audioOnlyPresetIsRefused() throws {
        let (_, e) = rig()
        e.addShape(.rectangle)
        let audio = try #require(AudioPresets.all.first)
        if case .refused = e.applyEffectPreset(audio.preset, name: "Voice") {} else { Issue.record("expected a refusal") }
    }

    // MARK: Stale panel state

    @Test func structureFollowsSelectionEffectsAndDrawMode() throws {
        let (_, e) = rig()
        e.addShape(.rectangle)
        let first = try #require(e.selectedLayer?.id)
        e.addShape(.ellipse)
        let second = try #require(e.selectedLayer?.id)
        let s2 = GraphicsPanelView.structure(e)
        e.select([first])
        #expect(GraphicsPanelView.structure(e) != s2)
        e.select([second])
        #expect(GraphicsPanelView.structure(e) == s2)
        e.addEffect(ClipEffect.gaussianBlurKind)
        let withFx = GraphicsPanelView.structure(e)
        #expect(withFx != s2)
        let fx = try #require(e.selectedLayer?.effects.first?.id)
        e.setEffectEnabled(fx, false)
        #expect(GraphicsPanelView.structure(e) != withFx)
        let before = GraphicsPanelView.structure(e)
        e.isDrawing = true
        #expect(GraphicsPanelView.structure(e) != before)
    }

    @Test func undoOfTheSelectedLayersCreationDropsItFromTheSelection() throws {
        let (s, e) = rig()
        e.addShape(.rectangle)
        #expect(e.selectedLayers.count == 1)
        _ = s.undo()
        e.sync()
        #expect(e.selectedLayers.isEmpty)
        #expect(e.selectedLayer == nil)
        // No layer selected: the signature carries the zone switch, never a stale layer id.
        #expect(GraphicsPanelView.structure(e).contains("#zones"))
    }

    @Test func anotherClipClearsLayersAndDrawMode() throws {
        let (_, e) = rig()
        e.addShape(.rectangle)
        e.isDrawing = true
        let one = GraphicsPanelView.structure(e)
        e.newGraphicsClip()
        e.sync()
        #expect(e.selectedLayers.isEmpty)
        #expect(!e.isDrawing)
        #expect(GraphicsPanelView.structure(e) != one)
    }

    @Test func deletingTheSelectionWhileDrawingKeepsASingleConsistentState() throws {
        let (_, e) = rig()
        e.addShape(.rectangle)
        e.isDrawing = true
        e.deleteSelected()
        e.sync()
        #expect(e.selectedLayers.isEmpty)
        #expect(e.document?.layers.isEmpty == true)
        #expect(GraphicsPanelView.structure(e).hasSuffix("#draw"))
    }
}
