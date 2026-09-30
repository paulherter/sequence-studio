import AppKit
import SSCore
import SSEditorUI
import SSExport
import SwiftUI

struct RendererNotConnected: LocalizedError {
    var errorDescription: String? { "The export renderer is not connected to the editor yet." }
}

/// Export sheet and queue popover. The queue and dialog are real; the frame source is not wired to the compositor yet,
/// so a submitted job fails with `RendererNotConnected` (shown in the queue).
@MainActor
final class ExportCoordinator {
    let queue = ExportQueue()
    private(set) lazy var queueModel = ExportQueueModel(queue: queue)
    private var popover: NSPopover?
    private var sheet: NSWindow?

    func presentDialog(for session: EditorSession, on window: NSWindow) {
        let items = session.project.timelines.map {
            ExportDialogModel.SequenceItem(id: $0.id, name: $0.name, duration: $0.duration, inOut: $0.inOut)
        }
        guard !items.isEmpty else { NSSound.beep(); return }
        let model = ExportDialogModel(sequences: items) { _, _ in throw RendererNotConnected() }
        if let id = session.activeTimelineID, items.contains(where: { $0.id == id }) {
            model.selectedID = id
            model.checkedIDs = [id]
        }
        let view = ExportDialogView(model: model,
                                    onExport: { [weak self] in self?.chooseFolderAndSubmit(model, window: window) },
                                    onCancel: { [weak self] in self?.closeSheet(on: window) })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        w.appearance = NSAppearance(named: .darkAqua)
        sheet = w
        window.beginSheet(w)
    }

    private func closeSheet(on window: NSWindow) {
        if let s = sheet { window.endSheet(s) }
        sheet = nil
    }

    private func chooseFolderAndSubmit(_ model: ExportDialogModel, window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported files"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        closeSheet(on: window)
        queueModel.start()
        Task { await model.submit(to: queue, outputDirectory: dir) }
    }

    func showQueue(relativeTo rect: CGRect, of view: NSView) {
        if let p = popover, p.isShown { p.close(); return }
        queueModel.start()
        let p = NSPopover()
        p.behavior = .transient
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = NSHostingController(rootView: ExportQueueView(model: queueModel))
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
    }
}
