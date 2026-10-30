import Foundation

/// When an import of many files puts its finished items into the bin (docs/PLAYBACK-PERF.md "Import of large folders").
/// Before, the bin stayed empty until the last of N probes was done (300 files: seconds of nothing). Now the in-order
/// prefix of finished files goes in as it grows: the first one at once, then at most every `interval` (each commit
/// reloads the grid), and the rest when everything is done. Only the in-order prefix: the bin keeps the input order, the
/// same as one commit at the end would. Pure value logic; `ProjectPanelModel.importFiles` runs it.
public struct ImportCommitPlan: Sendable {
    public let count: Int
    public let interval: Duration
    /// Items `0..<committed` are handed out.
    public private(set) var committed = 0
    private var done: [Bool]
    private var ready = 0
    private var lastCommit: ContinuousClock.Instant?

    public init(count: Int, interval: Duration = .milliseconds(250)) {
        self.count = max(0, count)
        self.interval = interval
        done = Array(repeating: false, count: max(0, count))
    }

    public var isComplete: Bool { committed == count }

    /// Item `index` finished (imported or failed). Returns the range to commit now, if any.
    public mutating func finished(_ index: Int, at now: ContinuousClock.Instant) -> Range<Int>? {
        guard index >= 0, index < count, !done[index] else { return nil }
        done[index] = true
        while ready < count, done[ready] { ready += 1 }
        guard ready > committed else { return nil }
        let due = committed == 0 || ready == count || lastCommit.map { now - $0 >= interval } ?? true
        guard due else { return nil }
        lastCommit = now
        return take()
    }

    /// Whatever in-order prefix is ready, regardless of the interval (end of the import, or a timer).
    public mutating func flush() -> Range<Int>? {
        guard ready > committed else { return nil }
        return take()
    }

    private mutating func take() -> Range<Int> {
        let r = committed..<ready
        committed = ready
        return r
    }
}

/// Requests served visible-first: what is on screen (in screen order) before anything else, the rest oldest first.
/// For poster frames of a bin with hundreds of items: scrolling to the end of a fresh import no longer waits for every
/// poster above it. Enqueue / remove are O(1); `next` looks at the visible list (a screenful) and then the FIFO.
public struct VisibleFirstQueue<ID: Hashable & Sendable>: Sendable {
    private var order: [ID] = []
    private var head = 0
    /// Waiting requests -> position in `order` of their entry (an id served or removed and enqueued again gets a new one).
    private var waiting: [ID: Int] = [:]
    private var visible: [ID] = []

    public init() {}

    public var count: Int { waiting.count }
    public var isEmpty: Bool { waiting.isEmpty }
    public func contains(_ id: ID) -> Bool { waiting[id] != nil }

    /// Adds a request; one already waiting keeps its place.
    public mutating func enqueue(_ id: ID) {
        guard waiting[id] == nil else { return }
        waiting[id] = order.count
        order.append(id)
    }

    public mutating func remove(_ id: ID) { waiting[id] = nil }

    /// The ids on screen now, in screen order (top-left first). Replaces the previous list.
    public mutating func setVisible(_ ids: [ID]) { visible = ids }

    /// The next request to serve, removed from the queue.
    public mutating func next() -> ID? {
        for id in visible where waiting[id] != nil {
            waiting[id] = nil
            return id
        }
        while head < order.count {
            let i = head
            head += 1
            let id = order[i]
            if waiting[id] == i {
                waiting[id] = nil
                compact()
                return id
            }
        }
        compact()
        return nil
    }

    private mutating func compact() {
        guard head > 1024, head * 2 > order.count else { return }
        order.removeFirst(head)
        for (id, pos) in waiting { waiting[id] = pos - head }
        head = 0
    }
}
