import AppKit
import Foundation
import Testing
import SQLibrary
@testable import SQEditorUI

/// Provider that blocks until released, records calls and cancellations.
private final class FakeProvider: PreviewProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    private var _cancelled: [String] = []
    var hold: Bool
    init(hold: Bool = false) { self.hold = hold }

    var started: [String] { lock.withLock { _started } }
    var cancelled: [String] { lock.withLock { _cancelled } }

    func generate(_ request: PreviewRequest, to destination: URL) async throws {
        let name = request.entryID.relativePath
        lock.withLock { _started.append(name) }
        if hold {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                lock.withLock { _cancelled.append(name) }
                throw error
            }
        }
        try Data("png".utf8).write(to: destination)
    }
}

@MainActor
private struct Env {
    let root: URL
    let media: URL
    let watcher = FakeFolderWatcher()
    let provider: FakeProvider
    let model: LibraryPanelModel
    let store: PresetStore

    init(hold: Bool = false, files: [String] = ["b_clip.mp4", "a_song.wav", "Café.png", "x.cube"]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: media.appendingPathComponent(f)) }
        provider = FakeProvider(hold: hold)
        store = try PresetStore(applicationSupport: root.appendingPathComponent("support"))
        let coordinator = PreviewCoordinator(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("caches")), provider: provider)
        model = LibraryPanelModel(
            index: LibraryIndex(watcher: watcher), presetStore: store, coordinator: coordinator,
            favoritesURL: root.appendingPathComponent("favorites.json"))
        await model.start()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func eventually(_ cond: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

@MainActor @Suite struct LibraryPanelModelTests {
    @Test func addFolderSelectsAndListsSorted() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        var persisted: [WatchedFolder] = []
        env.model.onFoldersChanged = { persisted = $0 }
        let f = await env.model.addFolder(url: env.media)
        #expect(env.model.selection == .folder(f.id))
        #expect(persisted.map(\.id) == [f.id])
        #expect(env.model.items.map(\.entry.name) == ["a_song.wav", "b_clip.mp4", "Café.png", "x.cube"])
        #expect(env.model.items[1].url == env.media.appendingPathComponent("b_clip.mp4"))
    }

    @Test func removeFolderFallsBackToFavorites() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let f = await env.model.addFolder(url: env.media)
        await env.model.removeFolder(f.id)
        #expect(env.model.folders.isEmpty)
        #expect(env.model.selection == .favorites)
        #expect(env.model.items.isEmpty)
    }

    @Test func offlineFolderShowsNothing() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let missing = env.root.appendingPathComponent("gone")
        let f = await env.model.addFolder(url: missing)
        #expect(env.model.folders.first?.state == .offline)
        #expect(env.model.isSelectedFolderOffline)
        #expect(env.model.items.isEmpty)
        // Comes online once created and the watcher fires.
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: missing.appendingPathComponent("v.mov"))
        await env.model.rescan(f.id)
        #expect(!env.model.isSelectedFolderOffline)
        #expect(env.model.items.map(\.entry.name) == ["v.mov"])
    }

    @Test func watcherUpdateRefreshesItems() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let f = await env.model.addFolder(url: env.media)
        try Data("x".utf8).write(to: env.media.appendingPathComponent("new.mp3"))
        env.watcher.fire(env.media)
        #expect(await eventually { env.model.items.contains { $0.entry.name == "new.mp3" } })
        _ = f
    }

    @Test func searchTokensAndKindChips() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        env.model.query = "cafe"
        #expect(env.model.items.map(\.entry.name) == ["Café.png"])
        env.model.query = ""
        env.model.toggleKind(.audio)
        env.model.toggleKind(.video)
        #expect(env.model.items.map(\.entry.name) == ["a_song.wav", "b_clip.mp4"])
        env.model.toggleKind(.audio)
        #expect(env.model.items.map(\.entry.name) == ["b_clip.mp4"])
        env.model.clearKindFilter()
        #expect(env.model.items.count == 4)
    }

    @Test func sortDescending() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        env.model.ascending = false
        #expect(env.model.items.first?.entry.name == "x.cube")
    }

    @Test func favoritesToggleFilterAndPersist() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        let song = try #require(env.model.items.first { $0.entry.name == "a_song.wav" })
        #expect(!song.isFavorite)
        env.model.toggleFavorite(song.id)
        #expect(env.model.items.first { $0.id == song.id }?.isFavorite == true)
        env.model.selection = .favorites
        #expect(env.model.items.map(\.entry.name) == ["a_song.wav"])
        // A second model with the same favorites file sees it after start().
        let again = LibraryPanelModel(
            index: LibraryIndex(watcher: env.watcher), presetStore: env.store,
            coordinator: PreviewCoordinator(cache: PreviewCache(cachesDirectory: env.root.appendingPathComponent("c2")), provider: env.provider),
            favoritesURL: env.root.appendingPathComponent("favorites.json"))
        await again.start()
        #expect(again.favorites.contains(song.id))
        env.model.toggleFavorite(song.id)
        env.model.selection = .favorites
        #expect(env.model.items.isEmpty)
    }

    // Review finding 38: the ascending comparator was not a strict ordering (equal names compared "before" each other).
    @Test func equalPresetNamesKeepTheirOrderWhenAscending() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        for i in 0..<6 { try await env.store.add(PresetItem(kind: .easing, name: "Same", payload: Data("{\(i)}".utf8), payloadVersion: 1)) }
        env.model.selection = .presets(nil)
        let a = env.model.visiblePresets.map(\.id)
        env.model.ascending = false
        env.model.ascending = true
        #expect(env.model.visiblePresets.map(\.id) == a)
        let ids = env.model.visiblePresets.map(\.id)
        #expect(ids == env.model.presets.filter { $0.name == "Same" }.map(\.id))
    }

    // Review finding 39: a favorites file from a newer version was ignored on load and then overwritten by the next toggle.
    @Test func favoritesFileOfANewerVersionIsNotOverwritten() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let url = env.root.appendingPathComponent("favorites.json")
        let newer = Data(#"{"formatVersion": 99, "items": []}"#.utf8)
        try newer.write(to: url)
        await env.model.start()
        let folder = await env.model.addFolder(url: env.media)
        _ = folder
        let song = try #require(env.model.items.first { $0.entry.name == "a_song.wav" })
        env.model.toggleFavorite(song.id)
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test func presetsSectionByKind() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        try await env.store.add(PresetItem(kind: .textTemplate, name: "Lower Third", payload: Data("{}".utf8), payloadVersion: 1))
        try await env.store.add(PresetItem(kind: .easing, name: "Snappy", payload: Data("{}".utf8), payloadVersion: 1))
        try await env.store.add(PresetItem(kind: .easing, name: "Ease 2", payload: Data("{}".utf8), payloadVersion: 1))
        await env.model.reloadPresets()
        env.model.selection = .presets(.easing)
        #expect(env.model.visiblePresets.map(\.name) == ["Ease 2", "Snappy"])
        env.model.selection = .presets(nil)
        #expect(env.model.visiblePresets.count == 3)
        env.model.query = "lower"
        #expect(env.model.visiblePresets.map(\.name) == ["Lower Third"])
        #expect(env.model.presetCount(.easing) == 2)
        #expect(env.model.isShowingPresets)
        #expect(env.model.items.isEmpty)
    }

    @Test func dragURLsAreFileURLs() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        let ids = env.model.items.prefix(2).map(\.id)
        let urls = env.model.dragURLs(for: ids)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.isFileURL })
        #expect(urls[0].lastPathComponent == "a_song.wav")
    }

    @Test func thumbnailRequestCompletes() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        let clip = try #require(env.model.items.first { $0.entry.name == "b_clip.mp4" })
        env.model.itemDidAppear(clip)
        env.model.itemDidAppear(clip)  // idempotent
        #expect(await eventually { env.model.thumbnails[clip.id] != nil })
        #expect(env.provider.started == ["b_clip.mp4"])
        #expect(env.model.pendingPreviewCount == 0)
    }

    @Test func noPreviewForLutAndFont() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        let lut = try #require(env.model.items.first { $0.entry.kind == .lut })
        env.model.itemDidAppear(lut)
        #expect(env.model.pendingPreviewCount == 0)
    }

    @Test func scrollOutCancelsRequest() async throws {
        let env = try await Env(hold: true)
        defer { env.cleanup() }
        _ = await env.model.addFolder(url: env.media)
        let clip = try #require(env.model.items.first { $0.entry.name == "b_clip.mp4" })
        env.model.itemDidAppear(clip)
        #expect(await eventually { env.provider.started.count == 1 })
        env.model.itemDidDisappear(clip.id)
        #expect(env.model.pendingPreviewCount == 0)
        #expect(await eventually { env.provider.cancelled == ["b_clip.mp4"] })
        #expect(env.model.thumbnails[clip.id] == nil)
        #expect(!env.model.failedPreviews.contains(clip.id))
    }

    @Test func viewSmoke() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let view = LibraryPanelView(model: env.model)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 440)
        _ = await env.model.addFolder(url: env.media)
        view.layoutSubtreeIfNeeded()
        env.model.viewMode = .list
        env.model.selection = .presets(nil)
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        #expect(view.subviews.count == 1)
    }

    // Review finding 11: every model change (a finished thumbnail, a favorite) reloaded the grid and dropped the selection.
    @Test func selectionSurvivesARefresh() async throws {
        let env = try await Env()
        defer { env.cleanup() }
        let view = LibraryPanelView(model: env.model)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 440)
        _ = await env.model.addFolder(url: env.media)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func find(_ v: NSView) -> NSCollectionView? {
            if let c = v as? NSCollectionView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        let grid = try #require(find(view))
        grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        let other = try #require(env.model.items.first)
        env.model.toggleFavorite(other.id)                 // observed: the view refreshes
        try await Task.sleep(for: .milliseconds(100))
        #expect(grid.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    }
}
