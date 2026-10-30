import Foundation

/// The status bar's save state, one pure function of what is true on disk. "Autosave" writes a recovery copy in the
/// Autosave folder, never the project file, so the project file is only ever "Saved" after the user (or a
/// Save-on-quit) wrote it; until then it is "Edited". The dirty flag is `EditorSession.isDirty`, the same one the
/// top bar's "Edited ..." text reads.
public struct SaveStatus: Equatable, Sendable {
    public enum Kind: Sendable { case saved, edited, unsavedNew, empty }
    public var kind: Kind
    public var text: String

    /// - isDirty: edits since the last write to the project file.
    /// - hasFile: the project has been saved to a file at least once.
    /// - lastEdit: when the project last changed (nil when unknown).
    /// - lastBackup: when the recovery copy was last written (nil when none this session).
    public static func make(isDirty: Bool, hasFile: Bool, lastEdit: Date?, lastBackup: Date?,
                            timeZone: TimeZone = .current) -> SaveStatus {
        guard isDirty else {
            return hasFile ? SaveStatus(kind: .saved, text: "Saved") : SaveStatus(kind: .empty, text: "No changes")
        }
        var text = hasFile ? "Edited" : "Not saved"
        // A backup counts only when it was written after the last edit; an older one does not cover the change.
        if let b = lastBackup, lastEdit.map({ b >= $0 }) ?? true { text += " · Backup " + clock(b, timeZone) }
        return SaveStatus(kind: hasFile ? .edited : .unsavedNew, text: text)
    }

    static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
