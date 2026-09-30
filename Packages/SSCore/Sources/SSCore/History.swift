/// Snapshot-based undo/redo for any value-type state.
public struct History<State: Sendable & Equatable>: Sendable {
    private struct Entry: Sendable {
        var name: String
        var state: State
    }

    public private(set) var current: State
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var saved: State
    private var lastKey: String?
    public let limit: Int

    public init(_ initial: State, limit: Int = 200) {
        current = initial
        saved = initial
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }
    public var isDirty: Bool { current != saved }

    public mutating func markSaved() { saved = current }

    public mutating func commit(_ name: String, _ change: (inout State) throws -> Void) rethrows {
        try commit(name, coalescing: nil, change)
    }

    /// Consecutive commits with the same non-nil `key` merge into one undo step.
    public mutating func commit(_ name: String, coalescing key: String?,
                                _ change: (inout State) throws -> Void) rethrows {
        var next = current
        try change(&next)
        guard next != current else { return }
        if let key, key == lastKey, !undoStack.isEmpty {
            undoStack[undoStack.count - 1].name = name
        } else {
            undoStack.append(Entry(name: name, state: current))
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        }
        lastKey = key
        redoStack.removeAll()
        current = next
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let e = undoStack.popLast() else { return false }
        redoStack.append(Entry(name: e.name, state: current))
        current = e.state
        lastKey = nil
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let e = redoStack.popLast() else { return false }
        undoStack.append(Entry(name: e.name, state: current))
        current = e.state
        lastKey = nil
        return true
    }
}
