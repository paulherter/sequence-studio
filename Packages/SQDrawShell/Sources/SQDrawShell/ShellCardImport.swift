import Foundation
import SQCore
import SQUIKit
import SQLibrary
import SQEditorSession

/// Import from a camera card (the Mac CardImportWindow): what the card holds, which kinds to take, then Copy & Import
/// (into `<project folder>/Media`, an untitled project is saved first) or Import without Copying (the files stay on the card).
/// The files are picked in `ShellCardBrowser` (kind, sort, list or grid, preview).
/// shortcut: the dialog closes when the import starts (the Mac window stays and keeps only the failed files ticked);
/// keep it open when a failed copy needs a retry often.
public enum ShellCardImport {
    /// The dialog's Select All button (the third one added).
    static let selectAll = ShellDialog.Response(2)
    /// What Esc and a vanished volume answer: the header close button answers the same.
    static let cancel = ShellDialog.Response(-1)
    /// A card file's picture for the board (Windows: the FFmpeg thumbnail atlas); nil = the kind's icon.
    @MainActor public static var poster: ((CardCandidate) -> ProjectPoster?)?
    /// The board of the card dialog that shows last (tests).
    @MainActor public internal(set) static weak var current: ShellCardBrowser?
    /// The open card dialogs by volume path (closed when the volume goes away).
    @MainActor static var dialogs: [String: ShellDialog] = [:]

    /// "12 videos (8.4 GB), 30 photos (210 MB)".
    public static func summary(_ items: [CardCandidate]) -> String {
        func part(_ k: CardMediaKind, one: String, other: String) -> String? {
            let some = items.filter { $0.kind == k }
            guard !some.isEmpty else { return nil }
            return SQL10n.plural(some.count, one: one, other: other) + " (" + SQByteSize.string(some.reduce(0) { $0 + $1.size }) + ")"
        }
        return [part(.video, one: "%@ video", other: "%@ videos"), part(.photo, one: "%@ photo", other: "%@ photos")]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

extension ShellHost {
    /// A card or other import volume appeared (the platform's watcher calls this when Preferences > Media > Card Import
    /// is on). One dialog per volume; a second call for the same volume while it is up does nothing.
    /// `atLaunch`: a card that was already mounted when the app started is offered only once a project is open
    /// (never over the start window; the Mac app offers nothing at launch).
    public func openCardImport(volume: URL, atLaunch: Bool = false) {
        if atLaunch, isStartShown { return }
        let key = volume.standardizedFileURL.path
        guard !cardImportVolumes.contains(key) else { return }
        cardImportVolumes.insert(key)
        spawn {
            await self.cardImport(volume: volume)
            self.cardImportVolumes.remove(key)
        }
    }

    /// The volume went away (the platform's watcher): its import dialog closes like Cancel (the Mac window closes on unmount).
    public func closeCardImport(volume: URL) {
        ShellCardImport.dialogs[volume.standardizedFileURL.path]?.press(ShellCardImport.cancel)
    }

    func cardImport(volume: URL) async {
        let name = volume.lastPathComponent.isEmpty ? volume.path : volume.lastPathComponent
        onStatus?(SQL10n.format("Reading “%@”…", name))
        let items = await Task.detached(priority: .userInitiated) { CardScanner.scan(volume) }.value
        guard !items.isEmpty else { onStatus?(SQL10n.format("“%@” holds no videos or photos.", name)); return }
        let browser = ShellCardBrowser(items: items)
        browser.poster = ShellCardImport.poster
        let d = ShellDialog(SQL10n.format("Import from %@", name))
        d.width = ShellDialog.M.widthL
        d.content = browser
        d.sheetStyle = true
        d.footerStatus = { [weak browser] in browser?.statusText ?? "" }
        d.escapeResponse = ShellCardImport.cancel
        d.closeButton = true                                  // header close button answers like Esc
        d.addButton("Copy & Import")
        d.addButton("Import without Copying")
        d.addButton("Select All", leading: true)
        ShellCardImport.current = browser
        let key = volume.standardizedFileURL.path
        ShellCardImport.dialogs[key] = d
        defer { ShellCardImport.dialogs[key] = nil }
        // Select All keeps the dialog open; an import with nothing ticked says so instead of closing.
        d.canClose = { [weak self, weak browser] r in
            guard let browser else { return true }
            if r == ShellCardImport.selectAll { browser.selectAll(); return false }
            if r == .first || r == .second, browser.selected.isEmpty {
                self?.flash("Tick the files to import first.")
                return false
            }
            return true
        }
        let r = await ask(d)
        guard r == .first || r == .second else { return }
        await importFromCard(browser.selected.map(\.url), copy: r == .first)
    }

    /// Copies (or not) and imports into the Project panel; the failed files are named.
    func importFromCard(_ sources: [URL], copy: Bool) async {
        guard let model = projectModel else { flash("Import is not available yet."); return }
        var urls = sources
        var failed: [String] = []
        if copy {
            if session.fileURL == nil {
                flash("Save the project first: the copies go into its folder.")
                guard await saveDocumentAs(), session.fileURL != nil else { flash("Import canceled."); return }
            }
            guard let file = session.fileURL else { return }
            let dest = file.deletingLastPathComponent().appendingPathComponent("Media", isDirectory: true)
            let total = sources.count
            let box = ShellCardCopyBox()
            let stream = AsyncStream<Int> { c in
                Task.detached(priority: .userInitiated) {
                    let r = CardCopier.copy(sources, to: dest) { done, _ in c.yield(done) }
                    c.yield(-1)
                    box.set(r)
                    c.finish()
                }
            }
            for await done in stream where done >= 0 {
                onStatus?(SQL10n.format("Copying %@ of %@…", String(min(done + 1, total)), String(total)))
            }
            let r = box.take()
            urls = r.copied
            failed = r.failed
        }
        if !urls.isEmpty {
            onStatus?(SQL10n.string("Importing…"))
            await model.importFiles(urls)
            onProjectChanged?()
        }
        if failed.isEmpty {
            onStatus?(SQL10n.plural(urls.count, one: "Imported %@ file from the card.", other: "Imported %@ files from the card."))
        } else {
            let shown = failed.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            presentMessage("Some files were not copied",
                           SQL10n.format("%@ of %@ files could not be copied:", String(failed.count), String(sources.count)) + "\n" + shown)
        }
    }
}

/// Hands the copy result from the detached copy back to the flow (the Mac `resultBox`).
final class ShellCardCopyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = CardCopyResult()
    func set(_ r: CardCopyResult) { lock.lock(); result = r; lock.unlock() }
    func take() -> CardCopyResult { lock.lock(); defer { lock.unlock() }; let r = result; result = CardCopyResult(); return r }
}
