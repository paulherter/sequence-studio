import AppKit
import SQCore
import SQEditorUI
import SQLibrary
import SQMedia

/// Media management at the project folder: the prompt for outside media after a drop, the background copies that relink
/// the clips, library items into `Files/Library/`, the project folder watcher and the "outside the project folder" hint.
/// File work never runs on the main actor; the clip is usable at once and is relinked when its copy is verified.
/// Relinks and watcher syncs are history-neutral (no undo step); a Move trashes its original only after a save.
@MainActor
final class MediaPlacementController {
    weak var owner: AppController?
    /// Tokens, generation, scan memory, prompt queue and waiting relinks: see `MediaWorkState` (tested there).
    let state = MediaWorkState()
    private let prompt = MediaPlacementPrompt()
    private var token: (any FolderWatchToken)?
    private var syncTimer: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var copyWorks: [UUID: Task<[Outcome], Never>] = [:]
    private var relinkPoll: Task<Void, Never>?
    /// Moves whose original is trashed after the next save that contains the copy's path.
    private var pendingMoves: [PendingMove] = []
    /// Files the app made itself (voiceover, pasted image): never asked about, never moved or trashed.
    private var generated: Set<String> = []

    private struct Outcome: Sendable {
        var file: ProjectPanelModel.ImportedFile
        var result: MediaFileOps.Result?
        var viaLink = false
        var failure: String?
        var copy: URL? { result?.url }
    }

    private struct SyncJob: Sendable {
        var plan: [FolderSyncAdd]
        var seen: [MediaManagement.SeenFile]
        var unsettled: Bool
        var frames: Set<String>
    }

    /// Changes whenever a project opens or the app quits; background work from before it must not touch the new state.
    var epoch: Int { state.generation }

    private struct Sorted: Sendable {
        var ask: [ProjectPanelModel.ImportedFile] = []
        var library: [ProjectPanelModel.ImportedFile] = []
        var generated: [ProjectPanelModel.ImportedFile] = []
        var apply: [ImportMode: [ProjectPanelModel.ImportedFile]] = [:]
    }

    init() { state.onIdle = { [weak self] in self?.scheduleSync() } }

    /// The watcher waits while `true` (card import, Collect Files).
    func setPaused(_ on: Bool) {
        if on { state.pause() } else { state.resume() }
    }

    func markGenerated(_ urls: [URL]) { generated.formUnion(urls.map(\.path)) }

    // MARK: Landed files

    /// Called once per import with the files that landed (at their original place) and the pointer position.
    func imported(_ files: [ProjectPanelModel.ImportedFile], pointer: CGPoint) {
        guard let owner, let projectURL = owner.session.fileURL, !files.isEmpty else { return }
        let project = owner.session.project
        let defaults = MediaSettings.defaults
        let libraryFolders = owner.panels.libraryModel.folders.map(\.folder.url)
        let copyLibrary = MediaManagement.copiesLibraryItems(project, projectURL: projectURL, defaults: defaults)
        let own = generated
        generated.subtract(files.map(\.url.path))
        let projectID = project.id
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                Self.classify(files, project: project, projectURL: projectURL, defaults: defaults,
                              libraryFolders: libraryFolders, copyLibrary: copyLibrary, generated: own)
            }.value
            self?.apply(sorted, projectID: projectID, pointer: pointer, projectURL: projectURL)
        }
    }

    private nonisolated static func classify(_ files: [ProjectPanelModel.ImportedFile], project: Project, projectURL: URL,
                                             defaults: MediaPolicyDefaults, libraryFolders: [URL], copyLibrary: Bool,
                                             generated: Set<String>) -> Sorted {
        var out = Sorted()
        for f in files {
            if libraryFolders.contains(where: { MediaManagement.isInside(f.url.path, folder: $0) }) {
                if copyLibrary { out.library.append(f) }
                continue                                           // library items never ask
            }
            let disposition = MediaManagement.disposition(forPath: f.url.path, project: project, projectURL: projectURL, defaults: defaults)
            if generated.contains(f.url.path) {
                if case .link = disposition { continue }
                out.generated.append(f)
                continue
            }
            switch disposition {
            case .link: break
            case .ask: out.ask.append(f)
            case .apply(let mode): out.apply[mode, default: []].append(f)
            }
        }
        return out
    }

    private func apply(_ s: Sorted, projectID: UUID, pointer: CGPoint, projectURL: URL) {
        guard let owner, owner.session.project.id == projectID else { return }
        if !s.library.isEmpty { copyLibraryItems(s.library, projectURL: projectURL) }
        if !s.generated.isEmpty, MediaManagement.projectFolder(forProjectAt: projectURL) != nil {
            place(s.generated, mode: .copy)                        // silent copy, the original stays
        }
        for (mode, list) in s.apply { place(list, mode: mode) }
        if !s.ask.isEmpty { askAbout(s.ask, pointer: pointer) }
    }

    private func askAbout(_ files: [ProjectPanelModel.ImportedFile], pointer: CGPoint) {
        state.pendingAsk += files
        guard !prompt.isShown, let window = owner?.window else { return }
        let gen = state.generation
        prompt.show(fileCount: state.pendingAsk.count, at: pointer, in: window, alwaysTitle: "Always do this in this project") { [weak self] choice, always in
            self?.chosen(choice, always: always, generation: gen)
        }
    }

    private func chosen(_ choice: MediaPlacementPrompt.Choice, always: Bool, generation: Int) {
        // nil: the project changed while the prompt was up
        guard let files = state.takePendingAsk(promptGeneration: generation) else { return }
        if always, let owner {
            let mode: OutsideMediaMode = choice == .copy ? .copy : choice == .move ? .move : .leave
            owner.session.perform("Change Media Setting") { p in
                var policy = p.mediaPolicy ?? MediaPolicy()
                policy.outside = mode
                p.mediaPolicy = policy
            }
        }
        switch choice {
        case .copy: place(files, mode: .copy)
        case .move: place(files, mode: .move)
        case .leave: break
        }
        projectChanged()
    }

    // MARK: Copies

    /// Copies (and for `.move` later removes the originals of) `files` into `Files/Imported/` in the background, then
    /// points the clips at the copies. A failed copy leaves that clip linked to its original and says so.
    private func place(_ files: [ProjectPanelModel.ImportedFile], mode: ImportMode) {
        guard let owner, let projectURL = owner.session.fileURL, mode != .leave, !files.isEmpty else { return }
        let folder = MediaManagement.importedFolder(forProjectAt: projectURL)
        runCopies(files, label: "Copy Into Project", moveOriginals: mode == .move) { url in
            try MediaFileOps.ingest(url, into: folder, mode: .copy)
        }
    }

    private func copyLibraryItems(_ files: [ProjectPanelModel.ImportedFile], projectURL: URL) {
        let folder = MediaManagement.libraryFolder(forProjectAt: projectURL)
        runCopies(files, label: "Copy Library Items Into Project", moveOriginals: false) { url in
            try MediaFileOps.ingestLibraryItem(url, into: folder)
        }
    }

    private func runCopies(_ files: [ProjectPanelModel.ImportedFile], label: String, moveOriginals: Bool,
                           copy: @escaping @Sendable (URL) throws -> MediaFileOps.Result) {
        guard let owner else { return }
        let hold = state.hold()                       // released by finishCopies on every path
        let projectID = owner.session.project.id
        let gen = state.generation
        let key = UUID()
        let work = Task.detached(priority: .utility) { () -> [Outcome] in
            var out: [Outcome] = []
            for f in files {
                if Task.isCancelled { break }
                let link = MediaFileOps.isLinkOrAlias(f.url)
                do { out.append(Outcome(file: f, result: try copy(f.url), viaLink: link, failure: nil)) }
                catch { out.append(Outcome(file: f, result: nil, viaLink: link, failure: SQL10n.errorText(error))) }
            }
            return out
        }
        copyWorks[key] = work
        Task { [weak self] in
            let outcomes = await work.value
            self?.finishCopies(outcomes, key: key, hold: hold, projectID: projectID, generation: gen, label: label, moveOriginals: moveOriginals)
        }
    }

    private func finishCopies(_ outcomes: [Outcome], key: UUID, hold: MediaWorkState.Token, projectID: UUID, generation gen: Int, label: String, moveOriginals: Bool) {
        copyWorks[key] = nil
        defer { state.release(hold) }
        state.claim(outcomes.compactMap(\.result).filter(\.reused).map(\.url.path))   // another batch's file: not ours to delete
        guard let owner, gen == state.generation, owner.session.project.id == projectID else {
            // Closed or quit mid-batch: copies this batch created are ours and no clip points at them; remove them so the
            // next scan does not file them as duplicates. Originals are untouched.
            discardCreated(outcomes.compactMap(\.result))
            return
        }
        var map: [MediaRef.ID: String] = [:]
        for o in outcomes {
            if let copy = o.copy, copy.path != o.file.url.path { map[o.file.id] = copy.path }
        }
        let failed = outcomes.filter { $0.failure != nil }
        let linkNames = moveOriginals ? outcomes.filter { $0.viaLink && $0.failure == nil }.map { $0.file.url.lastPathComponent } : []
        let made = outcomes.compactMap(\.result)
        applyRelinks(map, created: made) { [weak self] applied in
            guard let self, let owner = self.owner else { return }
            guard moveOriginals else { return }
            var queued = 0
            for o in outcomes where !o.viaLink {
                if let copy = o.copy, applied[o.file.id] == copy.path {
                    self.pendingMoves.append(PendingMove(id: o.file.id, original: o.file.url.path, copy: copy.path)); queued += 1
                }
            }
            if !linkNames.isEmpty {
                owner.shell.statusBar.flash(linkNames.count == 1
                    ? "“\(linkNames[0])” is a link or alias: it was copied and the original stays. Nothing is moved to the Trash."
                    : "\(linkNames.count) files are links or aliases: they were copied and the originals stay.", seconds: 10)
            } else if queued > 0, failed.isEmpty {
                owner.shell.statusBar.flash("Copied into the project. The originals move to the Trash on the next save.", seconds: 8)
            }
        }
        if let first = failed.first {
            let name = first.file.url.lastPathComponent
            owner.shell.statusBar.flash(failed.count == 1
                ? "Could not copy “\(name)” into the project: \(first.failure ?? "") It stays linked to the original."
                : "Could not copy \(failed.count) files into the project (\(name) and others). They stay linked to the originals.",
                seconds: 10)
        }
        projectChanged()
    }

    /// Points items at their copies without an undo step. A copy whose item was removed meanwhile is remembered as
    /// ignored so the watcher never brings it back. Returns what was applied.
    /// While playback runs the relink waits (queued, polled) and never stops playback. `completion` gets what was applied.
    func applyRelinks(_ map: [MediaRef.ID: String], created: [MediaFileOps.Result] = [],
                      completion: (([MediaRef.ID: String]) -> Void)? = nil) {
        guard let owner, !map.isEmpty else { completion?([:]); return }
        if owner.session.isPlaying {
            // The entry holds its own token and the copies it created; a drop (project change) discards both.
            state.deferRelink(map: map, projectID: owner.session.project.id,
                              discard: { [weak self] in self?.discardCreated(created) }, completion: completion)
            pollDeferredRelinks()
            return
        }
        completion?(applyRelinksNow(map))
    }

    private func pollDeferredRelinks() {
        guard relinkPoll == nil else { return }
        relinkPoll = Task { [weak self] in
            while let self, let owner = self.owner, owner.session.isPlaying {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            self?.flushDeferredRelinks()
        }
    }

    private func flushDeferredRelinks() {
        relinkPoll = nil
        guard let owner else { return }
        state.flushDeferred(projectID: owner.session.project.id) { applyRelinksNow($0) }
    }


    /// Deletes copies a dropped batch created, off the main actor, unless anything may use them (see `MediaWorkState`).
    private func discardCreated(_ made: [MediaFileOps.Result]) {
        let inUse = Set(owner?.session.project.media.map(\.path) ?? [])
        let paths = Set(state.discardable(made.filter(\.created).map(\.url.path), inUse: inUse, otherBatchesRunning: !copyWorks.isEmpty))
        let doomed = made.filter { paths.contains($0.url.path) }
        guard !doomed.isEmpty else { return }
        Task.detached(priority: .utility) { MediaFileOps.discardUnlinked(doomed) }
    }

    private func applyRelinksNow(_ map: [MediaRef.ID: String]) -> [MediaRef.ID: String] {
        guard let owner else { return [:] }
        let present = Set(owner.session.project.media.map(\.id))
        let live = map.filter { present.contains($0.key) }
        let gone = map.filter { !present.contains($0.key) }.map(\.value)
        if !live.isEmpty { state.claim(Array(live.values)); owner.session.relinkMediaQuietly(live) }
        if !gone.isEmpty, let folder = MediaManagement.projectFolder(forProjectAt: owner.session.fileURL) {
            _ = owner.session.amendProject { p in gone.forEach { p.ignoreFolderFile($0, projectFolder: folder) } }
        }
        owner.panels.projectModel.scheduleOfflineRefresh()
        return live
    }

    /// After a successful save: originals of moved items whose saved path is the copy go to the Trash. Items that were
    /// removed or undone before the save keep both files.
    func saved(_ project: Project) {
        guard !pendingMoves.isEmpty, project.id == owner?.session.project.id else { return }
        let moves = pendingMoves, media = project.media, gen = state.generation
        Task { [weak self] in
            // Resolving symlinks of every media path touches the disk: off the main actor.
            let (ready, kept) = await Task.detached(priority: .utility) { () -> ([PendingMove], Int) in
                let ready = PendingMove.ready(moves, savedMedia: media)
                let kept = ready.filter { !MediaFileOps.removeOriginal(URL(fileURLWithPath: $0.original), afterCopy: URL(fileURLWithPath: $0.copy)) }.count
                return (ready, kept)
            }.value
            guard let self, gen == self.state.generation else { return }
            let ids = Set(media.map(\.id))
            self.pendingMoves = self.pendingMoves.filter { m in !moves.contains(m) || (ids.contains(m.id) && !ready.contains(m)) }
            if kept > 0 {
                self.owner?.shell.statusBar.flash("Copied into the project, but some originals could not be moved to the Trash and were kept.", seconds: 10)
            }
        }
    }

    /// Project closed or app quitting: running copies stop and remove their temporary file; pending moves are dropped
    /// (both files stay).
    func cancelCopies() {
        state.reset()                                   // first: a callback of the closing prompt sees the new generation
        prompt.close()

        copyWorks.values.forEach { $0.cancel() }
        pendingMoves = []
        relinkPoll?.cancel(); relinkPoll = nil
        syncTimer?.cancel(); syncTimer = nil
    }

    // MARK: Project opened

    /// After a project opened: media that is offline but sits somewhere in the project folder is relinked silently (a
    /// moved or zipped project folder opens with nothing offline), then the folder is watched and scanned.
    func projectOpened() async {
        guard let owner else { return }
        if let projectURL = owner.session.fileURL {
            let imported = MediaManagement.importedFolder(forProjectAt: projectURL), library = MediaManagement.libraryFolder(forProjectAt: projectURL)
            Task.detached(priority: .utility) {
                for f in [imported, library] { _ = MediaFileOps.removeStaleTemporaries(in: f, olderThan: 3600) }
            }
        }
        if let folder = MediaManagement.projectFolder(forProjectAt: owner.session.fileURL), !owner.session.missingMedia.isEmpty {
            await owner.session.relinkMissing(searching: [folder], undoable: false)
            owner.panels.projectModel.scheduleOfflineRefresh()
        }
        await mergeLinkedDuplicates()
        restartWatching()
        projectChanged()
    }

    /// Repair for projects that hold a linked original next to its imported copy (an older drop-in bug): an original
    /// whose bytes equal an item in `Files/Imported/` is folded into that item and its clips follow. History-neutral.
    private func mergeLinkedDuplicates() async {
        guard let owner, let projectURL = owner.session.fileURL else { return }
        let folder = MediaManagement.importedFolder(forProjectAt: projectURL).path + "/"
        let media = owner.session.project.media
        let projectID = owner.session.project.id
        let same = await Task.detached(priority: .utility) { () -> Set<String> in
            var out: Set<String> = []
            let copies = media.filter { $0.path.hasPrefix(folder) }
            for o in media where !o.path.hasPrefix(folder) && o.fingerprint.size > 0 {
                for c in copies where c.fingerprint.size == o.fingerprint.size {
                    if (try? MediaFileOps.fullyIdentical(URL(fileURLWithPath: o.path), URL(fileURLWithPath: c.path))) == true {
                        out.insert("\(o.id)|\(c.id)")
                    }
                }
            }
            return out
        }.value
        guard !same.isEmpty, owner.session.project.id == projectID else { return }
        _ = owner.session.amendProject { p in
            p.mergeLinkedOriginals(intoCopiesIn: folder) { same.contains("\($0.id)|\($1.id)") }
        }
        owner.panels.projectModel.scheduleOfflineRefresh()
    }

    // MARK: Folder watcher

    /// (Re)starts watching the project folder if the project has switched watching on; scans once.
    func restartWatching() {
        token?.cancel(); token = nil
        syncTimer?.cancel(); syncTimer = nil
        state.noteWatchRestart()
        _ = state.watchSettingChanged(to: owner?.session.project.mediaPolicy?.watchFolder == true)                         // a sync still running drops its result; it is never canceled
        guard let owner, let folder = MediaManagement.projectFolder(forProjectAt: owner.session.fileURL),
              MediaManagement.watchesFolder(owner.session.project, projectURL: owner.session.fileURL, defaults: MediaSettings.defaults) else { return }
        token = FSEventsFolderWatcher(latency: 1.5).watch(folder) { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
        scheduleSync()
    }

    /// Undo, redo, Revert or the menu changed the project's watch setting: the watcher follows it.
    func sessionChanged() {
        guard let owner else { return }
        if state.watchSettingChanged(to: owner.session.project.mediaPolicy?.watchFolder == true) { restartWatching() }
    }

    func stopWatching() { token?.cancel(); token = nil; syncTimer?.cancel(); syncTimer = nil; state.noteWatchRestart() }

    /// Only the waiting timer is replaced; a sync that already runs is never canceled (a canceled probe would look like a
    /// broken file). A request during a run is remembered by `MediaWorkState` and runs afterwards.
    private func scheduleSync(after delay: Int = 800) {
        guard token != nil else { return }
        syncTimer?.cancel()
        syncTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.syncTimer = nil
            Task { await self.sync() }                   // separate task: later timer cancels cannot reach it
        }
    }

    /// New files in the project folder appear in the bin (same structure, linked); files that went away turn offline.
    /// Files still being written (size or modification time changed in the last 2 s) wait for the next pass.
    private func sync() async {
        guard let owner, !state.isBusy, token != nil, owner.session.project.mediaPolicy?.watchFolder == true,
              let folder = MediaManagement.projectFolder(forProjectAt: owner.session.fileURL) else { return }
        guard state.beginSync() else { return }          // one is running: it goes again when it ends
        defer { if state.endSync() { scheduleSync() } }
        let epoch = state.watchEpoch, gen = state.generation
        let projectID = owner.session.project.id
        let known = Set(owner.session.project.media.map(\.path))
        let ignored = owner.session.project.mediaPolicy?.ignored ?? []
        let frames = state.sequenceFrames, previous = state.lastSeen
        // Scan, plan, image-sequence grouping and the settle check all run off the main actor.
        let job = await Task.detached(priority: .utility) { () -> SyncJob in
            let found = MediaManagement.scanFiles(in: folder, isMedia: { ext in
                let kind = LibraryItemKind.classify(URL(fileURLWithPath: "/x." + ext))
                return kind == .video || kind == .image || kind == .audio
            })
            var plan = MediaManagement.folderSyncPlan(files: found.filter { !frames.contains($0) }, projectFolder: folder,
                                                      known: known, ignoredRelative: ignored)
            // Numbered frames are one image sequence, not hundreds of stills: they stay out of the automatic add.
            let grouped = Set(ImageSequence.groups(in: plan.map { URL(fileURLWithPath: $0.path) }, minCount: 4).flatMap { $0 }.map(\.path))
            plan.removeAll { grouped.contains($0.path) }
            let seen = MediaManagement.stat(plan.map(\.path))
            let r = MediaManagement.settled(seen, previous: previous)
            let stable = Set(r.stable)
            return SyncJob(plan: plan.filter { stable.contains($0.path) }, seen: seen, unsettled: r.unsettled, frames: grouped)
        }.value
        guard owner.session.project.id == projectID, !state.isBusy, epoch == state.watchEpoch else { return }
        owner.panels.projectModel.scheduleOfflineRefresh()
        state.sequenceFrames.formUnion(job.frames)
        state.lastSeen = Dictionary(job.seen.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        if job.unsettled { scheduleSync(after: 2500) }
        let plan = job.plan
        guard !plan.isEmpty else { return }
        let added = await owner.panels.projectModel.importSynced(plan, stillValid: { [weak self] in
            guard let self else { return false }
            return owner.session.project.id == projectID && self.state.watchEpoch == epoch && self.state.generation == gen
        })
        if added > 0 {
            owner.shell.statusBar.flash(SQL10n.plural(added, one: "Added %@ file from the project folder.", other: "Added %@ files from the project folder."), seconds: 5)
        }
    }

    // MARK: Hint

    /// Recomputes the "N files outside the project folder" hint a moment after the project changed.
    func projectChanged() {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let owner = self.owner else { return }
            // The Library's project health line shows the outside count now; the status-bar chip stays off.
            owner.shell.statusBar.setOutsideHint(nil)
            owner.panels.projectModel.scheduleOfflineRefresh()
        }
    }
}
