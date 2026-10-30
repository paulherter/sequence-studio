import Foundation

/// Pure button-role logic of `SQDialog` (no AppKit): which button Return and Esc press, in which order the buttons
/// are laid out, and what a response index means. The response of a dialog is the index into `buttons` in the order
/// they were added (so the first added button is `Response.first`, like NSAlert's first button).
public struct SQDialogModel: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Plain button, never triggered by a key.
        case normal
        /// Return presses it. At most one; the first one wins.
        case `default`
        /// Esc (and Cmd-.) press it. At most one; the first one wins.
        case cancel
        /// Red text. Never the implicit Return button unless nothing else qualifies.
        case destructive
        /// "Don't Save": sits alone at the left edge, Cmd-D presses it. At most one; the first one wins.
        case dontSave
        /// "Save": the main action, Cmd-S presses it. At most one; the first one wins.
        case save
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var role: Role
        /// Sits alone at the left edge of the footer (board: "Delete Marker"); everything else is right aligned.
        public var leading: Bool
        public init(title: String, role: Role = .normal, leading: Bool = false) { self.title = title; self.role = role; self.leading = leading }
        /// Left edge of the footer: asked for explicitly, or the Don't Save role.
        public var isLeading: Bool { leading || role == .dontSave }
    }

    /// Dialog result: the index of the pressed button.
    public struct Response: RawRepresentable, Equatable, Hashable, Sendable {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public init(_ index: Int) { self.rawValue = index }
        public static let first = Response(0)
        public static let second = Response(1)
        public static let third = Response(2)
        /// A dialog dismissed without a button (window closed programmatically).
        public static let dismissed = Response(-1)
    }

    public var buttons: [Button] = []
    public init(buttons: [Button] = []) { self.buttons = buttons }

    /// The main action (rightmost, accent): an explicit `.default`, else `.save`, else the first button that is neither
    /// cancel, destructive nor leading, else the first non-cancel non-leading button (a destructive one), else none.
    public var primaryIndex: Int? {
        if let i = buttons.firstIndex(where: { $0.role == .default }) { return i }
        if let i = buttons.firstIndex(where: { $0.role == .save }) { return i }
        if let i = buttons.firstIndex(where: { $0.role == .normal && !$0.isLeading }) { return i }
        return buttons.firstIndex { $0.role != .cancel && !$0.isLeading }
    }

    /// The button Return presses: the main action, but never a destructive one while a cancel button exists (Return then
    /// presses Cancel, which also holds the focus); a lone destructive button still answers Return.
    public var returnIndex: Int? {
        guard let p = primaryIndex else { return buttons.firstIndex { $0.role != .cancel } }
        if buttons[p].role == .destructive, let c = cancelIndex { return c }
        return p
    }

    var cancelIndex: Int? { buttons.firstIndex { $0.role == .cancel } }

    /// The button that takes the keyboard focus when the dialog opens: Cancel when Return would press it (destructive
    /// dialogs), else none (the default button answers Return without holding the focus, a text field may take it).
    public var initialFocusIndex: Int? {
        guard let r = returnIndex, buttons[r].role == .cancel else { return nil }
        return r
    }

    /// The button Esc presses: an explicit `.cancel`; else a button titled "Cancel" (any case); else the only button
    /// of a one-button dialog; else none (a choice dialog must be answered).
    public var escapeIndex: Int? {
        if let i = cancelIndex { return i }
        if let i = buttons.firstIndex(where: { $0.title.caseInsensitiveCompare("Cancel") == .orderedSame }) { return i }
        return buttons.count == 1 ? 0 : nil
    }

    /// Cmd-D.
    public var dontSaveIndex: Int? { buttons.firstIndex { $0.role == .dontSave } }
    /// Cmd-S.
    public var saveIndex: Int? { buttons.firstIndex { $0.role == .save } }

    /// Button indices left to right, the fixed footer order: leading buttons ("Don't Save") alone on the left, then the
    /// other secondary actions, Cancel, and the main action last on the right. Within a group the first added button is
    /// the rightmost (the macOS way).
    public var displayOrder: [Int] {
        let p = primaryIndex
        func rank(_ i: Int) -> Int { i == p ? 2 : (buttons[i].role == .cancel ? 1 : 0) }
        let left = buttons.indices.filter { buttons[$0].isLeading && $0 != p }
        let right = buttons.indices.filter { !(buttons[$0].isLeading && $0 != p) }
            .sorted { (rank($0), -$0) < (rank($1), -$1) }
        return left + right
    }

    /// Response for a key press, nil when the key does nothing here.
    public func response(forReturn: Bool) -> Response? {
        (forReturn ? returnIndex : escapeIndex).map { Response($0) }
    }
}
