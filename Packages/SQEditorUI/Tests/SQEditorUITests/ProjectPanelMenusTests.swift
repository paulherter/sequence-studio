import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
@Suite struct ProjectPanelMenusTests {
    private func titles(_ rows: [SQMenuItem]) -> [String] { rows.map { $0.kind == .separator ? "-" : $0.title } }
    private func build(_ c: ProjectPanelMenus.Context, _ log: Box? = nil) -> [SQMenuItem] {
        ProjectPanelMenus.items(c, shortcut: { _ in "" }) { log?.actions.append($0) }
    }
    @MainActor final class Box { var actions: [ProjectPanelMenus.Action] = [] }

    @Test func emptyAreaListView() {
        let rows = build(.init())
        #expect(titles(rows) == ["New Folder", "New Sequence…", "New Color Matte…", "-", "Import…", "-", "Find…"])
    }

    @Test func emptyAreaIconViewHasUpAndHoverScrub() {
        let rows = build(.init(isIconView: true, canGoUp: false, hoverScrub: true))
        #expect(titles(rows).suffix(2) == ["Up One Level", "Hover Scrub"])
        #expect(!rows[rows.count - 2].isEnabled)
        #expect(rows.last?.isChecked == true)
    }

    @Test func mediaItemMenu() {
        let id = UUID()
        let log = Box()
        let rows = build(.init(media: [id], targetCount: 1, allMediaOnline: true, singleMediaHasPoster: true,
                               firstLabel: .iris, hasNonBinTarget: true), log)
        #expect(titles(rows) == ["Open in Source", "-", "Insert", "Overwrite", "New Sequence From Clip", "Make Subclip", "-", "Rename",
                                 "Delete Poster Frame", "-", "Label", "Select Label Group", "-", "Reveal in Finder",
                                 "Edit Original", "Replace Media…", "-", "Delete"])
        rows[0].action?()
        rows.last?.action?()
        #expect(log.actions == [.openInSource, .delete])
        // Make Subclip needs an In or Out on the item; Edit Original needs the file online.
        #expect(rows.first { $0.title == "Make Subclip" }?.isEnabled == false)
        #expect(rows.first { $0.title == "Edit Original" }?.isEnabled == true)
    }

    @Test func fillReelRowOnlyWithSlots() {
        let id = UUID()
        let log = Box()
        #expect(!titles(build(.init(media: [id], targetCount: 1, allMediaOnline: true))).contains("Fill Reel…"))
        var c = ProjectPanelMenus.Context(media: [id], targetCount: 1, allMediaOnline: true)
        c.canFillReel = true
        let rows = build(c, log)
        rows.first { $0.title == "Fill Reel…" }?.action?()
        #expect(log.actions == [.fillReel])
        c.allMediaOnline = false
        #expect(build(c).first { $0.title == "Fill Reel…" }?.isEnabled == false)
    }

    @Test func makeSubclipEnabledWithMarks() {
        let log = Box()
        let rows = build(.init(media: [UUID()], targetCount: 1, allMediaOnline: true, singleMediaHasMarks: true), log)
        let row = rows.first { $0.title == "Make Subclip" }
        #expect(row?.isEnabled == true)
        row?.action?()
        rows.first { $0.title == "Edit Original" }?.action?()
        #expect(log.actions == [.makeSubclip, .editOriginal])
    }

    @Test func offlineMediaDisablesPlacingAndOffersReconnect() {
        let rows = build(.init(media: [UUID()], targetCount: 1, allMediaOnline: false, singleMediaOffline: true, hasNonBinTarget: true))
        #expect(rows.first { $0.title == "Insert" }?.isEnabled == false)
        #expect(rows.contains { $0.title == "Reconnect Media…" })
        #expect(rows.contains { $0.title == "Locate…" })
        let online = build(.init(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true))
        #expect(!online.contains { $0.title == "Locate…" })
    }

    @Test func clearUsedMediaOnlyWhenUsedAndBeforeDelete() {
        let log = Box()
        var c = ProjectPanelMenus.Context(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true)
        #expect(!build(c).contains { $0.title == "Clear Used Media" })
        c.anyMediaUsed = true
        let rows = build(c, log)
        #expect(titles(rows).suffix(2) == ["Clear Used Media", "Delete"])
        rows.first { $0.title == "Clear Used Media" }?.action?()
        #expect(log.actions == [.clearUsedMedia])
    }

    @Test func extractAudioNeedsOneOnlineItemWithSound() {
        let log = Box()
        var c = ProjectPanelMenus.Context(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true)
        #expect(!build(c).contains { $0.title == "Extract Audio" })
        c.audioChannels = 2
        let rows = build(c, log)
        #expect(rows.first { $0.title == "Extract Audio" }?.isEnabled == true)
        rows.first { $0.title == "Extract Audio" }?.action?()
        #expect(log.actions == [.extractAudio])
        c.allMediaOnline = false
        #expect(build(c).first { $0.title == "Extract Audio" }?.isEnabled == false)
        var two = ProjectPanelMenus.Context(media: [UUID(), UUID()], targetCount: 2, allMediaOnline: true, hasNonBinTarget: true)
        two.audioChannels = 2
        #expect(!build(two).contains { $0.title == "Extract Audio" })
    }

    @Test func conformToConstantFrameRateShowsForVariableRateMediaOnly() {
        let log = Box()
        var c = ProjectPanelMenus.Context(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true)
        #expect(!build(c).contains { $0.title == "Conform to Constant Frame Rate" })
        c.canConformToCFR = true
        let rows = build(c, log)
        #expect(rows.first { $0.title == "Conform to Constant Frame Rate" }?.isEnabled == true)
        rows.first { $0.title == "Conform to Constant Frame Rate" }?.action?()
        #expect(log.actions == [.conformToConstantFrameRate])
        c.allMediaOnline = false
        #expect(build(c).first { $0.title == "Conform to Constant Frame Rate" }?.isEnabled == false)
    }

    @Test func binMenuHasNoLabelOrReveal() {
        let rows = build(.init(hasBin: true, targetCount: 1))
        #expect(titles(rows) == ["New Folder", "-", "Rename", "-", "Delete"])
    }

    @Test func sequenceMenu() {
        let rows = build(.init(hasSequence: true, targetCount: 2, hasNonBinTarget: true))
        #expect(rows[0].title == "Open in Timeline" && !rows[0].isEnabled)
        #expect(rows.first { $0.title == "Rename" }?.isEnabled == false)
    }

    @Test func labelSubmenuChecksSharedLabel() {
        let rows = build(.init(media: [UUID()], targetCount: 1, allMediaOnline: true, sharedLabel: .iris, firstLabel: .iris, hasNonBinTarget: true))
        let sub = rows.first { $0.title == "Label" }?.submenu ?? []
        #expect(sub.count == LabelColor.allCases.count + 2)
        #expect(titles(sub).first == "Default")
        let checked = sub.filter(\.isChecked).map(\.title)
        #expect(checked == [LabelColor.iris.displayName])
        #expect(sub.last?.icon != SQMenuIcon.none)
    }

    @Test func labelSubmenuRunsSetLabel() {
        let log = Box()
        let rows = build(.init(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true), log)
        let sub = rows.first { $0.title == "Label" }?.submenu ?? []
        sub[0].action?()
        sub[2].action?()
        #expect(log.actions == [.setLabel(nil), .setLabel(LabelColor.allCases[0])])
    }

    @Test func headerMenuToggleAndReset() {
        let log = Box()
        let rows = ProjectPanelMenus.headerItems(isVisible: { $0 == .duration }) { log.actions.append($0) }
        let cols = ProjectPanelModel.Column.allCases.filter { $0 != .name }
        #expect(titles(rows) == cols.map(\.title) + ["-", "Reset Columns"])
        #expect(rows.filter(\.isChecked).map(\.title) == [ProjectPanelModel.Column.duration.title])
        rows[0].action?()
        rows.last?.action?()
        #expect(log.actions == [.toggleColumn(cols[0]), .resetColumns])
    }
}
