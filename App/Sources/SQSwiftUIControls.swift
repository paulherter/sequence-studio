import AppKit
import SQEditorUI
import SwiftUI

/// SwiftUI hosts for the flat SQ controls, so SwiftUI windows (Start, Card import) use the same widgets as AppKit ones.

struct SQSegmentedView: NSViewRepresentable {
    var labels: [String]
    var symbols: [SQIcon?] = []
    var segmentWidth: CGFloat = 0
    @Binding var selection: Int

    func makeNSView(context: Context) -> SQSegmented {
        let v = SQSegmented(labels: labels, segmentWidth: segmentWidth, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        v.images = symbols.map { $0.flatMap { Theme.symbol($0, size: 12, label: $0.rawValue) } }
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }
    func updateNSView(_ v: SQSegmented, context: Context) {
        context.coordinator.parent = self
        // Labels carry live counts (Card Import "Videos (24)"): keep them current.
        for (i, l) in labels.enumerated() where v.label(forSegment: i) != l { v.setLabel(l, forSegment: i) }
        if v.selectedSegment != selection { v.selectedSegment = selection }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: SQSegmentedView
        init(_ p: SQSegmentedView) { parent = p }
        @objc func changed(_ s: SQSegmented) { parent.selection = s.selectedSegment }
    }
}

struct SQPopupView: NSViewRepresentable {
    var titles: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> SQPopup {
        let p = SQPopup(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.target = context.coordinator; p.action = #selector(Coordinator.changed(_:))
        p.setContentHuggingPriority(.required, for: .horizontal)
        return p
    }
    func updateNSView(_ p: SQPopup, context: Context) {
        context.coordinator.parent = self
        if p.itemTitles != titles { p.removeAllItems(); p.addItems(withTitles: titles) }
        if p.indexOfSelectedItem != selection { p.selectItem(at: selection) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: SQPopupView
        init(_ p: SQPopupView) { parent = p }
        @objc func changed(_ p: SQPopup) { parent.selection = p.indexOfSelectedItem }
    }
}

struct SQCheckboxView: NSViewRepresentable {
    @Binding var isOn: Bool

    func makeNSView(context: Context) -> SQCheckbox {
        let c = SQCheckbox(title: "", target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.setContentHuggingPriority(.required, for: .horizontal)
        return c
    }
    func updateNSView(_ c: SQCheckbox, context: Context) {
        context.coordinator.parent = self
        c.state = isOn ? .on : .off
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: SQCheckboxView
        init(_ p: SQCheckboxView) { parent = p }
        @objc func changed(_ c: SQCheckbox) { parent.isOn = c.state == .on }
    }
}
