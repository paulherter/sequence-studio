import Foundation
import Testing
import SQCore
import SQEditorSession
import SQLibrary
@testable import SQDrawShell

@MainActor
@Suite(.serialized) struct ShellLibraryImportTests {
    let root: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-libimport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The synthetic preset file of the SQPremiereImport tests (shared, not copied).
    static var presetFixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../SQPremiereImport/Tests/SQPremiereImportTests/Fixtures/presets.prfpset.gz").standardized
    }

    func host(_ picker: FilePicker) -> ShellHost {
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        h.files = picker
        h.presetStore = try! PresetStore(applicationSupport: root.appendingPathComponent("presets"))
        return h
    }

    @Test func importLottiePlacesAClipFromThePickedFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":100,"h":100,"nm":"x","layers":[]}"#
        let file = root.appendingPathComponent("a.json")
        try Data(json.utf8).write(to: file)
        let picker = FilePicker(); picker.file = file
        let h = host(picker)
        await h.chooseAndImportLottie()
        #expect(h.session.lastError == nil)
        #expect(h.session.canUndo)                       // a clip was placed
        let bad = root.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: bad)
        picker.file = bad
        await h.chooseAndImportLottie()
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.dialog?.messageText.hasPrefix("Could not import") == true)
    }

    @Test func importPremierePresetsFillsTheStoreAndReloadsTheLibrary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let picker = FilePicker(); picker.file = Self.presetFixture
        let h = host(picker)
        var reloads = 0
        h.presetsChanged = { reloads += 1 }
        var status: [String] = []
        h.onStatus = { status.append($0) }
        await h.importPremierePresets(at: Self.presetFixture, showReport: false)
        #expect(reloads == 1)
        #expect(await h.presetStore.all().count > 0)
        #expect(status.last?.hasPrefix("Imported ") == true)
        await h.importPremierePresets(at: Self.presetFixture, showReport: false)      // again: all already there
        #expect(status.last?.contains("already in the library") == true)
    }

    @Test func aBrokenTemplateSaysWhy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.mogrt")
        try Data([1, 2, 3]).write(to: bad)
        let h = host(FilePicker())
        await h.importMotionGraphicsTemplates(at: [bad])
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.dialog?.messageText.hasPrefix("Could not import") == true)
        #expect(await h.presetStore.all().isEmpty)
    }

    @Test func cancellingTheChooserChangesNothing() async {
        let h = host(FilePicker())
        await h.chooseAndImportPresets()
        await h.chooseAndImportTemplate()
        #expect(h.dialog == nil)
    }
}
