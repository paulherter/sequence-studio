#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import SQCore
import SQMedia

/// State and edit logic of the Project panel. Holds a `Project` value; every mutating action applies to a copy,
/// reports it through `onEdit(project, actionName)` (one undo step per action) and then adopts it.
/// The app pushes external changes (undo, open) in with `setProject`.
@MainActor @Observable
public final class ProjectPanelModel {
    public typealias Probe = @Sendable (URL) async throws -> MediaRef
    public typealias EditHandler = (Project, String) -> Void

    /// Columns the Project panel can show. `name` is always shown, first.
    public enum Column: String, Sendable, CaseIterable, Codable {
        case name, label, frameRate, duration, resolution, codec, audio, inPoint, filePath, format, sourceTimecode

        public var title: String {
            switch self {
            case .name: "Name"
            case .label: "Label"
            case .frameRate: "Frame Rate"
            case .duration: "Duration"
            case .resolution: "Resolution"
            case .codec: "Codec"
            case .audio: "Audio"
            case .inPoint: "Source In"
            case .filePath: "File Path"
            case .format: "Format"
            case .sourceTimecode: "Source Timecode"
            }
        }
        public var defaultWidth: CGFloat {
            switch self {
            case .name: 200
            case .label: 80
            case .frameRate: 90
            case .duration: 90
            case .resolution: 90
            case .codec: 110
            case .audio: 100
            case .inPoint: 90
            case .filePath: 260
            case .format: 210
            case .sourceTimecode: 110
            }
        }
        public var minWidth: CGFloat { self == .name ? 100 : 50 }
    }

    public private(set) var project: Project
    /// Bin that receives imports and new bins.
    public var currentBin: Bin.ID
    /// Bin the icon view shows (double-click a bin to enter it).
    public var browseBin: Bin.ID { didSet { if oldValue != browseBin { revision += 1 } } }
    public var searchText = "" { didSet { revision += 1 } }
    /// The search text also looks through the spoken words (captions over the media), not only names.
    public var searchSpoken = false { didSet { if oldValue != searchSpoken { revision += 1 } } }
    /// Display-only media filter (header menu > Show): all items, only media no sequence uses, only offline media.
    public enum MediaFilter: String, Sendable, CaseIterable {
        case all, unused, offline
        public var title: String {
            switch self { case .all: "All Media"; case .unused: "Unused Media"; case .offline: "Offline Media" }
        }
    }
    public var mediaFilter: MediaFilter = .all { didSet { if oldValue != mediaFilter { revision += 1 } } }
    /// Smart bin shown instead of the folder tree (display only, not saved): the media matching its rules, flat.
    public var activeSmartBin: SmartBin.ID? { didSet { if oldValue != activeSmartBin { revision += 1 } } }
    /// True while search or the media filter hides items (drag reordering is off then).
    public var isFiltering: Bool {
        activeSmartBin != nil || mediaFilter != .all || !filterTokens.isEmpty || grouping != .folders
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// Facts typed into the search field (`cam:FX3`, `unused`, ...), shown as chips. Display only, not saved.
    public var filterTokens: [MediaFilterToken] = [] { didSet { if oldValue != filterTokens { revision += 1 } } }
    /// "Sorted by": the same media shown grouped by day, camera or kind. Display only, moves nothing, not saved.
    public var grouping: MediaGrouping = .folders { didSet { if oldValue != grouping { revision += 1 } } }
    /// Group headers of the last grouped `children(of:)` call: they behave as folders in the view but exist nowhere in the
    /// project (see `displayBin`).
    @ObservationIgnored private var groupBins: [Bin.ID: Bin] = [:]
    /// Text and tokens together.
    public var filterQuery: MediaFilterQuery { MediaFilterQuery(text: searchText, tokens: filterTokens) }

    /// The folder with `id`: a real one of the project, or a group header of the "Sorted by" view.
    public func displayBin(_ id: Bin.ID) -> Bin? { project.bin(id) ?? groupBins[id] }
    public func isGroupHeader(_ id: Bin.ID) -> Bool { groupBins[id] != nil && project.bin(id) == nil }
    /// Name of a folder, media item or sequence as shown (group headers carry their title).
    public func displayName(of ref: BinItemRef) -> String {
        if case .bin(let id) = ref, let g = groupBins[id], project.bin(id) == nil { return g.name }
        return project.displayName(of: ref)
    }

    /// Same ID for the same group on every call, so expanded headers stay expanded.
    static func groupID(_ mode: MediaGrouping, _ key: String) -> Bin.ID {
        func fnv(_ salt: UInt64) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325 ^ salt
            for b in "\(mode.rawValue)|\(key)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        let a = fnv(0), b = fnv(0x9E3779B97F4A7C15)
        return UUID(uuid: (UInt8(a & 255), UInt8(a >> 8 & 255), UInt8(a >> 16 & 255), UInt8(a >> 24 & 255), UInt8(a >> 32 & 255),
                           UInt8(a >> 40 & 255), UInt8(a >> 48 & 255), UInt8(a >> 56), UInt8(b & 255), UInt8(b >> 8 & 255),
                           UInt8(b >> 16 & 255), UInt8(b >> 24 & 255), UInt8(b >> 32 & 255), UInt8(b >> 40 & 255),
                           UInt8(b >> 48 & 255), UInt8(b >> 56)))
    }
    public private(set) var sortColumn: Column?
    public private(set) var sortAscending = true
    /// Number of files still being probed.
    public private(set) var pendingImports = 0
    /// Files of the running import batch (all overlapping imports together); 0 when none runs. With `pendingImports`
    /// this gives "12 of 240".
    public private(set) var importTotal = 0
    /// Set when the last import was canceled: files that landed, and files in the batch.
    public private(set) var importCanceled: (imported: Int, total: Int)?
    @ObservationIgnored private var importTokens: [String: ImportCancelToken] = [:]

    /// Stops the running import: files not probed yet are skipped; files already probed or landed stay.
    public func cancelImport() { for t in importTokens.values { t.cancel() } }

    /// Status line after a canceled import.
    public static func canceledText(imported: Int, total: Int) -> String {
        "Import canceled: \(imported) of \(total) file\(total == 1 ? "" : "s") imported."
    }
    /// File names of the last imports that could not be read.
    public private(set) var importFailures: [String] = []
    /// Summary of the last import (landed, already in the project, same file under another path, unreadable,
    /// unsupported, no sound). A view shows `summary` once it wants to; nothing here asks for attention by itself.
    public private(set) var lastImportReport: ImportReport?
    /// File names of the last import that were already in the project (skipped; the panel says so).
    public private(set) var alreadyInProject: [String] = []
    /// Files of the last imports whose video codec cannot be decoded here (file name, codec name).
    public private(set) var unsupportedImports: [(file: String, codec: String)] = []
    /// Called after an import when `unsupportedImports` is not empty (the view shows a dialog).
    public var onUnsupported: (@MainActor ([(file: String, codec: String)]) -> Void)?
    /// Plain-language reason per file of `importFailures` (`MediaDiagnosis`: empty file, interrupted recording, AVI, ...).
    public private(set) var importFailureReasons: [(file: String, reason: String)] = []
    /// Files of the last imports that imported without sound because their audio codec cannot be decoded (file, codec).
    public private(set) var audioDroppedImports: [(file: String, codec: String)] = []
    /// Called after an import when `audioDroppedImports` is not empty (the view shows a notice).
    public var onAudioDropped: (@MainActor ([(file: String, codec: String)]) -> Void)?
    public private(set) var offline: Set<MediaRef.ID> = []
    /// Counts for the Library's health line (in the project folder, outside it, offline); updated with `offline`.
    public private(set) var health = ProjectHealth()
    /// Bumped on every change the view must reload for.
    public private(set) var revision = 0

    @ObservationIgnored private let probe: Probe
    /// Weak-Mac part 2: probes (+ copies) of one import running at once (`WorkLimits.importProbes`; was every file).
    @ObservationIgnored private let probeLimiter: AsyncLimiter
    /// Files the folder sync could not read, by path, with the size and date they had. Session only.
    @ObservationIgnored private var failedProbes: [String: String] = [:]

    nonisolated static func fileSignature(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return "\((a[.size] as? NSNumber)?.int64Value ?? -1)-\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    /// Test seam: how many unreadable files the sync remembers.
    var rememberedFailureCount: Int { failedProbes.count }
    /// Applies a background change (files the folder watcher found) to the project and its whole history without an undo
    /// step (`EditorSession.amendProject`). Without it, the change is one undo step.
    @ObservationIgnored public var amend: (@MainActor (@escaping (inout Project) -> Void) -> Void)?
    /// The project folder, if the project lives in one: bin items removed while their file stays in it are remembered so
    /// the folder watcher does not add them again; importing such a file by hand forgets that.
    @ObservationIgnored public var projectFolder: (@MainActor () -> URL?)?
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    @ObservationIgnored private var offlineDirty = false
    /// Media that just landed in the bin at its original place (the clip is usable at once). The app decides what to do with
    /// files outside the project folder (ask, copy, move) and relinks later; `pointer` is where the drop happened (screen).
    @ObservationIgnored public var onImported: (@MainActor ([ImportedFile], _ pointer: CGPoint) -> Void)?

    /// A file that landed in the bin: its item and the path it was imported from.
    public struct ImportedFile: Sendable, Equatable {
        public var id: MediaRef.ID
        public var url: URL
    }
    @ObservationIgnored private let onEdit: EditHandler
    /// Edits that merge with the previous one of the same key into one undo step (`EditorSession.perform(coalescing:)`).
    /// When set, an import fills the bin while it probes (`ImportCommitPlan`); without it the import commits once at the end.
    @ObservationIgnored public var onCoalescingEdit: ((Project, String, String) -> Void)?
    /// Least time between two bin updates of one import (each reloads the grid).
    @ObservationIgnored public var importCommitInterval: Duration = .milliseconds(250)
    @ObservationIgnored private let status: @Sendable (MediaRef) -> MediaStatus
    /// Source Timecode column: reads the camera timecode of a file (header only). Replaceable in tests.
    @ObservationIgnored var timecodeReader: @Sendable (URL) -> SourceTimecode? = { try? SourceTimecode.read(from: $0) }
    /// Read results by media; `.some(nil)` = the file has none. Filled in the background, the column shows "" until then.
    @ObservationIgnored var sourceTimecodes: [MediaRef.ID: SourceTimecode?] = [:]
    @ObservationIgnored private var timecodeReads: Set<MediaRef.ID> = []

    /// Starts the one background read of `m`'s source timecode; the panel reloads when it lands.
    func requestSourceTimecode(_ m: MediaRef) {
        guard sourceTimecodes[m.id] == nil, timecodeReads.insert(m.id).inserted else { return }
        let url = URL(fileURLWithPath: m.path), read = timecodeReader, id = m.id
        Task { [weak self] in
            let tc = await Task.detached(priority: .utility) { read(url) }.value
            guard let self else { return }
            sourceTimecodes[id] = .some(tc)
            revision += 1
        }
    }
    /// Numbered PNG / TIFF frames picked together import as one clip (cached strip); this probes the frames in order.
    #if os(macOS)
    @ObservationIgnored var sequenceProbe: @Sendable ([URL]) async throws -> MediaRef = { try await MediaImporter.probeSequence($0).0 }
    #else
    @ObservationIgnored var sequenceProbe: @Sendable ([URL]) async throws -> MediaRef = { _ in throw MediaError.unsupportedCodec("image sequence") }
    #endif
    /// Fewest numbered files that count as a sequence (a few unrelated numbered screenshots stay separate stills).
    nonisolated static let minSequenceFrames = 4

    public init(project: Project,
                probe: @escaping Probe = ProjectPanelModel.platformProbe,
                status: @escaping @Sendable (MediaRef) -> MediaStatus = { $0.status() },
                probeLimit: Int = WorkLimits.current.importProbes,
                onEdit: @escaping EditHandler) {
        probeLimiter = AsyncLimiter(width: probeLimit)
        var p = project
        p.normalizeBins()
        self.project = p
        self.currentBin = p.rootBin.id
        self.browseBin = p.rootBin.id
        self.probe = probe
        self.status = status
        self.onEdit = onEdit
        refreshOffline()
    }

    public func setProject(_ p: Project) {
        var p = p
        p.normalizeBins()
        project = p
        if project.bin(currentBin) == nil { currentBin = project.rootBin.id }
        if project.bin(browseBin) == nil { browseBin = project.rootBin.id }
        scheduleOfflineRefresh()
        revision += 1
    }

    /// Re-checks the files of all media items. Offline means nothing is at the stored path.
    public func refreshOffline() {
        offline = Set(project.media.filter { status($0) == .missing }.map(\.id))
        health = ProjectHealth.make(media: project.media, offline: offline, projectFolder: projectFolder?())
        revision += 1
    }

    /// Same check as `refreshOffline`, with the file stats off the main actor. A burst of calls gives one pass now and
    /// at most one more right after it.
    public func scheduleOfflineRefresh() {
        offlineDirty = true
        guard offlineTask == nil else { return }
        offlineTask = Task { [weak self] in
            while let self, self.offlineDirty {
                self.offlineDirty = false
                let media = self.project.media, status = self.status, folder = self.projectFolder?()
                let (missing, health) = await Task.detached(priority: .utility) { () -> (Set<MediaRef.ID>, ProjectHealth) in
                    let gone = Set(media.filter { status($0) == .missing }.map(\.id))
                    return (gone, ProjectHealth.make(media: media, offline: gone, projectFolder: folder))
                }.value
                if self.offline != missing || self.health != health { self.offline = missing; self.health = health; self.revision += 1 }
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.offlineTask = nil
        }
    }

    public func isOffline(_ id: MediaRef.ID) -> Bool { offline.contains(id) }

    // MARK: Editing

    private func commit(_ name: String, coalescing key: String? = nil, _ body: (inout Project) -> Bool) -> Bool {
        var p = project
        guard body(&p), p != project else { return false }
        project = p
        revision += 1
        if let key, let onCoalescingEdit { onCoalescingEdit(p, name, key) } else { onEdit(p, name) }
        return true
    }

    // MARK: Smart bins

    /// Saves a filter as a smart bin (one undo step). Returns its ID, nil for an empty name.
    @discardableResult
    public func addSmartBin(_ bin: SmartBin) -> SmartBin.ID? {
        commit("New Smart Folder") { $0.addSmartBin(bin) } ? bin.id : nil
    }

    /// Smart Folder from what the header currently filters by (search text, Unused / Offline).
    public func currentFilterAsSmartBin(name: String) -> SmartBin {
        SmartBin(name: name, text: searchText.trimmingCharacters(in: .whitespaces),
                 usage: mediaFilter == .unused ? .unused : .any, offlineOnly: mediaFilter == .offline,
                 tokens: filterTokens.isEmpty ? nil : filterTokens, searchesSpoken: searchSpoken ? true : nil)
    }

    @discardableResult
    public func updateSmartBin(_ bin: SmartBin) -> Bool { commit("Edit Smart Folder") { $0.updateSmartBin(bin) } }

    @discardableResult
    public func removeSmartBin(_ id: SmartBin.ID) -> Bool {
        if activeSmartBin == id { activeSmartBin = nil }
        return commit("Delete Smart Folder") { $0.removeSmartBin(id) }
    }

    /// Media matching a smart bin, in project order.
    public func smartBinMedia(_ id: SmartBin.ID) -> [MediaRef.ID] {
        guard let bin = project.smartBin(id) else { return [] }
        let used = Set(project.timelines.flatMap { $0.tracks.flatMap { $0.clips.filter { !$0.isNested && !$0.isGenerator }.map(\.media) } })
        let spoken = bin.searchesSpoken == true ? project.mediaIDs(spoken: bin.text) : []
        return project.media.filter { bin.matches($0, isUsed: used.contains($0.id), isOffline: offline.contains($0.id), spoken: spoken) }.map(\.id)
    }

    /// 0...1 share of the media's length the sequences use; nil = length unknown.
    public func usedFraction(of id: MediaRef.ID) -> Double? { project.usedFraction(of: id) }

    /// Creates a bin in the current bin and returns its ID.
    @discardableResult
    public func newBin(name: String = "Folder") -> Bin.ID? {
        var id: Bin.ID?
        let parent = currentBin
        _ = commit("New Folder") { id = $0.newBin(name: name, in: parent); return id != nil }
        return id
    }

    @discardableResult
    public func rename(_ ref: BinItemRef, to name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return commit("Rename") { p in
            switch ref {
            case .bin(let id): return p.renameBin(id, to: name)
            case .media(let id):
                guard let i = p.media.firstIndex(where: { $0.id == id }) else { return false }
                p.media[i].name = name; return true
            case .sequence(let id):
                guard let i = p.timelines.firstIndex(where: { $0.id == id }) else { return false }
                p.timelines[i].name = name; return true
            }
        }
    }

    @discardableResult
    public func move(_ items: [BinItemRef], to dest: Bin.ID, at index: Int? = nil) -> Bool {
        // Dropping items on the bin they already sit in (no insertion position) is a no-op, not "move to the bottom".
        if index == nil, let d = project.bin(dest), items.allSatisfy({ r in d.children.contains { $0.ref == r } }) { return false }
        return commit("Move to Folder") { $0.move(items, to: dest, at: index) }
    }

    /// Sets the label of the media items and sequences in `items` (nil = back to the type default): one undo step.
    @discardableResult
    public func setLabel(_ label: LabelColor?, for items: [BinItemRef]) -> Bool {
        commit("Change Label") { $0.setLabel(label, for: items) }
    }

    /// Label color shown for an item.
    public func label(of ref: BinItemRef) -> LabelColor { project.label(of: ref) }

    /// What `delete` did. `blockedBy` lists the sequence names that kept items from being deleted: sequences that still
    /// use a media item, or that nest a sequence (each name once, project order). `message` is the status line for it.
    public struct DeleteResult: Sendable, Equatable {
        public var changed = false
        public var blockedBy: [String] = []
        public var blockedItems = 0
        /// Media still used by a sequence that `clear` made offline instead of deleting (clips stay).
        public var offlined = 0
        public var message: String? {
            guard blockedItems > 0 else {
                return offlined > 0 ? "\(offlined) item\(offlined == 1 ? " is" : "s are") offline now: the clips stay, Relink attaches a file." : nil
            }
            let names = blockedBy.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + (blockedBy.count > 3 ? " and more" : "")
            return blockedBy.isEmpty ? "The last sequence cannot be deleted." : "Not deleted: still used in \(names)."
        }
    }

    /// Undo name of a delete: "Delete Folder" for exactly one bin, otherwise "Delete Items".
    public static func deleteName(for items: [BinItemRef]) -> String {
        if items.count == 1, case .bin = items[0] { return "Delete Folder" }
        return "Delete Items"
    }

    /// Deletes bins (their content moves up), media not used by any sequence, and sequences (never the last one, nor one
    /// that another sequence nests). The root bin is kept. One undo step. Items that are in use stay and their sequence
    /// names come back in `blockedBy`.
    @discardableResult
    public func delete(_ items: [BinItemRef]) -> DeleteResult { remove(items, offlineUsed: false) }

    /// Clear: like `delete`, but media a sequence still uses is not blocked: it goes offline and its clips stay on the
    /// timelines (`Project.makeOffline`, `DeleteResult.offlined`). Unused items and bins are deleted. One undo step.
    @discardableResult
    public func clear(_ items: [BinItemRef]) -> DeleteResult { remove(items, offlineUsed: true) }

    private func remove(_ items: [BinItemRef], offlineUsed: Bool) -> DeleteResult {
        var result = DeleteResult()
        let folder = projectFolder?()
        func block(_ names: [String]) {
            result.blockedItems += 1
            for n in names where !result.blockedBy.contains(n) { result.blockedBy.append(n) }
        }
        result.changed = commit(offlineUsed ? "Clear Items" : Self.deleteName(for: items)) { p in
            var changed = false
            for r in items {
                switch r {
                case .bin(let id): if p.deleteBin(id) { changed = true }
                case .media(let id):
                    guard p.media.contains(where: { $0.id == id }) else { continue }
                    let users = p.sequenceNames(using: id)
                    if !users.isEmpty {
                        guard offlineUsed else { block(users); continue }
                        if let folder, let m = p.media.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: m.path) {
                            p.ignoreFolderFile(m.path, projectFolder: folder)
                        }
                        if p.makeOffline(id) { result.offlined += 1; changed = true }
                        continue
                    }
                    // The file stays in the project folder: the watcher must not add it back.
                    if let folder, let m = p.media.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: m.path) {
                        p.ignoreFolderFile(m.path, projectFolder: folder)
                    }
                    p.media.removeAll { $0.id == id }
                    p.sourceMarks[id] = nil
                    p.normalizeBins()
                    changed = true
                case .sequence(let id):
                    let nesting = p.sequenceNames(nesting: id)
                    if p.deleteSequence(id) { changed = true } else { block(nesting) }
                }
            }
            return changed
        }
        return result
    }

    // MARK: Hover marks (I / O over a thumbnail)

    /// `I` (`isIn`) or `O` while hover scrubbing at `time`: writes the media's Source marks like the Source monitor does
    /// (Out includes its own frame, so it is stored one frame later). Returns false for unknown media.
    @discardableResult
    public func markFromHover(isIn: Bool, media id: MediaRef.ID, time: Time) -> Bool {
        guard let ref = project.media(id) else { return false }
        let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
        return commit(isIn ? "Mark In" : "Mark Out") { p in
            if isIn { p.setSourceIn(time, for: id) } else { p.setSourceOut(time + fd, for: id) }
            return true
        }
    }

    // MARK: Find (Cmd+F)

    /// Find criteria of the Project panel: text in the name (or label name) and/or offline items only.
    public struct FindCriteria: Sendable, Equatable {
        public enum Field: String, Sendable, CaseIterable { case name, label }
        public var text = ""
        public var field: Field = .name
        public var offlineOnly = false
        public init(text: String = "", field: Field = .name, offlineOnly: Bool = false) {
            self.text = text; self.field = field; self.offlineOnly = offlineOnly
        }
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !offlineOnly }
    }

    /// Items (media and sequences, in tree order, bins skipped) that match all criteria. Empty criteria match nothing.
    public func find(_ c: FindCriteria) -> [BinItemRef] {
        guard !c.isEmpty else { return [] }
        let q = c.text.trimmingCharacters(in: .whitespaces)
        var out: [BinItemRef] = []
        func walk(_ bin: Bin) {
            for child in bin.children {
                if case .bin(let b) = child { walk(b); continue }
                let ref = child.ref
                if c.offlineOnly {
                    guard case .media(let id) = ref, offline.contains(id) else { continue }
                }
                if !q.isEmpty {
                    let hay = c.field == .name ? project.displayName(of: ref) : project.label(of: ref).displayName
                    guard hay.localizedCaseInsensitiveContains(q) else { continue }
                }
                out.append(ref)
            }
        }
        walk(project.rootBin)
        return out
    }

    // MARK: Poster frame (Cmd+P / Option+P)

    /// Sets (or with nil clears) the poster frame of media items: one undo step. Items that are not media are skipped.
    @discardableResult
    public func setPoster(_ time: Time?, for items: [BinItemRef]) -> Bool {
        commit(time == nil ? "Clear Poster Frame" : "Set Poster Frame") { p in
            var changed = false
            for r in items { if case .media(let id) = r, p.setPosterTime(time, for: id) { changed = true } }
            return changed
        }
    }

    // MARK: Pixel aspect (F7.3)

    /// Source settings > Pixel Aspect for media items (nil = what the file says): one undo step. Monitors, thumbnails and
    /// export follow; clips keep their Scale. Items that are not media, or have no picture, are skipped.
    @discardableResult
    public func setPixelAspect(_ aspect: PixelAspect?, for items: [BinItemRef]) -> Bool {
        commit("Set Pixel Aspect") { p in
            var changed = false
            for r in items { if case .media(let id) = r, p.setPixelAspect(aspect, for: id) { changed = true } }
            return changed
        }
    }

    /// Source settings > Audio Channels for media items (nil = the file's layout): one undo step. Playback, export and
    /// waveforms follow. Items that are not media, or have no sound, are skipped.
    @discardableResult
    public func setAudioChannels(_ map: AudioChannelMap?, for items: [BinItemRef]) -> Bool {
        commit("Set Audio Channels") { p in
            var changed = false
            for r in items { if case .media(let id) = r, p.setAudioChannelMap(map, for: id) { changed = true } }
            return changed
        }
    }

    // MARK: Deinterlace

    /// The Deinterlace row is offered when every selected item is interlaced media: true = on for all of them.
    public func deinterlaceState(_ media: [MediaRef.ID]) -> Bool? {
        let states = media.compactMap { project.deinterlace(of: $0) }
        guard !media.isEmpty, states.count == media.count else { return nil }
        return states.allSatisfy { $0 }
    }

    /// Source settings > Deinterlace for media items: one undo step. Monitors and export follow; progressive media and
    /// items that are not media are skipped.
    @discardableResult
    public func setDeinterlace(_ on: Bool, for items: [BinItemRef]) -> Bool {
        commit("Set Deinterlace") { p in
            var changed = false
            for r in items { if case .media(let id) = r, p.setDeinterlace(on, for: id) { changed = true } }
            return changed
        }
    }

    // MARK: Import

    /// Media ID for a file handed to `importFiles` (its copy in Files, or the file itself), nil if it was not imported.
    public func mediaID(forImported url: URL) -> MediaRef.ID? {
        importedIDs[url.path] ?? project.media.first { $0.path == url.path }?.id
    }
    @ObservationIgnored private var importedIDs: [String: MediaRef.ID] = [:]

    /// Probes `urls` in the background and files the new items in the current bin as one undo step.
    /// Files already in the project (same path) are skipped; unreadable files end up in `importFailures`.
    /// With `onCoalescingEdit` set, the bin fills while the import runs (in input order, `ImportCommitPlan`): a folder
    /// of hundreds of clips shows its first item at once instead of after the last probe; still one undo step.
    public func importFiles(_ urls: [URL]) async {
        let known = Set(project.media.map(\.path))
        var seen = Set<String>()
        var todo = urls.filter { !known.contains($0.path) && seen.insert($0.path).inserted }
        alreadyInProject = urls.filter { known.contains($0.path) }.map(\.lastPathComponent)
        // Another path to a file that is in the project already (or earlier in this batch) is not imported twice.
        // shortcut: stats every project item once per import that has reachable files; upgrade to a cached identity
        // index on `project.media` when a 10k-item project makes this visible.
        var duplicateNames: [String] = []
        let identities = todo.map { Self.fileIdentity($0) }
        if identities.contains(where: { $0 != nil }) {
            var taken = Set(project.media.compactMap { Self.fileIdentity(URL(fileURLWithPath: $0.path)) })
            var keep: [URL] = []
            for (url, id) in zip(todo, identities) {
                if let id, !taken.insert(id).inserted { duplicateNames.append(url.lastPathComponent) } else { keep.append(url) }
            }
            todo = keep
        }
        var report = ImportReport()
        report.alreadyInProject = alreadyInProject
        report.duplicates = duplicateNames
        if !urls.isEmpty { importFailures = []; importFailureReasons = []; importCanceled = nil }
        if !alreadyInProject.isEmpty || !duplicateNames.isEmpty { revision += 1 }
        // Numbered frames collapse into their first file; its probe renders the whole run.
        var found: [String: [URL]] = [:]
        for g in Self.imageSequences(in: todo) { found[g[0].path] = g }
        if !found.isEmpty {
            let drop = Set(found.values.flatMap { $0.dropFirst() }.map(\.path))
            todo.removeAll { drop.contains($0.path) }
        }
        let sequences = found
        let sequenceProbe = self.sequenceProbe
        guard !todo.isEmpty else {
            if !urls.isEmpty { lastImportReport = report }
            return
        }
        importFailures = []
        pendingImports += todo.count
        importTotal += todo.count
        let token = ImportCancelToken()
        let tokenKey = UUID().uuidString
        importTokens[tokenKey] = token
        let probe = self.probe, limiter = self.probeLimiter
        let progressive = onCoalescingEdit != nil
        let key = "import-" + UUID().uuidString
        let startBin = currentBin
        var plan = ImportCommitPlan(count: todo.count, interval: importCommitInterval)
        var results = [(URL, MediaRef?)?](repeating: nil, count: todo.count)
        var unsupportedAt: [(index: Int, file: String, codec: String)] = []
        var reasons: [Int: String] = [:]
        var audioDropped: [(index: Int, file: String, codec: String)] = []
        var landed = 0
        var landedFiles: [ImportedFile] = []
        let pointer = Self.currentPointer()

        func land(_ range: Range<Int>) {
            let batch = range.compactMap { i -> (URL, MediaRef)? in
                guard let (url, ref) = results[i], let ref else { return nil }
                return (url, ref)
            }
            // Imported files may live elsewhere now (Files folder): callers look the item up by the URL they passed.
            for (url, ref) in batch { importedIDs[url.path] = project.media.first { $0.path == ref.path }?.id ?? ref.id }
            guard !batch.isEmpty else { return }
            landed += batch.count
            let refs = batch.map(\.1)
            let dest = progressive ? startBin : currentBin
            let folder = projectFolder?()
        _ = commit(landed == 1 ? "Import Media" : "Import \(landed) Media Items", coalescing: progressive ? key : nil) { p in
                if let folder { for r in refs { p.unignoreFolderFile(r.path, projectFolder: folder) } }
                // Another import of the same file may have finished while this one probed.
                let present = Set(p.media.map(\.path))
                let fresh = refs.filter { !present.contains($0.path) }
                for (url, ref) in batch { importedIDs[url.path] = p.media.first { $0.path == ref.path }?.id ?? ref.id }
                guard !fresh.isEmpty else { return false }
                for r in fresh { p.add(r) }
                for (url, ref) in batch where ref.path == url.path && fresh.contains(where: { $0.id == ref.id }) {
                    landedFiles.append(ImportedFile(id: ref.id, url: url))
                }
                if p.bin(dest) != nil, dest != p.rootBin.id { p.move(fresh.map { .media($0.id) }, to: dest) }
                return true
            }
        }

        var skipped = 0
        await withTaskGroup(of: (Int, URL, MediaRef?, String?, Bool, String?).self) { group in
            for (i, url) in todo.enumerated() {
                group.addTask { await limiter.run {
                    if token.isCanceled { return (i, url, nil, nil, true, nil) }      // canceled before its turn: not probed
                    // Probe the original first: a file that cannot be read is never copied, moved or trashed.
                    do {
                        let ref: MediaRef
                        if let frames = sequences[url.path] { ref = try await sequenceProbe(frames) } else { ref = try await probe(url) }
                        return (i, url, ref, nil, false, nil)
                    }
                    catch MediaError.unsupportedCodec(let codec) { return (i, url, nil, codec, false, nil) }
                    catch { return (i, url, nil, nil, false, Self.failureReason(for: url, error: error)) }
                } }
            }
            for await (i, url, ref, codec, wasSkipped, reason) in group {
                if wasSkipped { skipped += 1 } else { results[i] = (url, ref) }
                if let reason { reasons[i] = reason }
                if ref != nil, let c = Self.takeAudioDropped(url) { audioDropped.append((i, url.lastPathComponent, c)) }
                if let codec { unsupportedAt.append((i, url.lastPathComponent, codec)) }
                pendingImports -= 1
                if progressive, let r = plan.finished(i, at: .now) { land(r) }
            }
        }
        if progressive { if let r = plan.flush() { land(r) } } else { land(0..<todo.count) }
        importTokens[tokenKey] = nil
        if importTokens.isEmpty { importTotal = 0 }
        if skipped > 0 { importCanceled = (landed, todo.count) }

        let unsupported = unsupportedAt.sorted { $0.index < $1.index }.map { (file: $0.file, codec: $0.codec) }
        unsupportedImports = unsupported
        importFailures = results.compactMap { $0 }.filter { $0.1 == nil }.map { $0.0.lastPathComponent }
            .filter { n in !unsupported.contains { $0.file == n } }
        importFailureReasons = todo.enumerated().compactMap { i, u in reasons[i].map { (u.lastPathComponent, $0) } }
        audioDroppedImports = audioDropped.sorted { $0.index < $1.index }.map { (file: $0.file, codec: $0.codec) }
        report.imported = landed
        report.canceled = skipped > 0
        report.failed = importFailureReasons.map { ImportReport.Entry(file: $0.file, detail: $0.reason) }
        // A failure without a reason (a probe that returned nothing) still counts as unreadable.
        for n in importFailures where !report.failed.contains(where: { $0.file == n }) {
            report.failed.append(ImportReport.Entry(file: n, detail: "Could not be read."))
        }
        report.unsupported = unsupported.map { ImportReport.Entry(file: $0.file, detail: $0.codec) }
        report.audioDropped = audioDroppedImports.map { ImportReport.Entry(file: $0.file, detail: $0.codec) }
        lastImportReport = report
        if !unsupported.isEmpty { onUnsupported?(unsupported) }
        if !audioDroppedImports.isEmpty { onAudioDropped?(audioDroppedImports) }
        guard landed > 0 else { revision += 1; return }
        scheduleOfflineRefresh()
        if !landedFiles.isEmpty { onImported?(landedFiles, pointer) }
    }

    private static func currentPointer() -> CGPoint {
        #if os(macOS)
        NSEvent.mouseLocation
        #else
        .zero   // shortcut: no pointer position off the Mac; upgrade with the Windows shell's cursor position.
        #endif
    }

    // The platform side of an import (SQMedia's Mac importer). shortcut: off the Mac nothing probes, no duplicate file
    // identity, no image sequence grouping, no diagnosis; upgrade with the FFmpeg probe (SQMediaFFmpeg).
    #if os(macOS)
    nonisolated public static let platformProbe: Probe = { try await MediaImporter.probe($0).0 }
    nonisolated static func fileIdentity(_ url: URL) -> AnyHashable? { MediaFileOps.fileIdentity(url) }
    nonisolated static func imageSequences(in urls: [URL]) -> [[URL]] { ImageSequence.groups(in: urls, minCount: minSequenceFrames) }
    nonisolated static func failureReason(for url: URL, error: any Error) -> String? { MediaDiagnosis.reason(for: url, error: error) }
    nonisolated static func takeAudioDropped(_ url: URL) -> String? { ImportNotes.takeAudioDropped(url) }
    #else
    nonisolated public static let platformProbe: Probe = { _ in throw MediaError.unsupportedCodec("probe") }
    nonisolated static func fileIdentity(_ url: URL) -> AnyHashable? { nil }
    nonisolated static func imageSequences(in urls: [URL]) -> [[URL]] { [] }
    nonisolated static func failureReason(for url: URL, error: any Error) -> String? { nil }
    nonisolated static func takeAudioDropped(_ url: URL) -> String? { nil }
    #endif

    // MARK: Project folder sync

    /// Probes files that appeared in the project folder and files them, linked in place (no copy), into bins that mirror
    /// their folders: one undo step. Unreadable files are skipped silently (a scan will see them again). Returns the number added.
    @discardableResult
    /// `stillValid` is asked again after the probes: false (another project opened, watching restarted) drops the result.
    public func importSynced(_ adds: [FolderSyncAdd], stillValid: @MainActor () -> Bool = { true }) async -> Int {
        let known = Set(project.media.map(\.path))
        let todo = adds.filter { !known.contains($0.path) }
        guard !todo.isEmpty else { return 0 }
        let probe = self.probe, limiter = self.probeLimiter, failedBefore = failedProbes
        var results: [(MediaRef, [String])] = []
        var newFailures: [String: String] = [:]
        await withTaskGroup(of: (Int, MediaRef?, String?).self) { group in
            for (i, add) in todo.enumerated() {
                group.addTask {
                    // A file that failed to probe is tried again only when its size or modification date changed.
                    let sig = Self.fileSignature(add.path)
                    if let sig, failedBefore[add.path] == sig { return (i, nil, nil) }
                    let ref = await limiter.run { try? await probe(URL(fileURLWithPath: add.path)) }
                    // A probe that stopped because the work was canceled says nothing about the file.
                    return (i, ref, ref == nil && !Task.isCancelled ? sig : nil)
                }
            }
            var byIndex: [Int: MediaRef] = [:]
            for await (i, ref, failedSig) in group {
                if let ref { byIndex[i] = ref }
                if let failedSig { newFailures[todo[i].path] = failedSig }
            }
            for i in byIndex.keys.sorted() { results.append((byIndex[i]!, todo[i].bin)) }
        }
        guard stillValid() else { return 0 }
        failedProbes.merge(newFailures) { _, new in new }
        guard !results.isEmpty else { return 0 }
        let items = results.map { (ref: $0.0, bin: $0.1) }
        let binIDs = Project.newBinIDs(for: items)          // once, so every history state gets the same bin ids
        var added = 0
        if let amend {
            // Files the watcher found are not an edit: no undo step, redo stays, every history state knows them.
            amend { added = max(added, $0.addSynced(items, newBinIDs: binIDs)) }
        } else {
            _ = commit(results.count == 1 ? "Add Project Folder File" : "Add \(results.count) Project Folder Files") { p in
                added = p.addSynced(items, newBinIDs: binIDs)
                return added > 0
            }
        }
        scheduleOfflineRefresh()
        return added
    }

    /// Status line for files that were skipped because they are in the project already.
    public static func alreadyText(_ names: [String]) -> String {
        names.count == 1 ? "“\(names[0])” is already in the project." : "\(names.count) files are already in the project."
    }

    /// Status line for files that could not be read: the first three names, then a count.
    public static func failureText(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return "Could not read: " + shown + (names.count > 3 ? " and \(names.count - 3) more." : "")
    }

    /// Status line for failed imports: one file names its reason, several list the names (reasons are in the tooltip).
    public static func failureStatus(_ items: [(file: String, reason: String)], names: [String]) -> String {
        if items.count == 1, names.count == 1 { return "\(items[0].file): \(items[0].reason)" }
        return failureText(names)
    }

    /// One line per failed file with its reason (status row tooltip).
    public static func failureDetail(_ items: [(file: String, reason: String)]) -> String {
        items.map { "\($0.file): \($0.reason)" }.joined(separator: "\n")
    }

    /// Camera-card and editor files next to the footage that are not media (thumbnails, XML, XMP, indexes, text):
    /// a folder import skips them silently instead of listing each as unreadable.
    public static func isSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        return sidecarExtensions.contains(url.pathExtension.lowercased())
    }
    private static let sidecarExtensions: Set<String> = [
        "thm", "xml", "xmp", "txt", "json", "bim", "idx", "ctg", "sif", "mpl", "cpi", "bdm", "pdf", "html", "htm", "plist",
        "log", "csv", "ale", "edl", "md", "ini", "db", "lrf", "ds_store", "url", "zip",
    ]

    // MARK: Import project

    /// Why the last project import failed (title, plain-language detail); nil when it worked or none ran.
    public private(set) var projectImportError: (title: String, detail: String)?
    /// Names of the projects imported in the last call.
    public private(set) var importedProjectNames: [String] = []

    /// Imports other Sequence Studio projects (`.sqproj`, legacy `.ssproj`) as one bin each into the current bin, with
    /// all their media, sequences and bins, as one undo step. The current sequence is left alone. A project that cannot
    /// be read sets `projectImportError` (a human-readable reason) and the others still import.
    public func importProjects(_ urls: [URL]) async {
        projectImportError = nil
        importedProjectNames = []
        var loaded: [(url: URL, project: Project)] = []
        for url in urls {
            do {
                let p = try await Task.detached(priority: .userInitiated) { try ProjectMerge.load(from: url) }.value
                loaded.append((url, p))
            } catch {
                SQLog.error("project import failed: \(url.path): \(error)")
                projectImportError = ProjectMerge.message(for: error, fileName: url.lastPathComponent)
            }
        }
        guard !loaded.isEmpty else { revision += 1; return }
        let dest = currentBin
        let names = loaded.map { $0.project.name.isEmpty ? $0.url.deletingPathExtension().lastPathComponent : $0.project.name }
        let label = loaded.count == 1 ? "Import Project “\(names[0])”" : "Import \(loaded.count) Projects"
        let done = commit(label) { p in
            let into = p.bin(dest) != nil ? dest : p.rootBin.id
            var any = false
            for (i, l) in loaded.enumerated() {
                if p.merge(l.project, binName: names[i], into: into, sourceFolder: l.url.deletingLastPathComponent()) != nil { any = true }
            }
            return any
        }
        if done { importedProjectNames = names }
        revision += 1
        scheduleOfflineRefresh()
    }

    // MARK: Display (sort + filter are display-only)

    public func setSort(_ column: Column?, ascending: Bool) {
        sortColumn = column; sortAscending = ascending; revision += 1
    }

    /// Children of `bin` as shown: filtered by the search text, sorted by the active column (bins first).
    public func children(of bin: Bin) -> [BinItem] {
        var q = searchText.trimmingCharacters(in: .whitespaces)
        // A bin whose own name matches shows its full content.
        if !q.isEmpty, bin.id != project.rootBin.id, bin.name.localizedCaseInsensitiveContains(q) { q = "" }
        if let sb = activeSmartBin, project.smartBin(sb) != nil {
            guard bin.id == project.rootBin.id else { return [] }
            return smartBinMedia(sb).map { BinItem.media($0) }.filter { (q.isEmpty || matches($0, q)) && passesFilter($0) }
        }
        if grouping != .folders {
            if let g = groupBins[bin.id], project.bin(bin.id) == nil { return g.children }
            guard bin.id == project.rootBin.id else { return [] }
            return groupedRoot(q)
        }
        var items = bin.children
        if !q.isEmpty { items = items.filter { matches($0, q) } }
        if mediaFilter != .all || !filterTokens.isEmpty { items = items.filter { passesFilter($0) } }
        guard let col = sortColumn else { return items }
        func rank(_ i: BinItem) -> Int { if case .bin = i.ref { 0 } else { 1 } }
        func key(_ i: BinItem) -> String {
            switch (col, i) {
            case (.name, _): return displayName(of: i.ref)
            case (.duration, .media(let id)): return String(format: "%020.6f", project.media(id)?.duration.map(Self.seconds) ?? 0)
            case (.frameRate, .media(let id)):
                return String(format: "%020.6f", project.media(id)?.info?.video.map { 1 / Self.seconds($0.nominalFrameDuration) } ?? 0)
            default: return cellText(col, i.ref)
            }
        }
        let keys = items.map(key)
        let order = items.indices.sorted { l, r in
            let a = items[l], b = items[r]
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let c = keys[l].localizedStandardCompare(keys[r])
            if c == .orderedSame { return l < r }
            return (c == .orderedAscending) == sortAscending
        }
        return order.map { items[$0] }
    }

    /// Media: unused / offline as chosen, and every token. Folders stay when anything inside passes. Sequences are hidden
    /// by a filter.
    private func passesFilter(_ item: BinItem) -> Bool {
        switch item {
        case .bin(let b): return b.children.contains { passesFilter($0) }
        case .media(let id):
            switch mediaFilter {
            case .all: break
            case .unused: if !project.sequenceNames(using: id).isEmpty { return false }
            case .offline: if !isOffline(id) { return false }
            }
            guard !filterTokens.isEmpty else { return true }
            guard let m = project.media(id) else { return false }
            return MediaFilterQuery(tokens: filterTokens).matches(m, isUsed: !project.sequenceNames(using: id).isEmpty)
        default: return false
        }
    }

    /// Root of the "Sorted by" view: one header per group (folders are flattened away), media filtered like the folder view.
    private func groupedRoot(_ q: String) -> [BinItem] {
        let shown = project.media.filter { m in
            let item = BinItem.media(m.id)
            return (q.isEmpty || matches(item, q)) && passesFilter(item)
        }
        let groups = grouping.groups(of: shown)
        groupBins = [:]
        return groups.map { g in
            let id = Self.groupID(grouping, g.id)
            let bin = Bin(id: id, name: g.title, children: g.items.map { BinItem.media($0) })
            groupBins[id] = bin
            return BinItem.bin(bin)
        }
    }

    private func matches(_ item: BinItem, _ q: String) -> Bool {
        switch item {
        case .bin(let b):
            return b.name.localizedCaseInsensitiveContains(q) || b.children.contains { matches($0, q) }
        default:
            if displayName(of: item.ref).localizedCaseInsensitiveContains(q) { return true }
            if searchSpoken, case .media(let id) = item { return spokenMatches(q).contains(id) }
            return false
        }
    }

    /// Media with the words `q` in their captions, kept per project revision and text so typing stays cheap.
    private func spokenMatches(_ q: String) -> Set<MediaRef.ID> {
        if let c = spokenCache, c.revision == revision, c.text == q { return c.ids }
        let ids = project.mediaIDs(spoken: q)
        spokenCache = (revision, q, ids)
        return ids
    }
    private var spokenCache: (revision: Int, text: String, ids: Set<MediaRef.ID>)?

    // MARK: Formatting

    public static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    public static func codecName(_ fourCC: String) -> String {
        switch fourCC {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "apch": "ProRes 422 HQ"
        case "apcn": "ProRes 422"
        case "apcs": "ProRes 422 LT"
        case "apco": "ProRes 422 Proxy"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "av01": "AV1"
        case "vp09": "VP9"
        default: fourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Item info for a variable-frame-rate clip (phone and screen recordings): its frames are not evenly spaced, so
    /// picture can drift against audio. nil for constant-rate clips and files without picture. Conforming (re-encoding
    /// to a constant rate) is offered in the text; it is not a command yet.
    public static func variableFrameRateNote(_ m: MediaRef) -> String? {
        guard m.info?.isStill != true, m.info?.video?.isVariableFrameRate == true else { return nil }
        return "Variable frame rate: picture can drift against audio. Conform the clip to a constant rate before editing."
    }

    /// "3840×2160 29.97 H.264 4:2:2 10-bit"; audio-only: "48 kHz 2 ch AAC"; "" without probe info.
    public static func formatString(_ m: MediaRef) -> String {
        if let v = m.info?.video {
            let fps = Double(v.nominalFrameDuration.timescale) / Double(v.nominalFrameDuration.value)
            var f = String(format: "%.2f", fps)
            while f.hasSuffix("0") { f.removeLast() }
            if f.hasSuffix(".") { f.removeLast() }
            if m.info?.isStill == true { return "\(v.displayWidth)×\(v.displayHeight) Still image" }
            return "\(v.displayWidth)×\(v.displayHeight) \(f)\(v.isVariableFrameRate ? " VFR" : "") \(codecName(v.codec)) \(v.chroma) \(v.bitDepth)-bit"
        }
        if let a = m.info?.audio {
            var khz = String(format: "%.1f", Double(a.sampleRate) / 1000)
            if khz.hasSuffix(".0") { khz.removeLast(2) }
            return "\(khz) kHz \(a.channels) ch \(a.codec.trimmingCharacters(in: .whitespaces))"
        }
        return ""
    }

    /// Short Format cell (board `.tr`): the log profile when the file is log ("S-Log3"), else the picture size; audio-only
    /// files show the sample rate ("44.1 kHz"). `formatString` is the whole line.
    public static func formatLabel(_ m: MediaRef) -> String {
        if let v = m.info?.video {
            if let cs = m.info?.detectedColorSpace, cs.isLog || cs.isHDR {
                return String(cs.displayName.split(separator: "/").first ?? "").trimmingCharacters(in: .whitespaces)
            }
            return "\(v.displayWidth)×\(v.displayHeight)"
        }
        if let a = m.info?.audio {
            var khz = String(format: "%.1f", Double(a.sampleRate) / 1000)
            if khz.hasSuffix(".0") { khz.removeLast(2) }
            return "\(khz) kHz"
        }
        return ""
    }

    /// "9:16" for 1080×1920; "" for an empty size.
    public static func aspectLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height)
        return "\(width / g):\(height / g)"
    }

    /// HH:MM:SS:FF (non-drop, frame rate rounded); audio-only HH:MM:SS; "" when unknown.
    public static func durationString(_ m: MediaRef) -> String {
        guard let d = m.duration ?? m.info?.duration, !d.isNegative else { return "" }
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if let fd = m.info?.video?.nominalFrameDuration, fd.value > 0 {
            let fps = max(1, Int64((Double(fd.timescale) / Double(fd.value)).rounded()))
            let frames = d.frameIndex(frameDuration: fd)
            let s = frames / fps
            return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60)):\(two(frames % fps))"
        }
        let s = d.value / d.timescale
        return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60))"
    }

    // MARK: Pasteboard

    /// Custom pasteboard type carrying item IDs.
    nonisolated public static let pasteboardTypeName = "com.sequencestudio.media-ids"

    public static func encodeItems(_ refs: [BinItemRef]) -> String {
        refs.map { r in
            switch r {
            case .bin(let id): "b:\(id.uuidString)"
            case .media(let id): "m:\(id.uuidString)"
            case .sequence(let id): "s:\(id.uuidString)"
            }
        }.joined(separator: "\n")
    }

    public static func decodeItems(_ s: String) -> [BinItemRef] {
        s.split(separator: "\n").compactMap { line in
            guard line.count > 2, let id = UUID(uuidString: String(line.dropFirst(2))) else { return nil }
            switch line.prefix(2) {
            case "b:": return .bin(id)
            case "m:": return .media(id)
            case "s:": return .sequence(id)
            default: return nil
            }
        }
    }
}

/// Shared flag between `cancelImport` and the probe tasks of one import call.
private final class ImportCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
}
