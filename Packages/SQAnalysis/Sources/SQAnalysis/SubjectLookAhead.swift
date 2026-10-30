import Foundation

/// One piece of work done ahead, on its own thread, for a key object (the frame the tracking model is asked next):
/// the image encoder of frame n+1 runs while frame n is in the memory attention and the decoder. One at a time: a
/// start waits for the one still running. The work must end on its own (the model's predictions have a deadline).
final class SubjectLookAhead<Value>: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Guards everything below; signaled when the work in flight ends.
    private let changed = NSCondition()
    /// Read and written only under `changed`.
    private final class Entry: @unchecked Sendable {
        let key: AnyObject
        var result: Result<Value, any Error>?
        init(_ key: AnyObject) { self.key = key }
    }
    /// Oldest first: the frame asked now (its work may be done) and the one after it (its work may run).
    private var entries: [Entry] = []
    /// Results held that were not taken yet.
    static var kept: Int { 2 }

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    private struct Work: @unchecked Sendable { let run: () throws -> Value }

    /// Starts `work` for `key`, unless work for that key is already ahead. One at a time: waits for work that still
    /// runs. The oldest result not taken is dropped when more than `kept` would be held.
    func start(_ key: AnyObject, _ work: @escaping () throws -> Value) {
        changed.lock()
        defer { changed.unlock() }
        if entries.contains(where: { $0.key === key }) { return }
        while entries.contains(where: { $0.result == nil }) { changed.wait() }
        let entry = Entry(key)
        entries.append(entry)
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
        let job = Work(run: work)
        queue.async { [self] in
            let r = Result { try job.run() }
            changed.lock(); entry.result = r; changed.broadcast(); changed.unlock()
        }
    }

    /// The work's result for `key`, waited for; nil when nothing was started for `key`. Taken once.
    func take(_ key: AnyObject) throws -> Value? {
        changed.lock()
        defer { changed.unlock() }
        guard let entry = entries.first(where: { $0.key === key }) else { return nil }
        while entry.result == nil { changed.wait() }
        entries.removeAll { $0 === entry }
        return try entry.result?.get()
    }

    /// Whether work for `key` was started and not taken yet.
    func holds(_ key: AnyObject) -> Bool {
        changed.lock(); defer { changed.unlock() }
        return entries.contains { $0.key === key }
    }
}
