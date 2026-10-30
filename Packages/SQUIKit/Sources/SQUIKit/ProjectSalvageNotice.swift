import SQCore

/// The one notice shown after a damaged project file opened with parts dropped.
public enum ProjectSalvageNotice {
    public static let title = "Opened with parts left out"
    /// Longest list shown; the rest is counted.
    public static let maxLines = 8

    public static func detail(fileName: String, report: ProjectSalvageReport) -> String {
        let shown = report.dropped.prefix(maxLines).map { "• \($0)" }
        var lines = shown
        if report.dropped.count > maxLines { lines.append("… and \(report.dropped.count - maxLines) more") }
        return "Parts of “\(fileName)” could not be read and were left out:\n\n" + lines.joined(separator: "\n")
            + "\n\nThe original file was not changed. Save asks for a new place; the project stays unsaved until you do."
    }
}
