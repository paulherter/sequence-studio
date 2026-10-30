import AppKit
import DiskArbitration
import Quartz
import QuickLookThumbnailing
import SQEditorUI
import SQLibrary
import SwiftUI

/// Watches volume mounts and opens one import window per card.
@MainActor
final class CardImportCoordinator {
    /// Imports the (already copied) files into the project library.
    var importFiles: ([URL]) async -> Void = { _ in }
    /// Folder next to the saved project file (asks to save an untitled project first); nil when canceled.
    var projectFolder: () async -> URL? = { nil }
    /// True while a card copy and import runs: the project folder watcher waits so it never sees half-written files.
    var watchPause: (Bool) -> Void = { _ in }
    private var windows: [String: CardImportWindowController] = [:]
    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?["NSDevicePath"] as? String) ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated { if let path { self?.mounted(URL(fileURLWithPath: path, isDirectory: true)) } }
        }
    }

    private func mounted(_ url: URL) {
        guard CardImportSettings.enabled, let facts = Self.facts(for: url), facts.isImportSource else { return }
        open(volume: url)
    }

    func open(volume url: URL) {
        let key = url.path
        if let w = windows[key] { w.show(); return }
        let w = CardImportWindowController(
            volume: url, importFiles: { [weak self] in await self?.importFiles($0) },
            projectFolder: { [weak self] in await self?.projectFolder() },
            watchPause: { [weak self] in self?.watchPause($0) })
        w.onClose = { [weak self] in self?.windows[key] = nil }
        windows[key] = w
        w.show()
    }

    nonisolated static func facts(for url: URL) -> VolumeFacts? {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeFacts(url: url, isInternal: v.volumeIsInternal ?? true, isRemovable: v.volumeIsRemovable ?? false,
                           isEjectable: v.volumeIsEjectable ?? false, isLocal: v.volumeIsLocal ?? true, isBrowsable: v.volumeIsBrowsable ?? true,
                           isDiskImage: isDiskImage(url))
    }
}

extension CardImportCoordinator {
    /// DiskArbitration reports mounted .dmg files with the device model "Disk Image".
    nonisolated static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        if (desc[kDADiskDescriptionDeviceModelKey as String] as? String) == "Disk Image" { return true }
        return (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) == "Virtual Interface"
    }
}

// MARK: Model

@MainActor @Observable
final class CardImportModel {
    enum Layout: String { case list, grid }

    let volume: URL
    var kind: CardMediaKind = .video { didSet { selection.prune(to: visibleIDs); if let p = previewID, !visibleIDs.contains(p) { previewID = nil } } }
    var sort: CardSort = .newestFirst
    var layout: Layout = .grid     // board: the picture grid
    private(set) var all: [CardCandidate] = []
    private(set) var scanning = true
    private(set) var selection = CardSelection()
    var previewID: String?
    private(set) var busy = false
    private(set) var status = ""
    var importFiles: ([URL]) async -> Void = { _ in }
    var onDone: () -> Void = {}
    var projectFolder: () async -> URL? = { nil }
    var watchPause: (Bool) -> Void = { _ in }
    var cardRemoved = false
    private let resultBox = CopyResultBox()

    init(volume: URL) { self.volume = volume }

    var visible: [CardCandidate] { sort.apply(all.filter { $0.kind == kind }) }
    var visibleIDs: [String] { visible.map(\.id) }
    var selectedIDs: Set<String> { selection.ids }
    var count: (video: Int, photo: Int) { (all.filter { $0.kind == .video }.count, all.filter { $0.kind == .photo }.count) }
    var previewURL: URL? { previewID.flatMap { id in all.first { $0.id == id }?.url } }

    func scan() {
        let root = volume
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { CardScanner.scan(root) }.value
            all = found
            scanning = false
            selection.prune(to: visibleIDs)
        }
    }

    func click(_ id: String, toggle: Bool = false) {
        let flags = NSEvent.modifierFlags
        selection.click(id, in: visibleIDs, shift: flags.contains(.shift), toggle: toggle || flags.contains(.command))
        previewID = id
    }

    func selectAll() { selection.selectAll(visibleIDs) }

    /// Copy & Import: copies the selection to `<project folder>/Media` and imports the copies.
    /// Import without Copying: references the files on the card.
    func importSelected(copy: Bool) {
        let chosen = visible.filter { selection.ids.contains($0.id) }
        guard !chosen.isEmpty, !busy else { return }
        busy = true
        watchPause(true)
        Task {
            var urls = chosen.map(\.url)
            var failed: [String] = []
            if copy {
                status = "Preparing…"
                guard let folder = await projectFolder() else { busy = false; watchPause(false); status = "Import canceled."; return }
                let dest = folder.appendingPathComponent("Media", isDirectory: true)
                let sources = urls
                let box = resultBox
                let stream = AsyncStream<Int> { c in
                    Task.detached(priority: .userInitiated) {
                        let r = CardCopier.copy(sources, to: dest) { done, _ in c.yield(done) }
                        c.yield(-1 - r.copied.count)   // sentinel; results read below
                        box.set(r)
                        c.finish()
                    }
                }
                for await done in stream where done >= 0 { status = SQL10n.format("Copying %@ of %@…", String(min(done + 1, chosen.count)), String(chosen.count)) }
                let r = box.take()
                urls = r.copied; failed = r.failed
                selection.deselect(Set(r.copiedSources.map(\.path)))
            }
            status = SQL10n.string("Importing…")
            await importFiles(urls)
            busy = false
            watchPause(false)
            if failed.isEmpty { onDone() } else {
                // Only the failed files stay selected, so a retry does not copy the others again.
                status = SQL10n.format("%@ of %@ files could not be copied.", String(failed.count), String(chosen.count)) }
        }
    }
}

// MARK: Window

@MainActor
final class CardImportWindowController: NSObject {
    private var sheet: SQModalSheet?
    private let model: CardImportModel
    var onClose: () -> Void = {}

    private var unmountToken: NSObjectProtocol?
    private var selectAllButton: SQButton?
    private var importButtons: [SQButton] = []
    private var statusLabel: NSTextField?

    @objc private func selectAll() { model.selectAll() }
    @objc private func importWithoutCopying() { model.importSelected(copy: false) }
    @objc private func copyAndImport() { model.importSelected(copy: true) }

    /// Keeps the AppKit footer in step with the observable model (selection, busy, status).
    private func syncFooter() {
        guard sheet != nil else { return }
        let (empty, selected, busy, status) = withObservationTracking {
            (model.visible.isEmpty, model.selectedIDs.count, model.busy, model.status)
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncFooter() }
        }
        selectAllButton?.isEnabled = !empty
        for b in importButtons { b.isEnabled = selected > 0 && !busy }
        statusLabel?.stringValue = status.isEmpty ? "\(selected) selected" : status
    }

    init(volume: URL, importFiles: @escaping ([URL]) async -> Void, projectFolder: @escaping () async -> URL?,
         watchPause: @escaping (Bool) -> Void = { _ in }) {
        model = CardImportModel(volume: volume)
        super.init()
        model.importFiles = importFiles
        model.watchPause = watchPause
        model.projectFolder = projectFolder
        let path = volume.standardizedFileURL.path
        unmountToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let gone = (note.userInfo?["NSDevicePath"] as? String) ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            if let gone, URL(fileURLWithPath: gone).standardizedFileURL.path == path {
                MainActor.assumeIsolated { self?.close() }
            }
        }
        model.onDone = { [weak self] in self?.close() }
    }

    /// Opens the L modal over the main window; a second call while it shows does nothing.
    func show() {
        guard sheet == nil else { return }
        guard let host = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            closed()
            return
        }
        let view = NSHostingView(rootView: CardImportView(model: model))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: SQDialogMetrics.lBodyHeight).isActive = true
        let width = Theme.Modal.widthL
        let title = SQDialogText(.title, "Import from \(model.volume.lastPathComponent)", width: width - SQDialogMetrics.sidePad * 2)
        func button(_ title: String, _ action: Selector, accent: Bool = false, help: String? = nil) -> SQButton {
            let b = SQButton(title: title, target: self, action: action, style: accent ? .accent : .standard)
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.sqToolTip = help
            return b
        }
        let all = button("Select All", #selector(selectAll))
        let plain = button("Import without Copying", #selector(importWithoutCopying),
                           help: "Uses the files on the card directly. The card has to stay connected to play them.")
        let copy = button("Copy & Import", #selector(copyAndImport), accent: true,
                          help: "Copies the files into the Media folder next to your project, then imports the copies.")
        copy.keyEquivalent = "\r"
        let status = SQDialog.caption("")
        status.textColor = Theme.Colors.label3
        status.setContentHuggingPriority(.required, for: .horizontal)
        selectAllButton = all; importButtons = [plain, copy]; statusLabel = status
        let footer = SQDialog.footerRow(left: [all], right: [status, plain, copy])
        let card = SQDialog.cardContent(title: title, note: nil, body: view, footer: footer, width: width)
        let m = SQModalSheet(card: card) { [weak self] in self?.close() }
        sheet = m
        syncFooter()
        model.scan()
        m.present(over: host)
    }

    /// The card while the modal shows (render harness).
    var cardView: NSView? { sheet?.window.scrim.card }

    func close() {
        sheet?.dismiss()
        sheet = nil
        closed()
    }

    private func closed() {
        if let t = unmountToken { NSWorkspace.shared.notificationCenter.removeObserver(t); unmountToken = nil }
        onClose()
    }

    /// Render harness: the board's state (some tiles ticked, the first one previewed).
    func applyRenderState(selecting picks: [Int], preview: Int) {
        let v = model.visible
        for i in picks where v.indices.contains(i) { model.click(v[i].id, toggle: true) }
        if v.indices.contains(preview) { model.previewID = v[preview].id }
    }
}

// MARK: Views

private struct CardImportView: View {
    @Bindable var model: CardImportModel
    private var line: some View { Rectangle().fill(Quiet.color(Theme.Colors.separator)).frame(height: 1) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            line
            HStack(spacing: 0) {
                content.background(Quiet.color(Theme.Colors.content))
                Rectangle().fill(Quiet.color(Theme.Colors.separator)).frame(width: 1)
                preview
            }
        }
        .background(Quiet.color(Theme.Colors.overlay))
    }

    /// Board: 4 above, 22 high controls (capsule), 10 below, 16 at the sides, 12 between.
    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            SQSegmentedView(labels: ["Videos (\(model.count.video))", "Photos (\(model.count.photo))"],
                            segmentWidth: 0,
                            selection: Binding(get: { model.kind == .video ? 0 : 1 }, set: { model.kind = $0 == 0 ? .video : .photo }))
                .frame(height: Theme.Metrics.capsule)
            Spacer()
            SQPopupView(titles: CardSort.allCases.map(\.title),
                        selection: Binding(get: { CardSort.allCases.firstIndex(of: model.sort) ?? 0 },
                                           set: { model.sort = CardSort.allCases[$0] }))
                .frame(width: 150, height: Theme.Metrics.capsule)
            SQSegmentedView(labels: ["", ""], symbols: [.list, .grid], segmentWidth: 40,
                            selection: Binding(get: { model.layout == .list ? 0 : 1 }, set: { model.layout = $0 == 0 ? .list : .grid }))
                .frame(height: Theme.Metrics.capsule)
        }
        .padding(.top, 4).padding(.horizontal, Theme.Spacing.lg).padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if model.scanning {
            Text("Reading card…").font(Quiet.font).foregroundStyle(Quiet.label3).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visible.isEmpty {
            Text(model.kind == .video ? "No videos on this card." : "No photos on this card.")
                .font(Quiet.font).foregroundStyle(Quiet.label3).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.layout == .list {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { c in CardRow(model: model, item: c) }
                }
            }
            .scrollIndicators(.hidden)
        } else {
            ScrollView {
                // Board: 140 wide tiles, 12 across, 14 down, 16 around.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 140), spacing: 12, alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    ForEach(model.visible) { c in CardCell(model: model, item: c) }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Board: 300 wide, 16 padding; the picture 168 high with 6 corners, then the name and a note (date and size).
    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CardPreview(url: model.previewURL)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            if let id = model.previewID, let item = model.visible.first(where: { $0.id == id }) {
                Text(item.name).font(Quiet.fontName).foregroundStyle(Quiet.label).lineLimit(1).truncationMode(.middle)
                Text("\(item.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))) · \(SQByteSize.string(item.size))")
                    .font(Quiet.fontMini).foregroundStyle(Quiet.label3)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 301, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct CardRow: View {
    let model: CardImportModel
    let item: CardCandidate
    var body: some View {
        let selected = model.selectedIDs.contains(item.id)
        HStack(spacing: Theme.Spacing.md) {
            SQCheckboxView(isOn: Binding(get: { selected }, set: { _ in model.click(item.id, toggle: true) }))
                .frame(width: 12, height: 12)
            CardThumb(url: item.url, size: 20)
            Text(item.name).font(Quiet.font).foregroundStyle(Quiet.label).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(item.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))).font(Quiet.fontMini).foregroundStyle(Quiet.label3)
            Text(SQByteSize.string(item.size))
                .font(Quiet.fontMini).foregroundStyle(Quiet.label3).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Quiet.rowHeight)
        .background(selected ? Quiet.color(Theme.Selection.fill) : (model.previewID == item.id ? Quiet.color(Theme.Selection.hover) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.click(item.id) }
    }
}

private struct CardCell: View {
    let model: CardImportModel
    let item: CardCandidate
    var body: some View {
        let selected = model.selectedIDs.contains(item.id)
        let active = model.previewID == item.id
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                CardThumb(url: item.url, size: 80, fill: true)
                    .frame(width: 140, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay { if active { RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Quiet.color(Theme.Colors.yellow), lineWidth: 2) } }
                SQCheckboxView(isOn: Binding(get: { selected }, set: { _ in model.click(item.id, toggle: true) }))
                    .frame(width: 12, height: 12).padding(6)
            }
            Text(item.name).font(Quiet.font).foregroundStyle(Quiet.label).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        .onTapGesture { model.click(item.id) }
    }
}

private struct CardThumb: View {
    let url: URL
    let size: CGFloat
    var fill = false
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Quiet.color(Theme.Colors.fill2))
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .modifier(ThumbFrame(fill: fill, size: size))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size * 2, height: size * 2),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = rep.nsImage }
        }
    }
}

/// Quick Look preview of the last clicked file (plays videos with the standard controls).
private struct CardPreview: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.autostarts = false
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        let item = url as NSURL?
        if (v.previewItem as? NSURL) != item { v.previewItem = item }
    }
}

/// Hands the copy result from the background task to the main actor.
final class CopyResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CardCopyResult()
    func set(_ r: CardCopyResult) { lock.lock(); value = r; lock.unlock() }
    func take() -> CardCopyResult { lock.lock(); defer { lock.unlock() }; return value }
}

private struct ThumbFrame: ViewModifier {
    let fill: Bool
    let size: CGFloat
    func body(content: Content) -> some View {
        if fill { content }
        else { content.frame(width: size * 1.4, height: size) }
    }
}
