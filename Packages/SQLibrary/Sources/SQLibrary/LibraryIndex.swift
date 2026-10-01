import Foundation

public enum FolderState: Sendable, Equatable {
    case online, offline
}

public struct LibraryUpdate: Sendable, Equatable {
    public var folderID: UUID
    public var state: FolderState
    public var diff: LibraryDiff
}

/// In-memory index of watched folders: snapshots, offline state, incremental rescans.
public actor LibraryIndex {
    private let scanner: FolderScanner
    private let watcher: any FolderWatching
    private var folderList: [WatchedFolder] = []
    private var snapshots: [UUID: [LibraryEntry]] = [:]
    private var states: [UUID: FolderState] = [:]
    private var tokens: [UUID: any FolderWatchToken] = [:]
    private var continuations: [UUID: AsyncStream<LibraryUpdate>.Continuation] = [:]

    public init(scanner: FolderScanner = FolderScanner(), watcher: any FolderWatching) {
        self.scanner = scanner
        self.watcher = watcher
    }

    public var folders: [WatchedFolder] { folderList }

    public func state(of id: UUID) -> FolderState? { states[id] }
    public func entries(in id: UUID) -> [LibraryEntry] { snapshots[id] ?? [] }

    /// Adds (or replaces) a folder, scans it and starts watching.
    @discardableResult
    public func add(_ folder: WatchedFolder) -> LibraryUpdate {
        if let i = folderList.firstIndex(where: { $0.id == folder.id }) { folderList[i] = folder } else { folderList.append(folder) }
        tokens[folder.id]?.cancel()
        let id = folder.id
        tokens[id] = watcher.watch(folder.url) { [weak self] in
            Task { await self?.handleChange(id) }
        }
        return rescanNow(folder)
    }

    public func remove(_ id: UUID) {
        tokens.removeValue(forKey: id)?.cancel()
        folderList.removeAll { $0.id == id }
        snapshots[id] = nil
        states[id] = nil
    }

    @discardableResult
    public func rescan(_ id: UUID) -> LibraryUpdate? {
        guard let folder = folderList.first(where: { $0.id == id }) else { return nil }
        return rescanNow(folder)
    }

    /// Stream of updates produced by watcher events (non-empty diffs or state changes).
    public func updates() -> AsyncStream<LibraryUpdate> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<LibraryUpdate>.makeStream()
        continuations[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(key) } }
        return stream
    }

    private func dropContinuation(_ key: UUID) { continuations[key] = nil }

    private func handleChange(_ id: UUID) {
        guard let folder = folderList.first(where: { $0.id == id }) else { return }
        let before = states[id]
        let update = rescanNow(folder)
        guard !update.diff.isEmpty || before != update.state else { return }
        continuations.values.forEach { $0.yield(update) }
    }

    private func rescanNow(_ folder: WatchedFolder) -> LibraryUpdate {
        switch scanner.scan(folder) {
        case .offline:
            // Keep the last snapshot so nothing is reported as removed.
            states[folder.id] = .offline
            return LibraryUpdate(folderID: folder.id, state: .offline, diff: LibraryDiff(added: [], removed: [], changed: []))
        case .online(let entries):
            let diff = LibraryDiff.between(old: snapshots[folder.id] ?? [], new: entries)
            snapshots[folder.id] = entries
            states[folder.id] = .online
            return LibraryUpdate(folderID: folder.id, state: .online, diff: diff)
        }
    }
}
