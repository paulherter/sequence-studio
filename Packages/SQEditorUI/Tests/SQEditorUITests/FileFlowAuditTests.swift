import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private func media(_ name: String, path: String) -> MediaRef {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    return MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                    info: MediaInfo(duration: Time(10, 1), video: v))
}

@MainActor @Suite struct FileFlowAuditTests {
    private func model(_ p: Project = Project(name: "P")) -> ProjectPanelModel {
        ProjectPanelModel(project: p, probe: { url in media(url.lastPathComponent, path: url.path) }, onEdit: { _, _ in })
    }

    @Test func importingKnownFilesSaysSo() async {
        var p = Project(name: "P")
        p.add(media("a.mov", path: "/x/a.mov"))
        let m = model(p)
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov")])
        #expect(m.alreadyInProject == ["a.mov"])
        #expect(ProjectPanelModel.alreadyText(m.alreadyInProject) == "“a.mov” is already in the project.")
        // The next import clears the note.
        await m.importFiles([URL(fileURLWithPath: "/x/b.mov")])
        #expect(m.alreadyInProject.isEmpty)
    }

    @Test func noticeTexts() {
        #expect(ProjectPanelModel.alreadyText(["a", "b"]) == "2 files are already in the project.")
        let names = (1...7).map { "f\($0).bin" }
        #expect(ProjectPanelModel.failureText(names) == "Could not read: f1.bin, f2.bin, f3.bin and 4 more.")
        #expect(ProjectPanelModel.failureText(["a.bin"]) == "Could not read: a.bin")
    }

    @Test func folderImportSkipsSidecars() {
        for n in ["C0001.THM", "C0001M01.XML", "notes.txt", "clip.xmp", "index.bim", "meta.json", ".DS_Store"] {
            #expect(ProjectPanelModel.isSidecar(URL(fileURLWithPath: "/card/\(n)")), "\(n)")
        }
        for n in ["C0001.MP4", "a.mov", "b.wav", "c.png", "d.braw", "e.mxf", "f.LRV"] {
            #expect(!ProjectPanelModel.isSidecar(URL(fileURLWithPath: "/card/\(n)")), "\(n)")
        }
    }
}

@Suite struct SaveChangesPromptTests {
    @Test func boardOrderLeftToRight() {
        let m = SQDialogModel(buttons: SaveChangesPrompt.buttons)
        #expect(m.displayOrder.map { SaveChangesPrompt.buttons[$0].title } == ["Don’t Save", "Cancel", "Save"])
        #expect(m.returnIndex == 0)
        #expect(m.escapeIndex == 1)
    }

    @Test func responsesMap() {
        #expect(SaveChangesPrompt.choice(.first) == .save)
        #expect(SaveChangesPrompt.choice(.second) == .cancel)
        #expect(SaveChangesPrompt.choice(.third) == .dontSave)
        #expect(SaveChangesPrompt.choice(.dismissed) == .cancel)
    }

    @Test func outcomeKeepsProjectWhenSaveFails() {
        #expect(SaveChangesPrompt.outcome(.dontSave, saveSucceeded: nil) == .proceed)
        #expect(SaveChangesPrompt.outcome(.cancel, saveSucceeded: nil) == .stay)
        #expect(SaveChangesPrompt.outcome(.save, saveSucceeded: true) == .proceed)
        #expect(SaveChangesPrompt.outcome(.save, saveSucceeded: false) == .stay)
        #expect(SaveChangesPrompt.outcome(.save, saveSucceeded: nil) == .stay)
    }

    @Test func detailNamesThePlaceForNewProjects() {
        #expect(!SaveChangesPrompt.detail(hasFile: true).contains("never saved"))
        #expect(SaveChangesPrompt.detail(hasFile: false).contains("never saved"))
    }

    @Test func keysRouteToTheRightButtons() {
        let m = SQDialogModel(buttons: SaveChangesPrompt.buttons)
        func r(_ key: UInt16, _ cmd: Bool, _ ch: String?) -> SaveChangesPrompt.Choice? {
            SQModal.response(for: m, keyCode: key, command: cmd, otherModifiers: false, character: ch).map(SaveChangesPrompt.choice)
        }
        #expect(r(36, false, nil) == .save)
        #expect(r(53, false, nil) == .cancel)
        #expect(r(0, true, ".") == .cancel)
        #expect(r(2, true, "d") == .dontSave)
        #expect(r(1, true, "s") == .save)
    }
}

@Suite struct AutosaveLiveTests {
    @MainActor @Test func intervalChangeAppliesWithoutRestart() {
        let s = EditorSession()
        s.setAutosaveInterval(60)
        #expect(s.autosaveStore.policy.interval == 60)
        s.setAutosaveInterval(.nan)
        #expect(s.autosaveStore.policy.interval == 60)
        s.setAutosaveInterval(5)
        #expect(s.autosaveStore.policy.interval == 60)
    }
}

@MainActor @Suite struct SuggestedSequenceNameTests {
    @Test func skipsNamesInUse() {
        let s = EditorSession()
        let first = s.suggestedSequenceName
        s.addSequence(name: "Sequence 02")
        s.addSequence(name: "Sequence 03")
        let names = Set(s.project.timelines.map(\.name))
        #expect(!names.contains(s.suggestedSequenceName))
        #expect(first.hasPrefix("Sequence "))
    }
}
