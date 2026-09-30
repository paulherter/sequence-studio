import AppKit
import SSCore
import SSEditorUI
import SSExport
import SSPlayback
import SwiftUI

struct ExportSequenceMissing: LocalizedError {
    var errorDescription: String? { "The sequence no longer exists." }
}

/// Export sheet and queue popover. Jobs render the project as it was when the sheet opened: decoded video through
/// the compositor (text, nesting), mixed audio, sidecar SRT (`ExportSourceBuilder`).
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
        let timelines = Dictionary(uniqueKeysWithValues: session.project.timelines.map { ($0.id, $0) })
        let resolver = session.media
        let mediaIDs = session.project.media.map(\.id)
        let model = ExportDialogModel(sequences: items) { id, settings in
            guard let timeline = timelines[id] else { throw ExportSequenceMissing() }
            await resolver.prepare(mediaIDs)
            return try ExportSourceBuilder.make(timeline: timeline, sequences: timelines, settings: settings, resolver: resolver)
        }
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
