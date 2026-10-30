import AppKit
import SQCore
import SQEditorUI

/// Clip > Pixel Aspect: the same choices and the same model call as the Project item's context menu, applied to the
/// media items selected in the Project panel. Disabled unless the selection is media with a picture.
@MainActor
final class PixelAspectMenuTarget: NSObject, NSMenuItemValidation {
    weak var owner: AppController?
    private var rows: [(item: NSMenuItem, aspect: PixelAspect?)] = []   // aspect nil = From File
    private let custom = NSMenuItem(title: SQL10n.string("Custom Ratio…"), action: nil, keyEquivalent: "")

    /// The submenu entries in order, built once.
    func makeItems() -> [NSMenuItem] {
        func row(_ title: String, _ aspect: PixelAspect?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self
            rows.append((i, aspect))
            return i
        }
        var out = [row("From File", nil), .separator()]
        out += PixelAspectMenu.named.map { row("\($0.title) (\(PixelAspectMenu.ratioText($0.aspect)))", $0.aspect) }
        custom.target = self; custom.action = #selector(pickCustom(_:))
        return out + [.separator(), custom]
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let state = owner?.panels.projectView.selectionPixelAspectState() else {
            if rows.contains(where: { $0.item === item }) || item === custom { item.state = .off }
            return false
        }
        if let r = rows.first(where: { $0.item === item }) {
            if r.aspect == nil {
                item.title = state.sharedFile.map { "From File (\(PixelAspectMenu.ratioText($0)))" } ?? "From File"
                item.state = state.fromFile ? .on : .off
            } else {
                item.state = state.sharedChoice == r.aspect ? .on : .off
            }
        } else if item === custom {
            let c = state.sharedChoice
            let isCustom = c.map { a in !PixelAspectMenu.named.contains { $0.aspect == a } } ?? false
            item.state = isCustom ? .on : .off
            item.title = isCustom ? "Custom (\(PixelAspectMenu.ratioText(c!)))\u{2026}" : "Custom Ratio…"
        }
        return true
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let r = rows.first(where: { $0.item === sender }) else { return }
        owner?.panels.projectView.setSelectionPixelAspect(r.aspect)
    }

    @objc private func pickCustom(_ sender: NSMenuItem) { owner?.panels.projectView.customSelectionPixelAspect() }
}
