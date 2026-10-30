import Foundation
import SQCore

/// Decisions behind Quick Export (EXP-34), kept out of the App target so they can be tested.
@MainActor
public enum QuickExport {
    /// Where Quick Export writes: `Exports/` next to a saved project (created), else the folder of the last export
    /// (if it still exists), else ~/Movies (`moviesDirectory`), else the temporary directory.
    public static func directory(projectFile: URL?, lastDirectory: String?, moviesDirectory: URL?,
                                 fileManager fm: FileManager = .default) -> URL {
        if let file = projectFile {
            let dir = MediaManagement.exportsFolder(forProjectAt: file)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil { return dir }
        }
        if let p = lastDirectory, fm.fileExists(atPath: p) { return URL(fileURLWithPath: p, isDirectory: true) }
        return moviesDirectory ?? fm.temporaryDirectory
    }

    /// Status line for a Quick Export that covers only In to Out ("Exporting In to Out, 0:12"); nil for the whole sequence.
    public static func rangeNotice(for model: ExportDialogModel) -> String? {
        guard case .inOut(let r) = model.settings.range else { return nil }
        let secs = Int((Double(r.duration.value) / Double(r.duration.timescale)).rounded())
        return SQL10n.format("Exporting In to Out, %@:%@", String(secs / 60), String(format: "%02d", secs % 60))
    }

    /// The sequence's own platform preset (and loudness target) stays; a sequence without a delivery target uses the
    /// last preset exported with, when that preset still exists.
    public static func applyPreset(to model: ExportDialogModel, lastPresetID: String?) {
        guard model.sequences.first(where: { $0.id == model.selectedID })?.deliveryTarget == nil,
              let last = lastPresetID, model.presets.contains(where: { $0.id == last }) else { return }
        model.presetID = last
    }
}
