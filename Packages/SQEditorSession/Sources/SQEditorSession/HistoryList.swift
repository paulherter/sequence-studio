import Foundation
import SQUIKit

/// The undo history as the History panel lists it: the opening state, then every step oldest first. `position` is the
/// row of the state the project is in now; rows after it are steps that Redo would bring back.
public struct HistoryList: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: Int
        public var title: String
        /// A step Redo would apply (shown dimmed).
        public var isUndone: Bool
        public var isCurrent: Bool
    }

    public static let originalTitle = "Original"
    public let rows: [Row]
    public let position: Int

    public init(undoNames: [String], redoNames: [String]) {
        var rows = [Row(id: 0, title: SQL10n.string(Self.originalTitle), isUndone: false, isCurrent: false)]
        for (i, n) in undoNames.enumerated() {
            rows.append(Row(id: i + 1, title: SQL10n.undoName(n), isUndone: false, isCurrent: false))
        }
        for (i, n) in redoNames.enumerated() {
            rows.append(Row(id: undoNames.count + i + 1, title: SQL10n.undoName(n), isUndone: true, isCurrent: false))
        }
        rows[undoNames.count].isCurrent = true
        self.rows = rows
        position = undoNames.count
    }

    /// Undos (negative) or redos (positive) that take the project from the current row to `row`; 0 when it is the
    /// current row or does not exist.
    public func steps(to row: Int) -> Int { rows.indices.contains(row) ? row - position : 0 }
}

extension EditorSession {
    /// The history list of this session.
    public var historyList: HistoryList { HistoryList(undoNames: history.undoNames, redoNames: history.redoNames) }

    /// Goes to the state of `row` of `historyList` by undoing or redoing step by step, so every step's side effects
    /// (playhead moves, data kept outside the project) follow exactly as with Cmd+Z / Cmd+Shift+Z. True when it moved.
    @discardableResult
    public func jumpToHistoryRow(_ row: Int) -> Bool {
        let n = historyList.steps(to: row)
        guard n != 0 else { return false }
        for _ in 0..<abs(n) { if !(n < 0 ? undo() : redo()) { break } }
        return true
    }
}
