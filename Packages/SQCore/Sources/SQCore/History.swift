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

    /// Applies `change` to the current state, every undo and redo state and the saved state: a background
    /// refinement (e.g. detected media properties) that is not an edit. Adds no undo step; dirty stays as it was.
    public mutating func amendAll(_ change: (inout State) -> Void) {
        change(&current); change(&saved)
        for i in undoStack.indices { change(&undoStack[i].state) }
        for i in redoStack.indices { change(&redoStack[i].state) }
    }

    /// Number of undo steps.
    public var undoDepth: Int { undoStack.count }

    /// Goes back to `depth` undo steps and forgets everything above (no redo entries are left): for an edit that is
    /// withdrawn before it was ever finished (an empty text box).
    public mutating func rewind(toDepth depth: Int) {
        guard depth >= 0, undoStack.count > depth else { return }
        current = undoStack[depth].state
        undoStack.removeSubrange(depth...)
        redoStack.removeAll()
        lastKey = nil
    }

    /// Folds the undo steps above `depth` into one named step (state before the first of them).
    public mutating func squash(fromDepth depth: Int, name: String) {
        guard depth >= 0, undoStack.count > depth else { return }
        undoStack[depth].name = name
        if undoStack.count > depth + 1 { undoStack.removeSubrange((depth + 1)...) }
        lastKey = nil
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
