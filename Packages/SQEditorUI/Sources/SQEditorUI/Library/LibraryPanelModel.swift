import Foundation
import Observation
import SQLibrary

/// Sidebar selection of the Library panel.
public enum LibrarySection: Hashable, Sendable {
    case folder(UUID)
    case favorites
    /// Presets of one kind; nil = all kinds.
    case presets(PresetKind?)
}

public struct LibraryFolderRow: Identifiable, Equatable, Sendable {
    public var folder: WatchedFolder
    public var state: FolderState
    public var id: UUID { folder.id }
}

/// One item shown in the grid/list.
public struct LibraryItem: Identifiable, Hashable, Sendable {
    public var entry: LibraryEntry
    public var url: URL
    public var isFavorite: Bool
    public var id: LibraryEntryID { entry.id }
}

public enum LibraryViewMode: String, Sendable, CaseIterable { case grid, list }

/// State and logic of the Library panel. No AppKit; the view observes it.
@MainActor @Observable
public final class LibraryPanelModel {
    // MARK: Dependencies
    @ObservationIgnored private let index: LibraryIndex
    @ObservationIgnored private let presetStore: PresetStore
    @ObservationIgnored private let coordinator: PreviewCoordinator
    @ObservationIgnored private let favoritesURL: URL
    /// Called after folders were added or removed, so the host can persist them.
    @ObservationIgnored public var onFoldersChanged: (([WatchedFolder]) -> Void)?

    // MARK: Observable state
    public private(set) var folders: [LibraryFolderRow] = []
    public private(set) var presets: [PresetItem] = []
    public private(set) var favorites = Favorites()
    public private(set) var thumbnails: [LibraryEntryID: URL] = [:]
    public private(set) var failedPreviews: Set<LibraryEntryID> = []
    private var entriesByFolder: [UUID: [LibraryEntry]] = [:]

    public var selection: LibrarySection = .favorites
    public var query = ""
    public private(set) var kindFilter: Set<LibraryItemKind> = []
    public var sortKey: LibrarySortKey = .name
    public var ascending = true
    private var favoritesWritable = true
    public var viewMode: LibraryViewMode = .grid
    /// Pixel size used for preview requests.
    public var previewPixelSize = (width: 256, height: 144)

    @ObservationIgnored private var previewTasks: [LibraryEntryID: (gen: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    /// Kinds offered as filter chips.
    public static let filterKinds: [LibraryItemKind] = [.video, .audio, .image, .overlay, .lut, .font]

    public init(index: LibraryIndex, presetStore: PresetStore, coordinator: PreviewCoordinator, favoritesURL: URL) {
        self.index = index
        self.presetStore = presetStore
        self.coordinator = coordinator
        self.favoritesURL = favoritesURL
    }

    isolated deinit {
        updatesTask?.cancel()
        previewTasks.values.forEach { $0.task.cancel() }
    }

    // MARK: Lifecycle

    /// Loads favorites, presets and the index state, then follows watcher updates.
    public func start() async {
        do { favorites = try FavoritesStore.load(from: favoritesURL); favoritesWritable = true } catch {
            favorites = Favorites(); favoritesWritable = false      // e.g. a newer app version's file: never overwrite it
        }
        await reloadPresets()
        await reloadFolders()
        if updatesTask == nil {
            let stream = await index.updates()
            updatesTask = Task { [weak self] in
                for await update in stream {
                    guard let self else { return }
                    await self.apply(update)
                }
            }
        }
    }

    private func apply(_ update: LibraryUpdate) async {
        await reloadFolders()
        for e in update.diff.removed + update.diff.changed {
            thumbnails[e.id] = nil
            failedPreviews.remove(e.id)
            cancelPreview(e.id)
        }
    }

    private func reloadFolders() async {
        var rows: [LibraryFolderRow] = []
        var entries: [UUID: [LibraryEntry]] = [:]
        for f in await index.folders {
            rows.append(LibraryFolderRow(folder: f, state: await index.state(of: f.id) ?? .offline))
            entries[f.id] = await index.entries(in: f.id)
        }
        folders = rows
        entriesByFolder = entries
    }

    public func reloadPresets() async { presets = await presetStore.all() }

    // MARK: Folders

    @discardableResult
    public func addFolder(url: URL, bookmark: Data? = nil) async -> WatchedFolder {
        let folder = WatchedFolder(url: url, bookmark: bookmark)
        await index.add(folder)
        await reloadFolders()
        selection = .folder(folder.id)
        onFoldersChanged?(folders.map(\.folder))
        return folder
    }

    /// Re-adds folders restored from disk (no selection change, no persistence callback).
    public func restoreFolders(_ restored: [WatchedFolder]) async {
        for f in restored { await index.add(f) }
        await reloadFolders()
    }

    public func removeFolder(_ id: UUID) async {
        await index.remove(id)
        if selection == .folder(id) { selection = .favorites }
        for key in Array(thumbnails.keys) where key.folderID == id { thumbnails[key] = nil }
        for key in Array(failedPreviews) where key.folderID == id { failedPreviews.remove(key) }
        for key in Array(previewTasks.keys) where key.folderID == id { cancelPreview(key) }
        await reloadFolders()
        onFoldersChanged?(folders.map(\.folder))
    }

    public func rescan(_ id: UUID) async {
        await index.rescan(id)
        await reloadFolders()
    }

    public func folder(_ id: UUID) -> WatchedFolder? { folders.first { $0.id == id }?.folder }

    public var isSelectedFolderOffline: Bool {
        if case .folder(let id) = selection { return folders.first { $0.id == id }?.state == .offline }
        return false
    }

    // MARK: Search, filter, sort

    public func toggleKind(_ kind: LibraryItemKind) {
        if kindFilter.contains(kind) { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
    }

    public func clearKindFilter() { kindFilter = [] }

    // MARK: Items

    public var isShowingPresets: Bool {
        if case .presets = selection { return true }
        return false
    }

    /// Items of the current section after search, kind filter and sort.
    /// Offline folders show nothing (their last snapshot is kept but not listed).
    public var items: [LibraryItem] {
        let online = folders.filter { $0.state == .online }
        let source: [LibraryEntry]
        switch selection {
        case .folder(let id):
            source = online.contains { $0.id == id } ? entriesByFolder[id] ?? [] : []
        case .favorites:
            source = online.flatMap { entriesByFolder[$0.id] ?? [] }.filter { favorites.contains($0.id) }
        case .presets:
            source = []
        }
        let byID = Dictionary(folders.map { ($0.id, $0.folder) }, uniquingKeysWith: { a, _ in a })
        return LibrarySearch.filter(source, query: query, kinds: kindFilter, sort: sortKey, ascending: ascending)
            .compactMap { entry in
                guard let f = byID[entry.folderID] else { return nil }
                return LibraryItem(entry: entry, url: entry.url(in: f), isFavorite: favorites.contains(entry.id))
            }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Presets of the current presets section, filtered by the search field, sorted by name.
    public var visiblePresets: [PresetItem] {
        guard case .presets(let kind) = selection else { return [] }
        let tokens = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return presets
            .filter { kind == nil || $0.kind == kind }
            .filter { p in
                let name = Self.fold(p.name)
                return tokens.allSatisfy { name.contains($0) }
            }
            .sorted {
                let c = Self.fold($0.name).compare(Self.fold($1.name), options: .numeric)
                return ascending ? c == .orderedAscending : c == .orderedDescending
            }
    }

    /// Built-in text templates (drag to the timeline): shown under Text Templates and All Presets, filtered by the search.
    public var visibleTextTemplates: [TextTemplateCatalog.Entry] {
        guard case .presets(let kind) = selection, kind == nil || kind == .textTemplate else { return [] }
        let tokens = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return TextTemplateCatalog.all.filter { e in
            let name = Self.fold(e.name)
            return tokens.allSatisfy { name.contains($0) }
        }
    }

    public func presetCount(_ kind: PresetKind?) -> Int { presets.filter { kind == nil || $0.kind == kind }.count }

    // MARK: Favorites

    public func toggleFavorite(_ id: LibraryEntryID) {
        favorites.toggle(id)
        if favoritesWritable { try? FavoritesStore.save(favorites, to: favoritesURL) }
    }

    // MARK: Drag

    /// File URLs to put on the pasteboard when dragging the given items out.
    public func dragURLs(for ids: [LibraryEntryID]) -> [URL] {
        let all = Dictionary(items.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { all[$0] }
    }

    // MARK: Previews

    /// The preview kind an entry kind gets, nil = no preview.
    public static func previewKind(for kind: LibraryItemKind) -> PreviewKind? {
        switch kind {
        case .video, .image, .overlay: .thumbnail
        case .audio: .waveform
        case .lut, .font, .other: nil
        }
    }

    /// Item scrolled into view: start an async preview request (idempotent).
    public func itemDidAppear(_ item: LibraryItem) {
        let id = item.id
        guard let kind = Self.previewKind(for: item.entry.kind),
              thumbnails[id] == nil, previewTasks[id] == nil, !failedPreviews.contains(id),
              let folder = folder(item.entry.folderID) else { return }
        let request = PreviewRequest(
            entry: item.entry, in: folder, kind: kind,
            pixelWidth: previewPixelSize.width, pixelHeight: previewPixelSize.height)
        let coordinator = coordinator
        let gen = UUID()
        previewTasks[id] = (gen, Task { [weak self] in
            do {
                let url = try await coordinator.preview(for: request)
                self?.previewFinished(id, gen, url: url)
            } catch {
                // Cancelled or stale: a later appearance retries. Anything else is remembered.
                let retry = error is CancellationError || (error as? PreviewError) == .stale
                self?.previewEnded(id, gen, failed: !retry)
            }
        })
    }

    /// Item scrolled out: cancel its pending request.
    public func itemDidDisappear(_ id: LibraryEntryID) { cancelPreview(id) }

    public var pendingPreviewCount: Int { previewTasks.count }

    private func cancelPreview(_ id: LibraryEntryID) {
        previewTasks.removeValue(forKey: id)?.task.cancel()
    }

    private func previewFinished(_ id: LibraryEntryID, _ gen: UUID, url: URL) {
        guard previewTasks[id]?.gen == gen else { return }
        previewTasks[id] = nil
        thumbnails[id] = url
    }

    private func previewEnded(_ id: LibraryEntryID, _ gen: UUID, failed: Bool) {
        guard previewTasks[id]?.gen == gen else { return }
        previewTasks[id] = nil
        if failed { failedPreviews.insert(id) }
    }
}
