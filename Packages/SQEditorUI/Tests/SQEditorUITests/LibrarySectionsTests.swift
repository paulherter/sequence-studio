import Foundation
import SQCore
import SQLibrary
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct LibrarySectionsTests {
    private func makeModel(_ files: [String]) async throws -> (LibraryPanelModel, URL, WatchedFolder) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libsec-\(UUID().uuidString)")
        let media = root.appendingPathComponent("Music")
        for f in files {
            let u = media.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let store = try PresetStore(applicationSupport: root.appendingPathComponent("support"))
        let cache = PreviewCache(cachesDirectory: root.appendingPathComponent("caches"), disk: .unchecked)
        let model = LibraryPanelModel(index: LibraryIndex(watcher: FakeFolderWatcher()), presetStore: store,
                                      coordinator: PreviewCoordinator(cache: cache, provider: MediaPreviewProvider(cache: cache)),
                                      favoritesURL: root.appendingPathComponent("favorites.json"))
        await model.start()
        let folder = await model.addFolder(url: media)
        return (model, root, folder)
    }

    @Test func folderWithSubfoldersShowsAllThenCategories() async throws {
        let (model, root, _) = try await makeModel(["top.wav", "Calm/a.wav", "Calm/Piano/p.wav", "Epic/e.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = model.sections
        #expect(s.map(\.group.title) == ["All", "Calm", "Piano", "Epic"])
        #expect(s[0].items.count == 4 && s[0].group.totalCount == 4)
        #expect(s[1].items.map(\.entry.name) == ["a.wav"] && s[1].group.totalCount == 2)
        #expect(model.items.count == 4)                       // drag source list stays flat
    }

    @Test func flatFolderHasNoSections() async throws {
        let (model, root, _) = try await makeModel(["a.wav", "b.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.sections.isEmpty)
    }

    @Test func collapseHidesItemsAndNestedSections() async throws {
        let (model, root, _) = try await makeModel(["Calm/a.wav", "Calm/Piano/p.wav", "Epic/e.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.toggleGroup("Calm")
        let s = model.sections
        #expect(s.map(\.group.id) == ["*", "Calm", "Epic"])
        #expect(s[1].items.isEmpty && s[1].group.isCollapsed && s[1].group.totalCount == 2)
        model.toggleGroup("Calm")
        #expect(model.sections.map(\.group.id) == ["*", "Calm", "Calm/Piano", "Epic"])
    }

    @Test func searchFiltersSectionsAndDropsEmptyOnes() async throws {
        let (model, root, _) = try await makeModel(["Calm/sun.wav", "Epic/storm.wav", "Epic/Sub/sun2.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.query = "sun"
        #expect(model.sections.map(\.group.id) == ["*", "Calm", "Epic", "Epic/Sub"])
        #expect(model.sections.first { $0.group.id == "Epic" }?.items.isEmpty == true)
        model.query = "storm"
        #expect(model.sections.map(\.group.id) == ["*", "Epic"])
    }

    @Test func selectingAnotherItemSwitchesPreviewAndFolderChangeStopsIt() async throws {
        let (model, root, folder) = try await makeModel(["Calm/a.wav", "Calm/b.wav", "pic.png", "x.cube"])
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try #require(model.items.first { $0.entry.name == "a.wav" })
        let b = try #require(model.items.first { $0.entry.name == "b.wav" })
        let pic = try #require(model.items.first { $0.entry.name == "pic.png" })
        let cube = try #require(model.items.first { $0.entry.name == "x.cube" })
        model.selectItemForPreview(a)
        #expect(model.previewItem?.id == a.id && model.preview.currentItemID == a.id)
        model.selectItemForPreview(b)
        #expect(model.preview.currentItemID == b.id)
        model.selectItemForPreview(pic)
        #expect(model.preview.mode == .image && !model.preview.isPlaying)
        model.selectItemForPreview(cube)                      // no preview for a LUT
        #expect(model.previewItem == nil && model.preview.currentItemID == nil)
        model.selectItemForPreview(a)
        model.selection = .favorites
        #expect(model.previewItem == nil && model.preview.currentItemID == nil)
        _ = folder
    }
}
