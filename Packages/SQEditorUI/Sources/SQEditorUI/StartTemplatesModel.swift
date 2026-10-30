import Foundation
import SQCore

/// Model logic of the start window's "Your templates" row (Home pane) and the New Project sheet's outside-files choices.
public enum StartTemplatesModel {
    /// Cards in the Home row; the rest is behind "All templates" (Templates tab).
    public static let rowLimit = 4

    /// The user's own templates for the Home row, in the store's order, built-ins excluded.
    /// `total` is the full count so the row can show "All templates" when more exist than fit.
    public static func yourTemplates(from all: [ProjectTemplate], limit: Int = rowLimit) -> (shown: [ProjectTemplate], total: Int) {
        let builtIn = Set(ProjectTemplate.builtIn.map(\.id))
        let user = all.filter { !builtIn.contains($0.id) }
        return (Array(user.prefix(max(0, limit))), user.count)
    }

    /// Outside-files choices of the New Project sheet: ask, copy, move or leave (same four as Settings > Media).
    public static let outsideChoices: [(mode: OutsideMediaMode, title: String)] = [
        (.ask, "Ask each time"), (.copy, "Copy into project"), (.move, "Move into project"), (.leave, "Leave in place"),
    ]

    /// Index of `mode` in `outsideChoices` (0 = Ask when unknown).
    public static func outsideIndex(of mode: OutsideMediaMode) -> Int {
        outsideChoices.firstIndex { $0.mode == mode } ?? 0
    }
}
