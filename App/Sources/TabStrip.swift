import AppKit
import SSEditorUI

/// Capsule tabs of a panel group (DESIGN.md: pane tab strip). Real NSButtons, drawn flat by the layer.
@MainActor
final class TabStrip: NSView {
    private var buttons: [(PanelID, TabButton)] = []
    var onSelect: ((PanelID) -> Void)?
    /// A tab was pressed: the owner runs the click-or-drag session (`DockDragSession`).
    var onPress: ((PanelID, NSView, NSEvent) -> Void)?

    /// Tab capsule frames in strip order, in strip coordinates.
    var tabFrames: [CGRect] { buttons.map { $0.1.frame } }

    static let height = Theme.Metrics.panelHeader

    override var isFlipped: Bool { true }

    init(panels: [PanelID], selected: PanelID) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        for p in panels {
            let b = TabButton(title: EditorCommand.panelTitle(p))
            b.isSelectedTab = p == selected
            b.target = self
            b.action = #selector(tapped(_:))
            b.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            b.setAccessibilityLabel(EditorCommand.panelTitle(p))
            addSubview(b)
            buttons.append((p, b))
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: TabButton) {
        guard let p = PanelID(rawValue: sender.identifier?.rawValue ?? "") else { return }
        onSelect?(p)
    }

    fileprivate func pressed(_ button: TabButton, _ event: NSEvent) {
        guard let p = PanelID(rawValue: button.identifier?.rawValue ?? "") else { return }
        if let onPress { onPress(p, button, event) } else { onSelect?(p) }
    }

    override func layout() {
        super.layout()
        var x = Theme.Spacing.sm
        let h: CGFloat = 22
        for (_, b) in buttons {
            let w = b.intrinsicContentSize.width
            b.isHidden = x + w > bounds.width   // a narrow group shows the tabs that fit
            b.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            x += w + Theme.Spacing.xs
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class TabButton: NSButton {
    var isSelectedTab = false { didSet { refresh() } }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        focusRingType = .none
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        (superview as? TabStrip)?.pressed(self, event)
    }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: Theme.Fonts.small]).width
        return NSSize(width: ceil(w) + 20, height: 22)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func refresh() {
        layer?.backgroundColor = isSelectedTab ? Theme.Colors.fill.cgColor : NSColor.clear.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: isSelectedTab ? Theme.Fonts.smallName : Theme.Fonts.small,
            .foregroundColor: isSelectedTab ? Theme.Colors.label : Theme.Colors.label2,
        ])
        setAccessibilityValue(isSelectedTab ? "selected" : "")
    }
}

/// One tab group: strip on top, the selected panel's view below. The panel views are owned by `EditorPanels` and
/// re-parented here on every layout rebuild.
@MainActor
final class PanelContainerView: NSView {
    let panels: [PanelID]
    let selected: PanelID
    let strip: TabStrip
    private let content: NSView

    override var isFlipped: Bool { true }

    init(panels: [PanelID], selected: PanelID, content: NSView, onSelect: @escaping (PanelID) -> Void) {
        self.panels = panels; self.selected = selected; self.content = content
        strip = TabStrip(panels: panels, selected: selected)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        layer?.masksToBounds = true          // a panel can never draw over its neighbours
        strip.onSelect = onSelect
        addSubview(strip)
        content.removeFromSuperview()
        content.autoresizingMask = []
        addSubview(content)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabStrip.height)
        content.frame = CGRect(x: 0, y: TabStrip.height, width: bounds.width, height: max(bounds.height - TabStrip.height, 0))
    }
}
