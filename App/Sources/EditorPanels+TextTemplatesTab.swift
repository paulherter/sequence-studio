import Foundation
import SQCore
import SQInspectorUI
import SQLibrary
import SQText

/// The Text panel's Templates tab: the Library's text and graphic templates, one click to place at the playhead.
extension EditorPanels {
    func wireTextTemplatesTab() {
        textView.templatesTab.onPick = { [weak self] tile in self?.placeTextTemplate(tile) }
        refreshTextTemplateTiles()
    }

    /// Re-reads the Library whenever its presets change (a template saved from the timeline shows up at once).
    private func refreshTextTemplateTiles() {
        textView.templatesTab.allTiles = TextTemplateTile.tiles(presets: libraryModel.presets, builtIns: TextTemplateCatalog.all)
        withObservationTracking { _ = libraryModel.presets } onChange: { [weak self] in
            Task { @MainActor in self?.refreshTextTemplateTiles() }
        }
    }

    private func placeTextTemplate(_ tile: TextTemplateTile) {
        if let status = TextTemplatePlacement.place(tile, presets: libraryModel.presets, session: session) { onStatus?(status) }
        libraryModel.recordPresetUse(tile.presetKey)
    }
}
