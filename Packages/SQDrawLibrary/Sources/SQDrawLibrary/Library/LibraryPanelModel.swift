import Foundation
import Observation
import SQCore
import SQLibrary
import SQInspectorUI
import SQEditorSession
import SQText

/// Sidebar selection of the Library panel.
public enum LibrarySection: Hashable, Sendable {
    /// The "Library" group row: every item of every online folder.
    case all
    case folder(UUID)
    case favorites
    /// Presets of one kind; nil = all kinds.
    case presets(PresetKind?)
    /// The presets imported from one `.sqpack`, shown as a folder named after the pack.
    case pack(String)
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

/// One section of the grid/list: header (title, count, collapse) and the items shown under it.
public struct LibrarySectionData: Identifiable, Sendable {
    public var group: LibraryGroup
    public var items: [LibraryItem]
    public var id: String { group.id }
}

public enum LibraryViewMode: String, Sendable, CaseIterable { case grid, list }

/// State and logic of the Library panel. No AppKit; the view observes it.
@MainActor @Observable
public final class LibraryPanelModel {
    // MARK: Dependencies
    @ObservationIgnored private let index: LibraryIndex
    @ObservationIgnored public let presetStore: PresetStore
    /// The Look store the Captions group reads (nil = none, e.g. tests of the panel alone): its Looks are listed as
    /// `.caption` items, a `.caption` preset itself never is, and the store follows the preset store (`reloadPresets`).
    @ObservationIgnored public var lookStore: LookStore? {
        didSet {
            if let lookObserver { NotificationCenter.default.removeObserver(lookObserver); Self.liveLookObservers -= 1 }
            lookObserver = nil
            if let lookStore {
                Self.liveLookObservers += 1
                lookObserver = NotificationCenter.default.addObserver(forName: LookStore.didChange, object: lookStore, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recomposePresets() }
                }
            }
            recomposePresets()
        }
    }
    @ObservationIgnored private var lookObserver: NSObjectProtocol?
    @ObservationIgnored private var storedPresets: [PresetItem] = []
    /// Observers on `LookStore.didChange` that are still installed (tests check that a model removes its own).
    nonisolated(unsafe) public static var liveLookObservers = 0
    @ObservationIgnored private let coordinator: PreviewCoordinator
    @ObservationIgnored private let favoritesURL: URL
    /// Called after folders were added or removed, so the host can persist them.
    @ObservationIgnored public var onFoldersChanged: (([WatchedFolder]) -> Void)?
    /// Where the SFX bin lives on disk (set by `LibraryServices`); nil = no SFX bin support.
    @ObservationIgnored public var sfxDirectory: URL?
    /// UserDefaults key of the last whoosh sound the user chose from the SFX bin (its file path).
    @ObservationIgnored public var whooshDefaults: UserDefaults = .standard
    public static let lastWhooshKey = "sq.sfx.lastWhoosh"
    /// Double-click / "Apply to Selected Clips" on a preset: the host applies it to the selection.
    /// Double-click / drag of a title block: the host places it at the playhead / drop time.
    @ObservationIgnored public var onInsertTitleBlock: ((PresetItem, Time?) -> Void)?
    /// A pack carried workspace layouts: the host stores them as user workspaces.
    @ObservationIgnored public var onImportWorkspaces: (([Workspace]) -> Void)?
    /// .mogrt files dropped on the panel: the host imports them like File > Import Motion Graphics Template.
    @ObservationIgnored public var onImportMotionGraphicsTemplates: (([URL]) -> Void)?
    @ObservationIgnored public var onApplyPreset: ((PresetItem, EffectPreset.ApplyMode?) -> Void)?   // nil mode = the remembered default

    // MARK: Observable state
    public private(set) var folders: [LibraryFolderRow] = []
    public private(set) var presets: [PresetItem] = []
    public private(set) var favorites = Favorites()
    public private(set) var thumbnails: [LibraryEntryID: URL] = [:]
    public private(set) var failedPreviews: Set<LibraryEntryID> = []
    private var entriesByFolder: [UUID: [LibraryEntry]] = [:]

    public var selection: LibrarySection = .favorites {
        didSet { if oldValue != selection { selectItemForPreview(nil) } }
    }
    /// Own player of the Library (never the timeline engine); starts on selecting an audio or video item.
    public let preview = LibraryPreviewPlayer()
    /// The item the preview bar shows (selected in the grid or list); nil = no preview bar.
    public private(set) var previewItem: LibraryItem?
    /// Sections (group ids, `LibraryGroup.allID` for All) the user collapsed. Not persisted.
    public private(set) var collapsedGroups: Set<String> = []
    public var query = ""
    public private(set) var kindFilter: Set<LibraryItemKind> = []
    public var sortKey: LibrarySortKey = .name
    public var ascending = true
    private var favoritesWritable = true
    /// Presets section: category, tags, favorites and use counts (side file next to the favorites), sort, scope, filters.
    public private(set) var presetMeta = PresetMetaTable()
    public var presetSort: PresetSortKey = .name
    public var presetAscending = true
    public var presetScope: PresetScope = .all
    public var presetCategory: PresetCategory?
    public var presetTag: String?
    private var presetMetaWritable = true
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
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver); Self.liveLookObservers -= 1 }
        updatesTask?.cancel()
        previewTasks.values.forEach { $0.task.cancel() }
    }

    // MARK: Lifecycle

    /// Loads favorites, presets and the index state, then follows watcher updates.
    public func start() async {
        do { favorites = try FavoritesStore.load(from: favoritesURL); favoritesWritable = true } catch {
            favorites = Favorites(); favoritesWritable = false      // e.g. a newer app version's file: never overwrite it
        }
        do { presetMeta = try PresetMetaStore.load(from: presetMetaURL); presetMetaWritable = true } catch {
            presetMeta = PresetMetaTable(); presetMetaWritable = false
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
        if let current = previewItem, update.diff.removed.contains(where: { $0.id == current.id }) { selectItemForPreview(nil) }
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

    public func reloadPresets() async {
        storedPresets = await presetStore.all()
        // One Look system: a `.caption` preset added, changed, renamed, deleted or imported here changes its Look.
        await lookStore?.importCaptionPresets(from: presetStore)
        recomposePresets()
        // Presets that are only hidden (no Look list to compare with) keep their favorites and meta.
        let kept = presetsAreAuthoritative ? presets : storedPresets + presets
        presetMeta.prune(keepingUserKeys: Set(kept.map { PresetKey.user($0.id) }))
    }

    /// The list the panel shows: the preset store's presets, with every `.caption` one replaced by the Look under its
    /// id. A `.caption` preset without a Look is a stale copy (its Look was deleted) and is not listed, except one this
    /// build cannot read (it keeps its Look-less place). Looks of the Text panel (no preset) are listed too.
    private func recomposePresets() {
        guard let lookStore else { presets = storedPresets; return }
        let looks = lookStore.library.user
        let byID = Dictionary(looks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PresetItem] = []
        var placed: Set<String> = []
        for p in storedPresets {
            guard p.kind == .caption else { out.append(p); continue }
            if let look = byID[p.id.uuidString], var item = Self.item(for: look, like: p) {
                item.pack = p.pack
                out.append(item); placed.insert(look.id)
            } else if byID[p.id.uuidString] == nil, !presetsAreAuthoritative || !Self.isReadable(caption: p) {
                out.append(p)
            }
        }
        for look in looks where !placed.contains(look.id) {
            if let item = Self.item(for: look, like: nil) { out.append(item) }
        }
        if out != presets { presets = out }
    }

    /// False while the Look list cannot say which Looks exist (its file was not loaded, or the preset store is a
    /// stand-in that the follow skips): a `.caption` preset without a Look is then kept, not dropped.
    private var presetsAreAuthoritative: Bool { (lookStore?.isLoaded ?? true) && presetStore.origin != .standIn }

    private static func isReadable(caption p: PresetItem) -> Bool {
        p.payloadVersion <= CaptionLookPayload.version && (try? JSONDecoder().decode(CaptionLookPayload.self, from: p.payload)) != nil
    }

    /// A Look as a `.caption` item (same payload a caption preset has). Nil for an id that is not a UUID.
    private static func item(for look: Look, like preset: PresetItem?) -> PresetItem? {
        guard let id = UUID(uuidString: look.id),
              let payload = try? JSONEncoder().encode(CaptionLookPayload(look: look.captionLook, segmentation: LookStore.segmentation(of: look), category: look.category))
        else { return nil }
        return PresetItem(id: id, kind: .caption, name: look.name, createdAt: preset?.createdAt ?? Date(timeIntervalSince1970: 0),
                          payload: payload, payloadVersion: CaptionLookPayload.version)
    }

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

    /// Indexed entries of one folder (unsorted, unfiltered).
    public func entries(in folderID: UUID) -> [LibraryEntry] { entriesByFolder[folderID] ?? [] }

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
        switch selection {
        case .presets, .pack: return true
        default: return false
        }
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
        case .all:
            source = online.flatMap { entriesByFolder[$0.id] ?? [] }
        case .presets, .pack:
            source = []
        }
        let byID = Dictionary(folders.map { ($0.id, $0.folder) }, uniquingKeysWith: { a, _ in a })
        return LibrarySearch.filter(source, query: query, kinds: kindFilter, sort: sortKey, ascending: ascending)
            .compactMap { entry in
                guard let f = byID[entry.folderID] else { return nil }
                return LibraryItem(entry: entry, url: entry.url(in: f), isFavorite: favorites.contains(entry.id))
            }
    }

    /// Sections of a Library folder with subfolders: All first, then one per subfolder (nested ones indented), with the
    /// collapsed state applied. Empty = show the plain flat `items` list (no subfolders, Favorites, presets).
    public var sections: [LibrarySectionData] {
        guard case .folder = selection else { return [] }
        let all = items
        let groups = LibraryGrouping.groups(all.map(\.entry))
        guard !groups.isEmpty else { return [] }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return LibraryGrouping.visible(groups, collapsed: collapsedGroups).map { g in
            LibrarySectionData(group: g, items: g.entries.compactMap { byID[$0.id] })
        }
    }

    public func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    /// Selecting an item previews it: audio and video start playing (stopping the previous one), images show larger.
    public func selectItemForPreview(_ item: LibraryItem?) {
        guard let item, let mode = LibraryPreviewMath.mode(for: item.entry.kind) else {
            previewItem = nil
            preview.stop()
            return
        }
        if previewItem?.id == item.id { return }
        previewItem = item
        preview.select(id: item.id, url: item.url, mode: mode)
    }

    // MARK: Preset organizing (category, tags, favorites, recents, sort)

    private var presetMetaURL: URL { favoritesURL.deletingLastPathComponent().appendingPathComponent("preset-meta.json") }

    /// Category of a built-in template: the user's choice, else guessed from its name (the CTA end card is Social).
    private static func defaultCategory(of t: TextTemplateCatalog.Entry) -> PresetCategory {
        t.isCTA ? .social : PresetCategory.inferred(fromName: t.name)
    }

    public func entry(for preset: PresetItem) -> PresetListEntry {
        let key = PresetKey.user(preset.id)
        return PresetListEntry(key: key, name: preset.name, isBuiltIn: false, createdAt: preset.createdAt,
                               defaultCategory: PresetCategory.defaultCategory(for: preset.kind), meta: presetMeta[key])
    }

    public func entry(for template: TextTemplateCatalog.Entry) -> PresetListEntry {
        let key = PresetKey.builtIn(template.id)
        return PresetListEntry(key: key, name: template.name, isBuiltIn: true, defaultCategory: Self.defaultCategory(of: template), meta: presetMeta[key])
    }

    private var presetFilter: PresetFilter {
        PresetFilter(query: query, category: presetCategory, scope: presetScope, tag: presetTag)
    }

    /// True while a scope, category or tag narrows the list (the search field is separate).
    public var presetFilterActive: Bool { presetScope != .all || presetCategory != nil || presetTag != nil }

    public func clearPresetFilters() { presetScope = .all; presetCategory = nil; presetTag = nil }

    /// Everything the current presets section can show, before search and filters.
    private var sectionEntries: [PresetListEntry] {
        if case .pack(let name) = selection { return presets.filter { $0.pack == name }.map(entry(for:)) }
        guard case .presets(let kind) = selection else { return [] }
        let user = presets.filter { kind == nil || $0.kind == kind || (kind == .textTemplate && ($0.kind == .titleBlock || $0.kind == .titleTemplate)) }.map(entry(for:))   // saved titles sit with the text templates
        let built = (kind == nil || kind == .textTemplate) ? TextTemplateCatalog.all.map(entry(for:)) : []
        return built + user
    }

    private var visiblePresetKeys: [String] {
        PresetOrganizer.visible(sectionEntries, filter: presetFilter, sort: presetSort, ascending: presetAscending).map(\.key)
    }

    /// Presets of the current presets section after search, scope, category, tag and sort.
    public var visiblePresets: [PresetItem] {
        let byKey = Dictionary(presets.map { (PresetKey.user($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        return visiblePresetKeys.compactMap { byKey[$0] }
    }

    /// Built-in text templates (drag to the timeline): shown under Text Templates and All Presets, same filters as the presets.
    public var visibleTextTemplates: [TextTemplateCatalog.Entry] {
        let byKey = Dictionary(TextTemplateCatalog.all.map { (PresetKey.builtIn($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        return visiblePresetKeys.compactMap { byKey[$0] }
    }

    /// Categories and tags present in the current section, for the menus.
    public var presetCategoryCounts: [PresetCategory: Int] { PresetOrganizer.categoryCounts(sectionEntries) }
    public var presetTagCounts: [(tag: String, count: Int)] { PresetOrganizer.tagCounts(sectionEntries) }

    public func sortPresets(by key: PresetSortKey) {
        if presetSort == key { presetAscending.toggle() } else { presetSort = key; presetAscending = true }
    }

    public func toggleFavoritePreset(_ key: String) { editMeta { $0.toggleFavorite(key) } }
    public func setPresetCategory(_ key: String, _ category: PresetCategory?) { editMeta { $0.setCategory(key, category) } }
    public func togglePresetTag(_ key: String, _ tag: String) { editMeta { $0.toggleTag(key, tag) } }
    /// A preset or template was applied, inserted or dragged out: feeds Recent and Most Used.
    public func recordPresetUse(_ key: String) { editMeta { $0.recordUse(key) } }

    private func editMeta(_ change: (inout PresetMetaTable) -> Void) {
        change(&presetMeta)
        guard presetMetaWritable else { return }      // a newer app version's file is never overwritten
        try? PresetMetaStore.save(presetMeta, to: presetMetaURL)
    }

    public func presetCount(_ kind: PresetKind?) -> Int { presets.filter { kind == nil || $0.kind == kind || (kind == .textTemplate && ($0.kind == .titleBlock || $0.kind == .titleTemplate)) }.count }

    // MARK: Preset files and editing

    /// Adds a preset (e.g. "Save as Preset…") and shows it.
    public func savePreset(_ item: PresetItem) async throws {
        try await presetStore.add(item)
        await reloadPresets()
    }

    /// Adds the preset, or replaces the one with its id (name and payload).
    public func replacePreset(_ item: PresetItem) async throws {
        if await presetStore.preset(item.id) != nil {
            try await presetStore.updatePayload(item.id, payload: item.payload, version: item.payloadVersion)
            try await presetStore.rename(item.id, to: item.name)
        } else {
            try await presetStore.add(item)
        }
        await reloadPresets()
    }

    public func deletePreset(_ id: UUID) async {
        // A Look is deleted in the Look store (it takes its preset along); the rest goes to the preset store.
        if let lookStore, lookStore.library.look(id.uuidString) != nil {
            _ = try? lookStore.edit { $0.delete(id.uuidString) }
            try? await presetStore.delete(id)
            lookStore.forgetPreset(id)
        } else {
            try? await presetStore.delete(id)
        }
        await reloadPresets()
    }

    /// Writes one preset as a `.sqpreset` file.
    /// A Look that only lives in the Look store (saved in the Text panel) has no stored preset: the file is built from
    /// the listed item, which carries the Look's values and category.
    public func exportPreset(_ id: UUID, to url: URL) async throws {
        if await presetStore.preset(id) == nil, let item = presets.first(where: { $0.id == id }) {
            try PresetFile.encode(item).write(to: url, options: .atomic)
            return
        }
        try await presetStore.exportPreset(id, to: url)
    }

    /// Imports `.sqpreset` files; returns the files that failed with their errors (the others are added).
    public func importPresets(from urls: [URL]) async -> [(url: URL, error: any Error)] {
        var failures: [(url: URL, error: any Error)] = []
        for url in urls {
            do { try await presetStore.importPreset(from: url) } catch { failures.append((url, error)) }
        }
        await reloadPresets()
        return failures
    }

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
                // Canceled, stale or disk low: a later appearance retries. Anything else is remembered.
                let retry = error is CancellationError || [.stale, .diskLow].contains(error as? PreviewError)
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
