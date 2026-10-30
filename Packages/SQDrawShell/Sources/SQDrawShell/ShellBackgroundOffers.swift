import Foundation
import SQCore
import SQEditorSession
import SQExport
import SQUIKit

/// The background relink offer for the status bar chip (the Mac `offerRelinkIfNeeded`): found files for offline media,
/// applied on a click as one undo step.
public struct ShellRelinkOffer: Equatable, Sendable {
    /// "Found 4 offline files · Reconnect".
    public var text: String
    var plan: [MediaRef.ID: String]
    var projectID: UUID

    /// The Mac chip text for `found` of `total` offline files.
    public static func text(found: Int, total: Int) -> String {
        found == total ? SQL10n.format("Found %@ offline files · Reconnect", String(total))
            : SQL10n.format("Found %@ of %@ offline files · Reconnect", String(found), String(total))
    }
}

/// The status bar's background parts for both shared shells: the relink offer after a project opens and the export
/// queue's progress ring (the Mac `AppController+Relink`, `watchExports`).
extension ShellHost {
    /// Never modal: first links the offline files beside the project file quietly (a copied project, `relinkNearProject`),
    /// then looks in their old folders and the folders Reconnect Media searched before and shows the chip; nothing when
    /// nothing is found (File > Reconnect Media… still works).
    public func offerRelinkIfNeeded() {
        relinkOffer = nil
        guard !session.missingMedia.isEmpty else { return }
        let folder = session.fileURL?.deletingLastPathComponent()
        let extra = (startDefaults.stringArray(forKey: Self.relinkFoldersKey) ?? []).map { URL(fileURLWithPath: $0) }
        let projectID = session.project.id
        spawn {
            // A copied project (Mac project on Windows, moved folder): media beside the project file links quietly first.
            let near = await self.session.relinkNearProject()
            guard self.session.project.id == projectID else { return }
            if near > 0 {
                self.onStatus?(SQL10n.plural(near, one: "Reconnected %@ media file.", other: "Reconnected %@ media files."))
                self.onProjectChanged?()
            }
            let total = self.session.missingMedia.count
            guard total > 0 else { return }
            let plan = await self.session.relinkOffer(projectFolder: folder, extraFolders: extra)
            guard !plan.isEmpty, self.session.project.id == projectID else { return }
            self.relinkOffer = ShellRelinkOffer(text: ShellRelinkOffer.text(found: plan.count, total: total), plan: plan,
                                                projectID: projectID)
        }
    }

    /// The chip's click: reconnects what is still offline (one undo step) and says how many.
    public func acceptRelinkOffer() {
        guard let offer = relinkOffer else { return }
        relinkOffer = nil
        guard offer.projectID == session.project.id else { return }
        let n = session.applyRelinkOffer(offer.plan)
        if n > 0 { onStatus?(SQL10n.plural(n, one: "Reconnected %@ media file.", other: "Reconnected %@ media files.")) }
    }

    /// The ring's fill for the jobs of one Export: finished jobs count whole; nil once none waits or runs.
    static func overallProgress(_ all: [(state: ExportJobState, progress: Double)]) -> Double? {
        let open = all.contains { $0.state == .waiting || $0.state == .running }
        guard open, !all.isEmpty else { return nil }
        let sum = all.reduce(0.0) { acc, s in
            switch s.state {
            case .waiting: acc
            case .running: acc + min(max(s.progress, 0), 1)
            case .done, .failed, .cancelled: acc + 1
            }
        }
        return sum / Double(all.count)
    }
}
