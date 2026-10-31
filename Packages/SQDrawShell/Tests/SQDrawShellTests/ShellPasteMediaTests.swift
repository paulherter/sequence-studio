import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

/// Paste with files or an image on the system clipboard: the host reports what the clipboard holds, the shell derives the
/// Paste row and runs the import like the Mac `pasteMedia`.
@MainActor
@Suite struct ShellPasteMediaTests {
    func host() -> ShellHost { ShellMainMenuWalkTests.host(.premiereDefault).0 }

    @Test func pasteIsOffWithoutAClipboardReader() {
        let h = host()
        h.focus = .project
        #expect(!h.menuEnabled(.paste))
    }

    @Test func filesOnTheClipboardEnablePasteInProjectAndTimelineOnly() {
        let h = host()
        h.mediaClipboard = { PasteMedia.Content(fileURLs: [URL(fileURLWithPath: "/a.mov")]) }
        h.focus = .project
        #expect(h.menuEnabled(.paste))
        h.focus = .timeline
        #expect(h.menuEnabled(.paste))
        h.focus = .effectControls
        #expect(!h.menuEnabled(.paste))
    }

    @Test func anImageEnablesPasteAndAnEmptyClipboardDoesNot() {
        let h = host()
        h.focus = .project
        h.mediaClipboard = { PasteMedia.Content(imageData: Data([1])) }
        #expect(h.menuEnabled(.paste))
        h.mediaClipboard = { PasteMedia.Content() }
        #expect(!h.menuEnabled(.paste))
    }

    @Test func ownClipDataKeepsPriorityOverTheClipboard() throws {
        let (h, clip) = ShellMainMenuWalkTests.host(.premiereDefault)
        h.mediaClipboard = { PasteMedia.Content(fileURLs: [URL(fileURLWithPath: "/a.mov")]) }
        h.session.select(clips: [clip.id], captions: [])
        #expect(h.session.copySelection())
        h.focus = .timeline
        #expect(h.currentFacts().canPasteMedia == false)
        #expect(h.menuEnabled(.paste))                      // the own clipboard pastes
    }

    @Test func pastedImageFileLandsInTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try PasteMedia.writeImage(Data([0x89, 0x50]), into: dir)
        #expect(url.lastPathComponent.hasPrefix("Pasted Image "))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aSavedProjectPastesImagesIntoTheScratchFolderAnUnsavedOneIntoSupport() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sq-scratch-\(UUID().uuidString)", isDirectory: true)
        let l = StorageLocations(scratchFolder: scratch)
        #expect(ShellHost.pastedImageFolder(saved: true, locations: l).path == scratch.appendingPathComponent("Pasted Images").path)
        #expect(ShellHost.pastedImageFolder(saved: false, locations: l).path.hasSuffix("Sequence Studio/Pasted Images"))
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func revealOfSeveralFilesUsesTheListHookOrFallsBackToOneByOne() {
        let h = host()
        let a = URL(fileURLWithPath: "/a.mov"), b = URL(fileURLWithPath: "/b.mov")
        var single: [URL] = [], list: [[URL]] = []
        h.revealFile = { single.append($0) }
        h.reveal([a, b])
        #expect(single == [a, b])
        h.revealFiles = { list.append($0) }
        h.reveal([a, b])
        #expect(list == [[a, b]] && single.count == 2)
    }

    @Test func theHostHearsWhenFollowedExportsEnd() {
        let h = host()
        var heard = 0
        h.onExportsFinished = { done, failed in if done.isEmpty && failed.isEmpty { heard += 1 } }
        h.finishExports([])
        #expect(heard == 1 && h.exportProgress == nil)
    }
}
