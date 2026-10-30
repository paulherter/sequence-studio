import Foundation
import SQCore

extension ProjectListView {
    /// Reveal in Project (the Mac `ProjectPanelView.reveal(media:)`): clears the search, opens every folder above the
    /// item, selects it and scrolls its row into view.
    public func reveal(media id: MediaRef.ID) {
        guard let model else { return }
        if !searchText.isEmpty { setSearchText("") }
        let root = model.project.rootBin
        var up = root.parent(of: .media(id))
        while let b = up, b != root.id {
            if !expanded.contains(b) { toggle(b) }
            up = root.parent(of: .bin(b))
        }
        selection = [.media(id)]
        guard viewMode == .list, let i = rows().firstIndex(where: { $0.ref == .media(id) }) else { return }
        let top = CGFloat(i) * Self.rowHeight, h = listRect.height
        if top < scroll { scroll = top } else if h > 0, top + Self.rowHeight > scroll + h { scroll = top + Self.rowHeight - h }
    }
}
