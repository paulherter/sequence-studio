import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor final class UndoNameBox { var names: [String] = [] }

@MainActor @Suite struct ProjectPanelUndoNameTests {
    private func media(_ n: String) -> MediaRef {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        return MediaRef(name: n, path: "/nonexistent/\(n)", fingerprint: MediaFingerprint(size: 1),
                        duration: Time(10, 1), info: MediaInfo(duration: Time(10, 1), video: v))
    }

    @Test func moveAndDeleteNamesAreSpecific() {
        let box = UndoNameBox()
        let m = ProjectPanelModel(project: Project(name: "P"), onEdit: { box.names.append($1) })
        let a = m.newBin()!
        let b = m.newBin()!
        box.names.removeAll()
        #expect(m.move([.bin(b)], to: a))
        #expect(box.names == ["Move to Folder"])
        #expect(m.delete([.bin(a)]).changed)
        #expect(box.names.last == "Delete Folder")
    }

    @Test func deleteNameCountsItems() {
        let id = Bin.ID()
        #expect(ProjectPanelModel.deleteName(for: [.bin(id)]) == "Delete Folder")
        #expect(ProjectPanelModel.deleteName(for: [.bin(id), .bin(Bin.ID())]) == "Delete Items")
        #expect(ProjectPanelModel.deleteName(for: [.bin(id), .media(MediaRef.ID())]) == "Delete Items")
    }

    @Test func hoverMarksGoThroughTheEditHandlerAsMarkInAndOut() {
        var p = Project(name: "P")
        let r = media("a")
        p.media.append(r)
        let box = UndoNameBox()
        let m = ProjectPanelModel(project: p, onEdit: { box.names.append($1) })
        #expect(m.markFromHover(isIn: true, media: r.id, time: Time(1, 1)))
        #expect(m.markFromHover(isIn: false, media: r.id, time: Time(3, 1)))
        #expect(box.names == ["Mark In", "Mark Out"])
        #expect(m.project.sourceMarks[r.id]?.markIn == Time(1, 1))
    }
}

@Suite struct CommandMenuKeysTests {
    @Test func bindingsBecomeKeyEquivalents() {
        let cmdI = CommandMenuKeys.equivalent(for: KeyBinding(.char("i"), [.command]))
        #expect(cmdI?.key == "i" && cmdI?.modifiers == .command)
        #expect(CommandMenuKeys.equivalent(for: KeyBinding(.delete))?.key == "\u{8}")
        #expect(CommandMenuKeys.equivalent(for: KeyBinding(.left)) == nil)
    }

    @MainActor @Test func projectMenuCommandsHaveKeysInTheDefaultMap() {
        for c in [EditorCommand.importMedia, .newBin, .newSequence, .find, .insert, .overwrite, .deleteProjectItems] {
            let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
            CommandMenuKeys.apply(c, to: item, map: .premiereDefault)
            #expect(!item.keyEquivalent.isEmpty, "\(c)")
        }
    }

    @MainActor @Test func emptyTextCoversEveryCase() {
        #expect(LibraryPanelView.emptyText(offline: true, presetMode: false, favorites: false, hasFolders: true).title == "Folder is offline")
        #expect(LibraryPanelView.emptyText(offline: false, presetMode: false, favorites: false, hasFolders: false).title == "No library folders")
        #expect(LibraryPanelView.emptyText(offline: false, presetMode: true, favorites: false, hasFolders: true).title == "No presets")
    }
}
