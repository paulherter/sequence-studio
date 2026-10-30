import Testing
@testable import SQUIKit

@Suite struct MarkerListCommandTests {
    @Test func windowMenuListsTheMarkerList() {
        #expect(EditorMenus.windowPanels.contains(.markerList))
        #expect(PanelID.dockable.contains(.markerList))
        #expect(EditorCommand.focusPanel(.markerList).title == "Show Marker List")
    }

    @Test func fileMenuHasTheMarkerCSVExport() {
        #expect(EditorMenus.file.commands.contains(.exportMarkersCSV))
        #expect(CommandSupport.isSupported(.exportMarkersCSV))
        #expect(EditorCommand.exportMarkersCSV.title == "Export Markers as CSV…")
    }

    @Test func viewMenuHasOneItemPerThumbnailMode() {
        let cmds = EditorMenus.view.commands
        for m in ThumbnailModeChoice.allCases {
            #expect(cmds.contains(.thumbnailMode(m)))
            #expect(CommandSupport.isSupported(.thumbnailMode(m)))
        }
    }

    @Test func thumbnailCommandIdsRoundTrip() {
        for m in ThumbnailModeChoice.allCases {
            let c = EditorCommand.thumbnailMode(m)
            #expect(c.id == "thumbnailMode.\(m.rawValue)")
            #expect(EditorCommand(id: c.id) == c)
        }
    }
}
