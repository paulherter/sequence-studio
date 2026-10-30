import Foundation

/// The start window's lifecycle where the start screen has a window of its own (the Mac, `ShellHost.startWindowSize`),
/// translated from AppController+Start (`showStartWindow`, `closeStartWindow`, `startWindowClosedByUser`, `showEditorWindow`):
/// the start screen opens in its own window; without a real project the editor window goes away meanwhile (never an empty
/// editor), with one (Window > Start Window) the editor stays where it is. Opening or creating a project hides the start
/// window and brings the editor window up. The host applies `steps` to its two windows after each frame.
public enum ShellStartWindows {
    /// What the windows show now.
    public struct State: Equatable, Sendable {
        public var startShown: Bool
        public var startVisible: Bool
        public var editorVisible: Bool
        public var hasRealProject: Bool
        public init(startShown: Bool, startVisible: Bool, editorVisible: Bool, hasRealProject: Bool) {
            self.startShown = startShown; self.startVisible = startVisible
            self.editorVisible = editorVisible; self.hasRealProject = hasRealProject
        }
    }

    public enum Step: Equatable, Sendable { case showStart, hideStart, showEditor, hideEditor }

    /// The window changes that bring the windows in line with the shell, in order. The start window shows before the
    /// editor hides (hiding the only visible window first quit the AppKit app).
    public static func steps(_ s: State) -> [Step] {
        if s.startShown {
            var out: [Step] = s.startVisible ? [] : [.showStart]
            if !s.hasRealProject, s.editorVisible { out.append(.hideEditor) }
            return out
        }
        var out: [Step] = []
        if !s.editorVisible { out.append(.showEditor) }
        if s.startVisible { out.append(.hideStart) }
        return out
    }
}

extension ShellHost {
    /// The steps for the host's windows now (`ShellStartWindows.steps` with this shell's start screen and project).
    public func startWindowSteps(startVisible: Bool, editorVisible: Bool) -> [ShellStartWindows.Step] {
        ShellStartWindows.steps(.init(startShown: isStartShown, startVisible: startVisible, editorVisible: editorVisible,
                                      hasRealProject: !session.isEmptyUntitled))
    }

    /// The start window's close button (`startWindowClosedByUser`): back to the open project, or quit (with the unsaved
    /// changes question) when there is none.
    public func startWindowClosedByUser() {
        if session.isEmptyUntitled { perform(.quit) } else { hideStart() }
    }

    /// The editor window became the key window while the start window is up over a real project: the start window goes.
    /// shortcut: the Mac start window stays open behind the editor; here it closes, because the shell has one modal start
    /// screen that would otherwise take the editor's keys. Upgrade when the start screen stops being modal for the shell.
    public func editorWindowActivated() {
        if startWindowSize != nil, isStartShown, !session.isEmptyUntitled { hideStart() }
    }
}
