import Foundation
import SQLibrary
import SQText
import Testing
@testable import SQInspectorUI

@Suite struct TextTemplateTilesTests {
    private func preset(_ kind: PresetKind, _ name: String) -> PresetItem {
        PresetItem(kind: kind, name: name, payload: Data("{}".utf8), payloadVersion: 1)
    }

    @Test func ownTemplatesComeFirstAndOnlyTextLikeKindsAreListed() {
        let own = preset(.titleBlock, "My Intro")
        let tiles = TextTemplateTile.tiles(presets: [preset(.effect, "Blur"), own, preset(.easing, "Ease")], builtIns: TextTemplateCatalog.all)
        #expect(tiles.first?.name == "My Intro")
        #expect(tiles.first?.source == .user(own.id, .titleBlock))
        #expect(tiles.count == 1 + TextTemplateCatalog.all.count)
        #expect(!tiles.contains { $0.name == "Blur" || $0.name == "Ease" })
    }

    @Test func searchMatchesNamesIgnoringCase() {
        let tiles = TextTemplateTile.tiles(presets: [preset(.titleBlock, "Hook Title"), preset(.titleBlock, "Outro")], builtIns: [])
        #expect(TextTemplateTile.filter(tiles, query: " hook ").map(\.name) == ["Hook Title"])
        #expect(TextTemplateTile.filter(tiles, query: "").count == 2)
        #expect(TextTemplateTile.filter(tiles, query: "zzz").isEmpty)
    }

    @Test func tileIDsAreUniquePerSource() {
        let tiles = TextTemplateTile.tiles(presets: [preset(.titleBlock, "A"), preset(.titleBlock, "A")], builtIns: TextTemplateCatalog.all)
        #expect(Set(tiles.map(\.id)).count == tiles.count)
    }
}
