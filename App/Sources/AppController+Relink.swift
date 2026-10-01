import AppKit
import SQCore

/// Missing-media dialog after opening a project: offers to search a folder for the offline files and relinks them.
extension AppController {
    func offerRelinkIfNeeded() {
        let missing = session.missingMedia
        guard !missing.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = missing.count == 1 ? "1 media file is offline" : "\(missing.count) media files are offline"
        let names = missing.prefix(5).map(\.name).joined(separator: ", ")
        alert.informativeText = "Not found: \(names)\(missing.count > 5 ? ", …" : ""). Choose the folder they moved to and Sequence Studio will find them by file name."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Skip")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                self.chooseRelinkFolder(for: missing)
            }
        }
    }

    private func chooseRelinkFolder(for missing: [MediaRef]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that contains the offline media (subfolders are searched too)"
        panel.prompt = "Search"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        shell.statusBar.flash("Searching \(dir.lastPathComponent)…", seconds: 30)
        Task {
            let wanted = Set(missing.map { ($0.path as NSString).lastPathComponent.lowercased() })
            let found = await Task.detached(priority: .userInitiated) { Self.scan(dir, wanted: wanted) }.value
            let plan = RelinkPlanner.plan(missing: missing, candidates: found)
            session.relinkMedia(plan)
            shell.statusBar.flash(plan.count == missing.count ? "Relinked \(plan.count) media files."
                                  : "Relinked \(plan.count) of \(missing.count) media files.", seconds: 6)
        }
    }

    nonisolated private static func scan(_ dir: URL, wanted: Set<String>) -> [RelinkCandidate] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [RelinkCandidate] = []
        for case let url as URL in e where wanted.contains(url.lastPathComponent.lowercased()) {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            out.append(RelinkCandidate(path: url.path, size: Int64(v?.fileSize ?? -1)))
        }
        return out
    }
}
