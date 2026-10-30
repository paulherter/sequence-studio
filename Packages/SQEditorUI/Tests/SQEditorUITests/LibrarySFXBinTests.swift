import Foundation
import SQCore
import Testing
import SQLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

private struct NoPreviews: PreviewProvider {
    func generate(_ request: PreviewRequest, to destination: URL) async throws { try Data("png".utf8).write(to: destination) }
}

@MainActor
private func makeModel(root: URL, defaults: UserDefaults) async throws -> LibraryPanelModel {
    let store = try PresetStore(applicationSupport: root.appendingPathComponent("support"))
    let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("caches"), disk: .unchecked), provider: NoPreviews())
    let model = LibraryPanelModel(index: LibraryIndex(watcher: FakeFolderWatcher()), presetStore: store, coordinator: coordinator,
                                  favoritesURL: root.appendingPathComponent("favorites.json"))
    model.sfxDirectory = root.appendingPathComponent("SFX")
    model.whooshDefaults = defaults
    await model.start()
    return model
}

@MainActor @Suite struct LibrarySFXBinTests {
    @Test func binIsCreatedOnDemandAndStartsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(root: root, defaults: UserDefaults(suiteName: "sfx-\(UUID().uuidString)")!)
        #expect(model.sfxFolder == nil && model.whooshSound == nil)
        let f = await model.ensureSFXBin()
        #expect(f?.displayName == "SFX")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("SFX").path))
        #expect(model.folders.count == 1)
        _ = await model.ensureSFXBin()
        #expect(model.folders.count == 1)          // not added twice
        #expect(model.whooshSound == nil)          // empty: nothing bundled
    }

    @Test func addingFilesCopiesAudioAndWhooshPicksLastChosenElseFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "sfx-\(UUID().uuidString)"
        let model = try await makeModel(root: root, defaults: UserDefaults(suiteName: suite)!)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for n in ["b_whoosh.wav", "a_swish.wav", "note.txt"] { try Data("x".utf8).write(to: src.appendingPathComponent(n)) }
        let copied = await model.addToSFXBin(["b_whoosh.wav", "a_swish.wav", "note.txt"].map { src.appendingPathComponent($0) })
        #expect(copied == 2)                        // the text file is not audio
        #expect(model.sfxSounds.map(\.lastPathComponent) == ["a_swish.wav", "b_whoosh.wav"])
        #expect(model.whooshSound?.lastPathComponent == "a_swish.wav")
        model.chooseWhoosh(model.sfxSounds[1])
        #expect(model.whooshSound?.lastPathComponent == "b_whoosh.wav")
        // Same name again gets a number instead of overwriting.
        #expect(await model.addToSFXBin([src.appendingPathComponent("a_swish.wav")]) == 1)
        #expect(model.sfxSounds.count == 3)
        // A chosen file that left the bin falls back to the first.
        model.chooseWhoosh(URL(fileURLWithPath: "/nowhere/gone.wav"))
        #expect(model.whooshSound == model.sfxSounds.first)
    }
}
