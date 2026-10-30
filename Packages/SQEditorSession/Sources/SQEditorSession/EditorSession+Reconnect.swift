import Foundation
import SQCore
import SQLibrary

extension EditorSession {
    /// Reconnect from one find: looks around the picked file or folder (that folder, its parent and siblings, the same
    /// folder on other volumes) and scores every media file there against all offline media. Changes nothing; the dialog
    /// shows the result as a checklist. Lengths are probed only for files that could matter. Off the main thread.
    public func proposeReconnect(from picked: URL, volumes: [URL]? = nil) async -> RelinkScorer.Result {
        let missing = missingMedia
        guard !missing.isEmpty else { return RelinkScorer.Result() }
        let projectID = project.id
        let vols = volumes ?? ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? [])
        let probe = mediaInfoProbe
        let found: [RelinkCandidate] = await Task.detached(priority: .userInitiated) {
            let roots = RelinkScanner.reconnectRoots(picked: picked, volumes: vols)
            var files = RelinkScanner.scanMedia(roots: roots, isMedia: { ext in
                let kind = LibraryItemKind.classify(URL(fileURLWithPath: "/x." + ext))
                return kind == .video || kind == .image || kind == .audio
            })
            var probed = 0
            for i in files.indices where probed < 300 && RelinkScorer.worthProbing(files[i], for: missing) {
                if Task.isCancelled { break }
                probed += 1
                files[i].duration = await probe(URL(fileURLWithPath: files[i].path))?.duration
            }
            return files
        }.value
        guard project.id == projectID else { return RelinkScorer.Result() }
        let result = RelinkScorer.propose(missing: missingMedia, candidates: found)
        SQLog.info("reconnect: \(picked.path) -> \(found.count) files, \(result.proposals.count) proposed, \(result.proposals.filter(\.isChecked).count) strong")
        return result
    }

    /// Applies the ticked rows of a reconnect checklist (one undo step), keeping only items that are still offline.
    @discardableResult
    public func applyReconnect(_ proposals: [RelinkProposal]) -> Int {
        let still = Set(missingMedia.map(\.id))
        let plan = Dictionary(proposals.filter { still.contains($0.mediaID) }.map { ($0.mediaID, $0.path) }, uniquingKeysWith: { a, _ in a })
        guard !plan.isEmpty else { return 0 }
        stopPlayback()
        relinkMedia(plan, name: "Reconnect Media")
        return plan.count
    }
}
