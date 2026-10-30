import Foundation

/// Snapshot-based undo/redo for any value-type state.
public struct History<State: Sendable & Equatable>: Sendable {
    private struct Entry: Sendable {
        var name: String
        var state: State
        /// Names data kept outside the state (the session's side effects of this step); follows the step through undo
        /// and redo and is gone when the step is trimmed, dropped or withdrawn.
        var tag: UUID?
    }

    public private(set) var current: State
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var saved: State
    private var lastKey: String? { didSet { if lastKey == nil { heldRedo = []; heldOldest = [] } } }
    /// The redo steps a coalesced step (a gesture) replaced when it began, kept while that step is the newest and can
    /// still merge: a gesture that is canceled back to its start gives them back, as if it had never begun.
    private var heldRedo: [Entry] = []
    /// The oldest undo steps that gesture's step pushed over the `limit`, given back the same way.
    private var heldOldest: [Entry] = []
    /// Undo entries dropped by the `limit` trim. Depths are counted from the very first step, so a depth taken
    /// before a trim still names the same step afterwards (clamped to the oldest entry still held).
    private var dropped = 0
    /// Tags of undo steps taken out of the stack with their change still in effect (a gesture canceled back to its start,
    /// `rewind`), newest first. The owner of the tagged data undoes it and takes the list with `takeWithdrawnTags()`.
    private var withdrawn: [UUID] = []
    /// Tags of the steps `squash` merged (and the tag of the step they merged into), oldest first: the owner combines
    /// their data under a new tag of the merged step.
    private var folded: [UUID] = []
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
    /// Names of the undo steps still held, oldest first (the History panel's list; trimmed steps are not in it).
    public var undoNames: [String] { undoStack.map(\.name) }
    /// Names of the redo steps, the one Redo takes first at the start.
    public var redoNames: [String] { redoStack.reversed().map(\.name) }

    public mutating func markSaved() { saved = current }
    /// Marks `state` (what was written) as the saved one, even when undo or redo moved on while the write ran.
    public mutating func markSaved(_ state: State) { saved = state }

    public mutating func commit(_ name: String, _ change: (inout State) throws -> Void) rethrows {
        try commit(name, coalescing: nil, change)
    }

    /// Consecutive commits with the same non-nil `key` merge into one undo step. A merged commit that brings the state
    /// back to where the step began (a gesture canceled with Esc) drops the step: there is nothing left to undo, and
    /// what could be redone before the gesture can be redone again.
    public mutating func commit(_ name: String, coalescing key: String?,
                                _ change: (inout State) throws -> Void) rethrows {
        var next = current
        try change(&next)
        guard next != current else { return }
        if let key, key == lastKey, let last = undoStack.last {
            if last.state == next {
                if let t = last.tag { withdrawn.append(t) }
                undoStack.removeLast()
                undoStack.insert(contentsOf: heldOldest, at: 0)
                dropped -= heldOldest.count
                redoStack = heldRedo
                lastKey = nil
                current = next
                return
            }
            undoStack[undoStack.count - 1].name = name
        } else {
            undoStack.append(Entry(name: name, state: current, tag: nil))
            let over = max(undoStack.count - limit, 0)
            let oldest = Array(undoStack.prefix(over))
            if over > 0 { dropped += over; undoStack.removeFirst(over) }
            lastKey = nil
            if key != nil { heldRedo = redoStack; heldOldest = oldest }
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
        for i in heldRedo.indices { change(&heldRedo[i].state) }
        for i in heldOldest.indices { change(&heldOldest[i].state) }
    }

    /// Whether the newest step is a gesture holding redo steps it would give back if canceled.
    public var holdsRedo: Bool { !heldRedo.isEmpty }

    /// The gesture is over (mouse up): its step merges no further commit and can no longer be canceled away, so what
    /// it held back for a cancel (redo steps, steps over the limit) is let go now, not at the next commit.
    public mutating func endCoalescing() { lastKey = nil }

    /// Tag of the step Undo / Redo would take.
    public var undoTag: UUID? { undoStack.last?.tag }
    public var redoTag: UUID? { redoStack.last?.tag }
    /// Every tag still held by an undo or redo step.
    public var liveTags: Set<UUID> { Set((undoStack + redoStack + heldRedo + heldOldest).compactMap(\.tag)) }

    /// The tags of steps withdrawn since the last call (newest first); their data must be undone by the caller.
    public mutating func takeWithdrawnTags() -> [UUID] { defer { withdrawn = [] }; return withdrawn }
    /// The tags of steps merged by `squash` since the last call (oldest first); the caller tags the merged step anew.
    public mutating func takeFoldedTags() -> [UUID] { defer { folded = [] }; return folded }

    /// Tags the newest undo step (false when there is none).
    @discardableResult
    public mutating func tagNewestStep(_ tag: UUID) -> Bool {
        guard !undoStack.isEmpty else { return false }
        undoStack[undoStack.count - 1].tag = tag
        return true
    }

    /// A step that changes nothing in the state (its effect lives outside it): named, tagged, clears Redo.
    public mutating func pushMarker(_ name: String, tag: UUID) {
        undoStack.append(Entry(name: name, state: current, tag: tag))
        if undoStack.count > limit { dropped += undoStack.count - limit; undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        lastKey = nil
    }

    /// Number of undo steps.
    public var undoDepth: Int { undoStack.count + dropped }

    /// Goes back to `depth` undo steps and forgets everything above (no redo entries are left): for an edit that is
    /// withdrawn before it was ever finished (an empty text box).
    public mutating func rewind(toDepth depth: Int) {
        let depth = max(depth - dropped, 0)
        guard undoStack.count > depth else { return }
        current = undoStack[depth].state
        withdrawn.append(contentsOf: undoStack[depth...].reversed().compactMap(\.tag))
        undoStack.removeSubrange(depth...)
        redoStack.removeAll()
        lastKey = nil
    }

    /// Folds the undo steps above `depth` into one named step (state before the first of them).
    public mutating func squash(fromDepth depth: Int, name: String) {
        let depth = max(depth - dropped, 0)
        guard undoStack.count > depth else { return }
        undoStack[depth].name = name
        if undoStack.count > depth + 1 {
            let tags = undoStack[depth...].compactMap(\.tag)
            if !tags.isEmpty {
                folded.append(contentsOf: tags)
                undoStack[depth].tag = nil
            }
            undoStack.removeSubrange((depth + 1)...)
        }
        lastKey = nil
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let e = undoStack.popLast() else { return false }
        redoStack.append(Entry(name: e.name, state: current, tag: e.tag))
        current = e.state
        lastKey = nil
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let e = redoStack.popLast() else { return false }
        undoStack.append(Entry(name: e.name, state: current, tag: e.tag))
        current = e.state
        lastKey = nil
        return true
    }
}
