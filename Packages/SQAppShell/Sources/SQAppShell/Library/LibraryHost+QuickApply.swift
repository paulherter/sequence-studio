import SQDrawLibrary
import SQDrawShell
import SQEditorSession

extension LibraryHost {
    /// Quick Apply's entries and the user presets of the shell's popup come from the Library (the AppKit window reads the
    /// same `LibraryPanelModel.presets`). `library` is asked on use, so a host can keep its Library panel lazy.
    public static func connectQuickApply(shell: ShellHost, library: @escaping @MainActor () -> LibraryHost?) {
        shell.libraryPresets = { library()?.model.presets ?? [] }
        shell.quickApplyItems = { QuickApplyCatalog.items(presets: library()?.model.presets ?? []) }
    }
}
