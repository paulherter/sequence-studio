import Foundation
import SQCore
import SQExport

/// What the user should know before an export starts (offline, damaged and HDR media, masks without a track or a matte,
/// a failed audio check, little disk space) and the question about files that already exist. Moved out of the Mac
/// `ExportCoordinator` so the AppKit app and the shared shell ask exactly the same things.
public enum ExportPreflightReport {
    public struct Report: Equatable, Sendable {
        public var lines: [String]
        public var title: String
        public var isEmpty: Bool { lines.isEmpty }
    }

    /// The notes for `model`'s selected sequence exporting into `dir`. `untrackedMagicFrames` counts Magic mask frames
    /// without a matte (the matte store lives in the platform layer); nil counts none.
    @MainActor
    public static func build(model: ExportDialogModel, project: Project, directory dir: URL,
                             untrackedMagicFrames: ((Timeline, [Timeline.ID: Timeline]) -> Int)? = nil) async -> Report {
        guard let tl = project.timelines.first(where: { $0.id == model.selectedID }) else { return Report(lines: [], title: "") }
        let sequences = Dictionary(project.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unlinked = tl.unlinkedPictureMaskCount(sequences: sequences)
        let n = untrackedMagicFrames?(tl, sequences) ?? 0
        let offline = ExportPreflight.offlineMedia(in: tl.id, project: project)
        var lines: [String] = []
        func list(_ refs: [MediaRef]) -> String {
            let shown = refs.prefix(5).map { "• \($0.name)" }.joined(separator: "\n")
            return shown + (refs.count > 5 ? "\n• and \(refs.count - 5) more" : "")
        }
        func plural(_ c: Int, _ one: String, _ other: String) -> String { c == 1 ? one : other }
        if !offline.isEmpty {
            lines.append("\(offline.count) media file\(plural(offline.count, " is", "s are")) offline and export as the offline picture:\n\(list(offline))\nReconnect them first (File > Reconnect Media…).")
        }
        if unlinked > 0 {
            lines.append("\(unlinked) Picture mask\(plural(unlinked, " is", "s are")) set to No track and cut\(plural(unlinked, "s", "")) nothing. Pick a track in the mask row.")
        }
        if n > 0 {
            lines.append("Magic mask not tracked on \(n) frame\(plural(n, "", "s")): those frames export without the mask. Select the clip, then Track Forward / Backward in its mask row.")
        }
        // The audio check ran in the dialog and found a failure (clipping, silent mix, level off target): say so again.
        let audioFails = model.audioCheckFailures
        if !audioFails.isEmpty {
            lines.append("Audio check failed:\n" + audioFails.map { "• \($0.message)" }.joined(separator: "\n"))
        }
        // Files that are there but cannot be read: their frames export as the damaged placeholder (or stop the export).
        let damaged = await ExportPreflight.unreadableMedia(in: tl.id, project: project)
        if !damaged.isEmpty {
            let outcome = model.continueOnDamagedFrames
                ? "their frames export as the damaged-frame placeholder"
                : "the export stops at the first damaged frame (turn on Continue on damaged frames to export the rest)"
            lines.append("\(damaged.count) media file\(plural(damaged.count, " is", "s are")) damaged or unreadable; \(outcome):\n\(list(damaged))")
        }
        // HDR sources: the export is Rec. 709 only, so HLG / PQ media is tone-mapped to SDR.
        let hdr = ExportPreflight.hdrMedia(in: tl.id, project: project)
        if !hdr.isEmpty {
            lines.append("\(hdr.count) media file\(plural(hdr.count, " is", "s are")) HDR. The export is Rec. 709 (SDR) only, so the picture is converted and will look flatter than on an HDR display:\n\(list(hdr))")
        }
        // The estimate against the free space of the output volume (the queue also watches it while exporting).
        let estimate = model.estimatedBytes
        let verdict = ExportPreflight.spaceVerdict(freeBytes: ExportPreflight.freeBytes(at: dir), estimatedBytes: estimate)
        if verdict != .ok, let free = ExportPreflight.freeBytes(at: dir) {
            let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
            lines.append(verdict == .insufficient
                ? "The output disk has \(gb(free)) free and the export needs about \(gb(estimate)). It will probably stop before it is done. Pick another folder or free some space."
                : "The output disk has \(gb(free)) free and the export needs about \(gb(estimate)): little room is left over.")
        }
        let flags: [Bool] = [!offline.isEmpty, unlinked > 0, n > 0, !audioFails.isEmpty, !damaged.isEmpty, verdict != .ok, !hdr.isEmpty]
        let kinds = flags.filter { $0 }.count
        let title = kinds > 1 ? "Check before exporting"
            : !damaged.isEmpty ? "Media is damaged"
            : verdict != .ok ? "Not much disk space"
            : !audioFails.isEmpty ? "Audio check failed"
            : !offline.isEmpty ? "Media is offline"
            : !hdr.isEmpty ? "Media is HDR"
            : unlinked > 0 ? "Picture mask without a track" : "Magic mask not tracked"
        return Report(lines: lines, title: title)
    }

    /// The question when files of the new export are already in the folder: its title and message (Keep Both / Replace);
    /// nil when none exists.
    public static func existingFilesQuestion(_ existing: [URL]) -> (title: String, message: String)? {
        guard !existing.isEmpty else { return nil }
        let names = existing.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
        let more = existing.count > 3 ? " and \(existing.count - 3) more" : ""
        let what = existing.count == 1 ? "\(names) already exists" : "\(names)\(more) already exist"
        return ("\(what) in this folder",
                "Keep Both saves the new export with a number added to its name. Replace overwrites the existing file.")
    }
}
