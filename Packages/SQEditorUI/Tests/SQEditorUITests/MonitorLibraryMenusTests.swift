import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
@Suite struct MonitorLibraryMenusTests {
    private func titles(_ rows: [SQMenuItem]) -> [String] { rows.map { $0.kind == .separator ? "-" : $0.title } }
    @MainActor final class Log { var lib: [LibraryMenus.Action] = []; var mon: [MonitorAction] = []; var ids: [UUID?] = [] }

    @Test func libraryFolder() {
        let log = Log()
        let rows = LibraryMenus.folderItems { log.lib.append($0) }
        #expect(titles(rows) == ["Rescan", "-", "Remove Folder"])
        rows[2].action?()
        #expect(log.lib == [.removeFolder])
    }

    @Test func libraryFileItems() {
        let rows = LibraryMenus.itemItems(.init(hasAudio: true, canWhoosh: false)) { _ in }
        #expect(titles(rows) == ["Toggle Favorite", "Whoosh at Selected Cuts", "Add to SFX Folder", "Reveal in Finder"])
        #expect(rows.map(\.isEnabled) == [true, false, true, true])
        let none = LibraryMenus.itemItems(.init()) { _ in }
        #expect(none.map(\.isEnabled) == [true, false, false, true])
    }

    @Test func libraryPresetItems() {
        let effect = LibraryMenus.itemItems(.init(showsPresets: true, presetIsEffect: true, hasPreset: true, relativeDefault: true)) { _ in }
        #expect(titles(effect) == ["Insert at Playhead", "Apply to Selected Clips", "Apply Absolute (Replace Values)",
                                   "Apply Relative (Add to Clip)", "Default Apply: Relative (switch to Absolute)",
                                   "Export…", "Import Presets…", "Export as Pack…", "Import Pack…", "-", "Delete"])
        #expect(effect.map(\.isEnabled) == [false, true, true, true, true, true, true, true, true, false, true])
        let empty = LibraryMenus.itemItems(.init(showsPresets: true)) { _ in }
        #expect(empty.last?.isEnabled == false)
        #expect(empty[4].title == "Default Apply: Absolute (switch to Relative)")
    }

    @Test func libraryPresetOrganizeRows() {
        let log = Log()
        let o = LibraryMenus.Organize(isFavorite: true, category: .social, defaultCategory: .titles, tags: ["bold", "mine"])
        let rows = LibraryMenus.itemItems(.init(showsPresets: true, hasPreset: true, organize: o)) { log.lib.append($0) }
        #expect(titles(rows).prefix(4) == ["Remove from Favorites", "Category", "Tags", "-"])
        rows[0].action?()
        let cats = rows[1].submenu ?? []
        #expect(cats.first { $0.isChecked }?.title == "Social")
        cats.first { $0.title == "Titles" }?.action?()       // default shelf stores nil
        cats.first { $0.title == "Effects" }?.action?()
        let tags = rows[2].submenu ?? []
        #expect(tags.contains { $0.title == "mine" && $0.isChecked })    // a file's own tag stays listed
        tags.first { $0.title == "bold" }?.action?()
        #expect(log.lib == [.toggleFavoritePreset, .setCategory(nil), .setCategory(.effects), .toggleTag("bold")])
    }

    @Test func monitorOptionRows() {
        let log = Log()
        let rows = MonitorMenus.optionItems(
            mode: .program, available: MonitorAction.allCases, isLooping: true, safeMargins: false, zoom: .fit, quality: .half,
            title: { "\($0)" }, shortcut: { _ in "" },
            perform: { log.mon.append($0) }, setZoom: { _ in }, setQuality: { _ in })
        #expect(titles(rows).prefix(7) == ["Loop Playback", "Play In to Out", "Safe Margins", "-", "Zoom", "Playback Quality", "-"])
        #expect(rows[0].isChecked && !rows[2].isChecked)
        #expect(rows[4].submenu?.first { $0.isChecked }?.title == MonitorZoom.fit.title)
        #expect(rows[5].submenu?.first { $0.isChecked }?.title == MonitorQuality.half.title)
        rows[0].action?()
        #expect(log.mon == [.loop])
        let source = MonitorMenus.optionItems(
            mode: .source, available: [], isLooping: false, safeMargins: true, zoom: .fit, quality: .full,
            title: { "\($0)" }, shortcut: { _ in "" }, perform: { _ in }, setZoom: { _ in }, setQuality: { _ in })
        #expect(titles(source) == ["Loop Playback", "Play In to Out", "-", "Zoom", "Playback Quality", "-"])
    }

    @Test func sourcePopupRows() {
        let a = MonitorPanelModel.SourceItem(id: UUID(), name: "A.mov"), b = MonitorPanelModel.SourceItem(id: UUID(), name: "B.mov")
        #expect(MonitorMenus.sourceTitle([], current: nil) == "No clip")
        #expect(MonitorMenus.sourceTitle([a, b], current: b.id) == "B.mov")
        let rows = MonitorMenus.sourceItems([a, b], current: b.id, pick: { _ in }, close: {}, closeAll: {})
        #expect(titles(rows) == ["A.mov", "B.mov", "-", "Close", "Close All"])
        #expect(rows.map(\.isChecked) == [false, true, false, false, false])
        #expect(MonitorMenus.sourceItems([], current: nil, pick: { _ in }, close: {}, closeAll: {}).isEmpty)
    }

    @Test func formatPopupRows() {
        let v = MonitorPanelModel.FormatItem(id: UUID(), name: "Square")
        let log = Log()
        let rows = MonitorMenus.formatItems(base: "", [v], current: nil, pick: { log.ids.append($0) }, add: { _ in }, remove: { _ in })
        #expect(titles(rows) == ["Sequence", "Square", "-", "Add Format", "Remove Format"])
        #expect(rows[0].isChecked && !rows[1].isChecked && !rows[4].isEnabled)
        #expect(rows[3].submenu?.count == SequenceConform.aspectPresets.count)
        rows[1].action?()
        #expect(log.ids == [v.id])
        let shown = MonitorMenus.formatItems(base: "Main", [v], current: v.id, pick: { _ in }, add: { _ in }, remove: { _ in })
        #expect(shown[1].isChecked && shown[4].isEnabled)
        #expect(MonitorMenus.formatTitle(base: "Main", [v], current: v.id) == "Square")
        #expect(MonitorMenus.formatTitle(base: "", [v], current: nil) == "Sequence")
        // Board: the popup in the Program tab strip names the sequence ("Main") while its own format is shown.
        #expect(MonitorMenus.formatTitle(base: "9:16", [v], current: nil, sequenceName: "Main") == "Main")
        #expect(MonitorMenus.formatTitle(base: "9:16", [v], current: v.id, sequenceName: "Main") == "Square")
    }
}
