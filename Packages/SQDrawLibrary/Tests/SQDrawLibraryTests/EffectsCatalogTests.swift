import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQDrawLibrary

@Suite struct EffectsCatalogTests {
    @Test func catalogListsEffectsAudioAndTransitions() {
        let ids = Set(EffectsCatalog.offered(hiding: false).map(\.id))
        #expect(ids.contains(ClipEffect.gaussianBlurKind))
        #expect(ids.contains(ClipEffect.audioCompressorKind))
        #expect(ids.contains(EffectDragPayloadProbe.crossDissolveID))
    }

    @Test func searchFindsOtherNames() {
        let rows = EffectsCatalog.rows(matching: "steady")
        #expect(rows.contains { $0.id == ClipEffect.stabilizeKind })
        #expect(rows.first?.isHeader == true)
    }

    @Test func presetEntriesSkipKeystonesAndUsePresetIDs() {
        let id = UUID()
        let effect = PresetItem(id: id, kind: .effect, name: "Warm", payload: Data(), payloadVersion: 1)
        let keystone = PresetItem(kind: .keystone, name: "K", payload: Data(), payloadVersion: 1)
        let entries = EffectsCatalog.presetEntries([effect, keystone])
        #expect(entries.map(\.id) == ["preset.\(id.uuidString)"])
        #expect(entries.first?.category == EffectFolderOutline.presetsFolder)
    }

    @Test func folderOutlineOpensSearchHits() {
        let rows = EffectFolderOutline.rows(entries: EffectsCatalog.catalog, store: EffectFolderStore(), expanded: [], query: "blur")
        #expect(rows.contains { $0.payload == ClipEffect.gaussianBlurKind })
    }
}

/// The transition id the Effects panel uses for the dissolve (`EffectDragPayload`).
enum EffectDragPayloadProbe {
    static var crossDissolveID: String { EffectsCatalog.transitionEntries.first { $0.title.lowercased().contains("dissolve") }?.id ?? "" }
}
