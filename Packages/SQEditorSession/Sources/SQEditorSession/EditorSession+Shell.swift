import Foundation
import SQCore
import SQMedia

/// Logic behind the daily-driver menu items (File > Close Project, Autosave Versions, Relink Media...). The app's menus only call these.
extension EditorSession {
    // MARK: LUT files

    /// Part of a save into the project file: with the copy setting on (project policy over the app default) and a
    /// project folder around `url`, every LUT a grade uses from outside that folder is copied into `Files/Library/`
    /// (identical content is reused). Returns old path -> copy path; the caller writes the file with the copies and, once
    /// that succeeded, points the open project at them (history-neutral, no undo step). The copying runs off the main
    /// actor and never waits for a media ingest. A LUT that cannot be read stays as it is.
    func collectLUTs(forSaveAt url: URL) async -> [String: String] {
        guard let folder = MediaManagement.projectFolder(forProjectAt: url),
              MediaManagement.copiesLibraryItems(project, projectURL: url, defaults: mediaPolicyDefaults()) else { return [:] }
        let outside = history.current.referencedLUTFiles.filter { $0.hasPrefix("/") && !MediaManagement.isInside($0, folder: folder) }
        guard !outside.isEmpty else { return [:] }
        let library = MediaManagement.libraryFolder(in: folder)
        return await Task.detached { () -> [String: String] in
            var m: [String: String] = [:]
            for p in outside { if let r = try? MediaFileOps.collectLUT(URL(fileURLWithPath: p), into: library) { m[p] = r.url.path } }
            return m
        }.value
    }

    // MARK: Close

    /// Closes the document: back to a project without any sequence (the chooser is shown). The caller asks about unsaved changes first.
    public func closeProject() { previewRate = .normal; newProject(EditorSession.makeEmpty()) }

    /// Nothing to close: untitled, unchanged and without content.
    public var isEmptyUntitled: Bool {
        fileURL == nil && !isDirty && project.media.isEmpty && project.timelines.allSatisfy { $0.tracks.allSatisfy { $0.clips.isEmpty } }
    }

    // MARK: Autosave versions

    /// Settings > Autosave takes effect at once (the same range `AppSettings.load` accepts); anything else is ignored.
    public func setAutosaveInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 30, seconds <= 3600 else { return }
        autosaveStore.policy.interval = seconds
    }

    /// Autosave versions of the open project, newest first.
    public var autosaveVersions: [AutosaveVersion] { autosaveStore.versions(for: project.id) }

    /// Makes the version the current project as ONE undo step ("Restore Autosave Version"). The project keeps its
    /// file and id; the content equals the version exactly. Throws when the version cannot be read.
    public func restoreAutosave(_ version: AutosaveVersion) throws {
        let restored: Project
        restored = try autosaveStore.read(version)       // the caller reports the error
        perform("Restore Autosave Version") { $0 = restored }
    }

    // MARK: Relink

    /// True while some media file is not at its path. Relink is available any time, not only at open.
    public var canRelink: Bool { !missingMedia.isEmpty }

    public struct RelinkOutcome: Sendable, Equatable {
        public var relinked = 0
        public var offline = 0
        /// Files of the right name were found, but with another size: not relinked.
        public var sizeDiffers = 0
    }

    /// Searches `folder` (and subfolders) for the offline media by file name and recorded size and relinks what it finds.
    @discardableResult
    public func relinkMissing(searching folder: URL) async -> RelinkOutcome { await relinkMissing(searching: [folder]) }

    /// Searches `folders` (and subfolders) for the offline media by file name (POSIX or Windows stored paths) and
    /// recorded size and relinks what it finds, as one undo step. If the project is replaced during the scan nothing is
    /// applied (all zero). Playback stops first: the engine reopens the media.
    @discardableResult
    public func relinkMissing(searching folders: [URL], undoable: Bool = true) async -> RelinkOutcome {
        let missing = missingMedia
        guard !missing.isEmpty, !folders.isEmpty else { return RelinkOutcome(offline: missing.count) }
        let projectID = project.id
        let wanted = Set(missing.map { MediaPathResolver.fileName(of: $0.path).lowercased() })
        let found = await Task.detached(priority: .userInitiated) { RelinkScanner.scan(folders: folders, named: wanted) }.value
        guard project.id == projectID else { return RelinkOutcome() }
        let current = missingMedia        // may have changed during the scan
        let result = RelinkPlanner.match(missing: current, candidates: found)
        SQLog.info("relink: \(folders.map(\.path)) -> \(found.count) name hits, \(result.plan.count) of \(current.count) relinked, \(result.sizeMismatch.count) size/ambiguous")
        if !result.plan.isEmpty { stopPlayback(); if undoable { relinkMedia(result.plan) } else { relinkMediaQuietly(result.plan) } }
        return RelinkOutcome(relinked: result.plan.count, offline: current.count, sizeDiffers: result.sizeMismatch.count)
    }
}

extension EditorSession {
    /// Save As into a folder the user picked: that folder is never watched on its own, so a project that watched its old
    /// folder stops. The setting changes only together with a successful save; a failed save puts the old value back.
    public func saveAsWithoutWatching(to url: URL) async throws {
        let hadWatch = project.mediaPolicy?.watchFolder == true, wasFlagged = needsSaveFlag, projectID = project.id
        if hadWatch { amendProject { $0.mediaPolicy?.watchFolder = false } }
        do { try await saveAs(to: url) } catch {
            // Another project was opened meanwhile: it keeps its own setting and dirty flag.
            if error as? SaveError == .projectChanged || project.id != projectID { throw error }
            if hadWatch { amendProject { $0.mediaPolicy?.watchFolder = true }; needsSaveFlag = wasFlagged }
            throw error
        }
    }

    // MARK: Locate one file

    /// Per-file Locate: points the one offline item `id` at the file the user chose (their word, no size check), as one
    /// undo step. Returns false when the item is unknown or its file is online.
    @discardableResult
    public func locateMedia(_ id: MediaRef.ID, at url: URL) -> Bool {
        guard let m = project.media(id), m.status() == .missing else { return false }
        stopPlayback()
        relinkMedia([id: url.path], name: "Locate Media")
        SQLog.info("locate: \(m.name) -> \(url.path)")
        return true
    }

    /// Other offline items whose file (same name, same recorded size) sits in `folder`, not below it: what the user is
    /// offered after choosing a file for one item. Scans off the main thread.
    public func missingSiblings(in folder: URL, excluding id: MediaRef.ID) async -> [MediaRef.ID: String] {
        let others = missingMedia.filter { $0.id != id }
        guard !others.isEmpty else { return [:] }
        let wanted = Set(others.map { MediaPathResolver.fileName(of: $0.path).lowercased() })
        let found = await Task.detached(priority: .userInitiated) { RelinkScanner.scan(roots: [(folder, 0)], named: wanted) }.value
        return RelinkPlanner.plan(missing: others, candidates: found)
    }

    /// Relinks the siblings the user accepted (one undo step).
    public func relinkSiblings(_ plan: [MediaRef.ID: String]) {
        guard !plan.isEmpty else { return }
        stopPlayback()
        relinkMedia(plan, name: "Relink Media")
    }
}
