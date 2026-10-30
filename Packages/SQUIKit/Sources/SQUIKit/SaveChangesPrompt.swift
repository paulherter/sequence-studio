import Foundation

/// The "Save changes?" question (the dialog: `makeDialog` in SQEditorUI on the Mac, `ShellDialog` in SQDrawShell) of every place that can discard a document (open, new, close, quit): one button set,
/// one order (board, left to right: Don’t Save, Cancel, Save), Return and Cmd-S = Save, Esc = Cancel, Cmd-D = Don’t Save (alone on the left).
public enum SaveChangesPrompt {
    public enum Choice: Equatable, Sendable { case save, cancel, dontSave }

    /// In the order they are added to the dialog (the first sits rightmost).
    public static let buttons: [SQDialogModel.Button] = [
        .init(title: "Save", role: .save),
        .init(title: "Cancel", role: .cancel),
        .init(title: "Don’t Save", role: .dontSave),
    ]

    public static func choice(_ response: SQDialogModel.Response) -> Choice {
        switch response {
        case .first: .save
        case .third: .dontSave
        default: .cancel
        }
    }

    /// What the caller does after the question (and, for Save, after the write): carry on with the quit / close /
    /// replace, or stay in the project. A failed save never counts as a decision to leave: the project stays open
    /// (the error dialog already told why) and the user asks again.
    public enum Outcome: Equatable, Sendable { case proceed, stay }

    /// `saveSucceeded` is only read for `.save`; pass nil when no write happened.
    public static func outcome(_ choice: Choice, saveSucceeded: Bool?) -> Outcome {
        switch choice {
        case .dontSave: .proceed
        case .cancel: .stay
        case .save: saveSucceeded == true ? .proceed : .stay
        }
    }

    /// Second line of the dialog: a never-saved project says it asks for a place next.
    public static func detail(hasFile: Bool) -> String {
        hasFile ? "Your changes are lost if you don’t save them."
            : "Your changes are lost if you don’t save them. This project was never saved: Save asks for a place."
    }
}
