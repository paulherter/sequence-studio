import Foundation
import SQAnalysis

/// Subject-mask matte files whose removal was decided and may not have happened yet. `MagicMatteStore.remove` drops
/// a key from memory at once and deletes its file later on its own queue; the app ending in between (a crash, a
/// forced quit) leaves the file in the matte folder for good, because nothing remembers the key. The journal writes
/// the keys down before the removal and strikes them out once the store's queue is through; what a process that
/// ended early left listed is deleted when the next project opens (`sweepLeftover`).
///
/// The matte folder is shared by all projects and a file name says nothing about its project, so "no mask of the
/// open project refers to it" never proves a file orphaned. Only keys listed here go: the removal of each was
/// decided before, by the same rules as without a crash. The sweep touches nothing but `<key>.sqmatte` directly in
/// the store's folder.
///
/// Each key is listed with the time of its removal (`<key>\t<seconds since 1970>` per line). A file changed at or
/// after that time is not the removed one: the same pick was made again and the store wrote its frames (it writes
/// instead of deleting then). Such a key is dropped from the list and its file stays.
public final class MatteRemovalJournal: Sendable {
    public static let fileName = "pending-removals"

    /// The app's journal, in the folder of `MagicMatteStore.shared`.
    public static let shared = MatteRemovalJournal(directory: MagicMatteStore.shared.directory)

    private struct State {
        /// Listed by a process before this one and not swept yet, with the time each was listed.
        var leftover: [String: Double]
        /// Noted by this process, removal not through yet; a key noted twice counts twice and keeps the later time.
        var pending: [String: (count: Int, at: Double)] = [:]
        var swept = false
    }

    private let directory: URL?
    private let state: NSLock = NSLock()
    private nonisolated(unsafe) var s: State
    /// Strikes keys out behind the store's own queue; never blocks the caller.
    private let settle = DispatchQueue(label: "sq.matte-removal-journal", qos: .utility)

    /// `directory` nil = nothing is written (a memory-only store).
    public init(directory: URL?) {
        self.directory = directory?.standardizedFileURL
        var left: [String: Double] = [:]
        let own = Self.ownPID
        // Each process writes `pending-removals.<pid>`. A list of a process that is still running is that process's
        // own in-flight work and is never adopted (a second app instance must not sweep it). The unnumbered list
        // of older builds counts as a dead process's.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.directory?.path ?? "")) ?? []
        for name in names where name == Self.fileName || name.hasPrefix(Self.fileName + ".") {
            var pid: Int32?
            if name != Self.fileName {
                guard let p = Int32(name.dropFirst(Self.fileName.count + 1)) else { continue }
                pid = p
            }
            if let pid, pid != own, Self.isAlive(pid) { continue }
            guard let url = self.directory?.appendingPathComponent(name) else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                // A line without a time proves nothing about its file: never listed.
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard parts.count == 2, Self.isKey(String(parts[0])), let at = Double(parts[1]), at.isFinite else { continue }
                    left[String(parts[0])] = max(at, left[String(parts[0])] ?? at)
                }
            }
            if pid != own { try? FileManager.default.removeItem(at: url) }
        }
        s = State(leftover: left)
        if !left.isEmpty { state.withLock { write() } }
    }

    static var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// The keys a process before this one left listed (until `sweepLeftover`).
    public var leftover: Set<String> { state.withLock { Set(s.leftover.keys) } }

    /// A key as the store makes them: letters, digits, `-` and `_` only, so a listed line can never name a path.
    public static func isKey(_ k: String) -> Bool {
        !k.isEmpty && k.count <= 128 && k.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
                || $0 == "-" || $0 == "_"
        }
    }

    /// `MagicMatteStore.sweep(keeping:)` with the keys written down first. Returns the removed keys.
    @discardableResult
    public func sweep(_ store: MagicMatteStore, keeping: Set<String>) -> [String] {
        let going = store.writtenKeys.subtracting(keeping)
        note(going)
        let gone = store.sweep(keeping: keeping)
        done(going, after: store)
        return gone
    }

    /// `MagicMatteStore.remove(key:)` with the key written down first.
    public func remove(_ key: String, from store: MagicMatteStore) {
        note([key])
        store.remove(key: key)
        done([key], after: store)
    }

    /// Waits until every removal noted so far is struck out (tests, quit).
    public func waitForSettle() { settle.sync {} }

    /// Deletes the matte files a process before this one listed and never got to, except the keys in `keeping`
    /// (the masks of the project that just opened and what the store holds frames for in this process) and the
    /// files changed since they were listed. Once per process; returns the keys whose file went.
    @discardableResult
    public func sweepLeftover(keeping: Set<String>) -> [String] {
        let keys: [String: Double] = state.withLock {
            guard !s.swept else { return [:] }
            s.swept = true
            return s.leftover
        }
        var gone: [String] = []
        if let directory {
            for k in keys.keys.sorted() where !keeping.contains(k) && Self.isKey(k) {
                let url = directory.appendingPathComponent("\(k).sqmatte").standardizedFileURL
                // Only a plain file directly in the matte folder, and only the one that was there when it was listed.
                guard url.deletingLastPathComponent().path == directory.path, let listed = keys[k],
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let changed = values.contentModificationDate,
                      changed.timeIntervalSince1970 < listed else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { gone.append(k) }
            }
        }
        state.withLock { s.leftover = [:]; write() }
        if !gone.isEmpty { NSLog("[Magic] removed %d matte file(s) left by a session that ended early", gone.count) }
        return gone
    }

    /// Lists `keys` as about to be removed, now.
    func note(_ keys: Set<String>) {
        let keys = keys.filter(Self.isKey)
        guard !keys.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        state.withLock {
            for k in keys { s.pending[k] = ((s.pending[k]?.count ?? 0) + 1, now) }
            write()
        }
    }

    private func done(_ keys: Set<String>, after store: MagicMatteStore) {
        let keys = keys.filter(Self.isKey)
        guard !keys.isEmpty else { return }
        settle.async { [self] in
            store.waitForSaves()
            state.withLock {
                for k in keys {
                    // Deleted, or written again for the same pick made anew: either way nothing is left to do.
                    if let p = s.pending[k], p.count > 1 { s.pending[k] = (p.count - 1, p.at) } else { s.pending[k] = nil }
                }
                write()
            }
        }
    }

    /// Writes the list (lock held): no file when nothing is listed.
    private func write() {
        guard let url = directory?.appendingPathComponent("\(Self.fileName).\(Self.ownPID)") else { return }
        var all = s.leftover
        for (k, p) in s.pending { all[k] = p.at }
        if all.isEmpty { try? FileManager.default.removeItem(at: url) }
        else { try? Data(all.keys.sorted().map { "\($0)\t\(all[$0]!)" }.joined(separator: "\n").utf8).write(to: url, options: .atomic) }
    }
}
