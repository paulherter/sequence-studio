import AppKit

/// Dropping `.sqpack` files on the Library panel imports them; dropping `.mogrt` files hands them to the host's template
/// import (the menu's code path). Anything else is refused, so the panel's own
/// drag-out behavior is untouched.
extension LibraryPanelView {
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { LibraryPackFlow.isPack($0) || isTemplateFile($0) }
    }

    private func isTemplateFile(_ url: URL) -> Bool {
        canImportDroppedTemplates && url.pathExtension.lowercased() == "mogrt"
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        let packs = files.filter(LibraryPackFlow.isPack), templates = files.filter(isTemplateFile)
        if !packs.isEmpty { importDroppedPacks(packs) }
        if !templates.isEmpty { importDroppedTemplates(templates) }
        return true
    }
}
