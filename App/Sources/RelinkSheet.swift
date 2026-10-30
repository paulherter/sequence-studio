import AppKit
import SQCore
import SQEditorUI
import SQUIKit

/// Missing-media sheet (own SQ look, no NSAlert): "Locate…" picks a folder, SQ scans it recursively and relinks by file
/// name (+ size when known), then shows "N of M found". More folders can be added; Done is always there; when everything
/// is found the sheet closes by itself. The folder chooser is a standalone NSOpenPanel (`begin`, not a nested modal
/// session run from inside a sheet's button action, which left the old dialog's Locate dead).
@MainActor
final class RelinkSheet: NSObject {
    private var keepAlive: RelinkSheet?
    private var sheet: SQModalSheet?
    private let session: EditorSession
    private let total: Int
    private let onFolderChosen: (URL) -> Void
    private let onClose: (_ found: Int, _ total: Int) -> Void
    private let title = SQDialogText(.title, width: 408)
    private let detail = SQDialogText(.note, width: 408)
    private var locate: SQButton!
    private var done: SQButton!
    private var folders: [URL] = []
    private var busy = false

    /// `onFolderChosen`: remember the folder for later imports. `onClose`: final counts.
    static func present(session: EditorSession, over window: NSWindow, onFolderChosen: @escaping (URL) -> Void,
                        onClose: @escaping (_ found: Int, _ total: Int) -> Void) {
        let s = RelinkSheet(session: session, onFolderChosen: onFolderChosen, onClose: onClose)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(session: EditorSession, onFolderChosen: @escaping (URL) -> Void, onClose: @escaping (Int, Int) -> Void) {
        self.session = session
        self.total = session.missingMedia.count
        self.onFolderChosen = onFolderChosen
        self.onClose = onClose
    }

    private func show(over window: NSWindow) {
        locate = SQButton(title: "Locate…", target: self, action: #selector(chooseFolder), style: .accent)
        done = SQButton(title: "Done", target: self, action: #selector(close), style: .standard)
        for b in [locate!, done!] {
            b.horizontalPadding = SQDialogMetrics.buttonPadding; b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        locate.keyEquivalent = "\r"
        let footer = SQDialog.footerRow(left: [SQMascotPlace.mediaOffline.makeView()].compactMap { $0 }, right: [done, locate])   // M14
        let content = SQDialog.cardContent(title: title, note: detail, body: nil, footer: footer, width: SQModal.Size.s.width)
        refresh()
        let w = SQModalSheet(card: content) { [weak self] in self?.close() }
        sheet = w
        w.present(over: window)
        SQLog.info("relink sheet: \(total) offline")
    }

    private var stillMissing: [MediaRef] { session.missingMedia }

    private func refresh(status: String? = nil) {
        let missing = stillMissing
        let found = max(0, total - missing.count)
        title.text = folders.isEmpty
            ? (total == 1 ? "1 media file is offline" : "\(total) media files are offline")
            : "\(found) of \(total) found"
        let names = missing.prefix(5).map { MediaPathResolver.fileName(of: $0.path) }.joined(separator: ", ")
        let more = missing.count > 5 ? ", …" : ""
        if let status {
            detail.text = status
        } else if folders.isEmpty {
            detail.text = "Not found: \(names)\(more). Choose the folder they are in; subfolders are searched too."
        } else {
            detail.text = "Still missing: \(names)\(more). Add another folder or click Done."
        }
        locate.title = folders.isEmpty ? "Locate…" : "Add Folder…"
        locate.isEnabled = !busy
        refreshSize()
    }

    private func refreshSize() { sheet?.resizeCard() }

    @objc private func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that contains the offline media (subfolders are searched too)"
        panel.prompt = "Search"
        SQLog.info("relink: folder chooser opened")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard response == .OK, let dir = panel.url else { SQLog.info("relink: chooser canceled"); return }
                self.scan(dir)
            }
        }
    }

    private func scan(_ dir: URL) {
        busy = true
        folders.append(dir)
        onFolderChosen(dir)
        refresh(status: SQL10n.format("Searching %@…", dir.lastPathComponent))
        Task { [weak self] in
            guard let self else { return }
            let r = await self.session.relinkMissing(searching: [dir])
            self.busy = false
            var note: String?
            if r.sizeDiffers > 0 {
                note = "\(r.sizeDiffers) file\(r.sizeDiffers == 1 ? "" : "s") with a matching name differ in size or are ambiguous: not linked."
            }
            if self.stillMissing.isEmpty { self.close(); return }
            self.refresh()
            if let note { self.detail.text += " " + note; self.refreshSize() }
        }
    }

    @objc private func close() {
        guard keepAlive != nil else { return }
        sheet?.dismiss(); sheet = nil
        let found = max(0, total - stillMissing.count)
        SQLog.info("relink sheet closed: \(found) of \(total) found")
        keepAlive = nil
        onClose(found, total)
    }
}
