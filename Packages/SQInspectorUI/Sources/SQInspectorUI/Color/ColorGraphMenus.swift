import Foundation
import SQCore
import SQUIKit

/// The Color Graph's menus (Step, LUT, add, insert, mixer, canvas), shared by the Mac Pro page (`ColorGraphPage`) and the
/// portable Steps graph (`ColorStepsDraw`). The platform supplies what it shows itself: the file chooser, renaming,
/// Tidy Up (which also refits the view) and the color decision import.
@MainActor public struct ColorGraphMenus {
    public enum LUTTarget: Sendable { case graphInput, graphOutput, step }

    public let model: ColorInspectorModel
    /// A .cube / .3dl file (nil = canceled); nil = no file chooser on this platform (Choose File… is disabled).
    public var chooseLUTFile: (@MainActor (@escaping @MainActor (String?) -> Void) -> Void)?
    public var rename: (@MainActor (UUID) -> Void)?
    public var tidyUp: @MainActor () -> Void
    public var importDecision: (@MainActor (UUID) -> Void)?

    public init(model: ColorInspectorModel, tidyUp: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.tidyUp = tidyUp ?? { [model] in model.tidyUpSteps() }
    }

    /// The entries of a LUT menu (None, Automatic for the In LUT, the library and recents, Choose File…).
    public func lutItems(_ t: LUTTarget) -> [SQMenuItem] {
        let model = model
        let current: ColorInspectorModel.LUTChoice? = switch t {
        case .graphInput: model.graphLUTChoice(.input)
        case .graphOutput: model.graphLUTChoice(.output)
        case .step: model.selectedStep.flatMap(model.stepLUTChoice)
        }
        let set: @MainActor (ColorInspectorModel.LUTChoice?) -> Void = { c in
            switch t {
            case .graphInput: model.setGraphLUT(.input, c)
            case .graphOutput: model.setGraphLUT(.output, c)
            case .step: if let id = model.selectedStep { model.setStepLUT(id, c) }
            }
        }
        var items: [SQMenuItem] = []
        if t == .graphInput {
            items.append(SQMenuItem(title: "Automatic", isChecked: current == .automatic, help: "The Simple rules: the camera LUT or the built-in conversion") { set(.automatic) })
        }
        items.append(SQMenuItem(title: t == .graphInput ? "None (built-in conversion)" : "None", isChecked: current == nil) { set(nil) })
        let looks = model.lookChoices
        if !looks.isEmpty {
            items.append(.separator)
            items.append(.header("Library"))
            for c in looks.prefix(20) { items.append(SQMenuItem(title: c.name, isChecked: c == current) { set(c) }) }
        }
        items.append(.separator)
        let choose = chooseLUTFile
        items.append(SQMenuItem(title: "Choose File…", isEnabled: choose != nil) {
            choose? { path in if let path { set(.file(path)) } }
        })
        return items
    }

    /// The Step's menu: everything about one Step (kind, effects and LUT live here and in the inspector).
    public func stepMenuItems(_ id: UUID) -> [SQMenuItem] {
        let model = model
        guard let g = model.graph, let i = g.steps.firstIndex(where: { $0.id == id }) else { return [] }
        let s = g.steps[i]
        let many = model.selectedSteps.count > 1 && model.selectedSteps.contains(id)
        let n = model.selectedSteps.count
        let rename = rename, tidyUp = tidyUp, importDecision = importDecision
        return [
            SQMenuItem(title: "Add Step Before", help: "Serial, in front of this Step") { model.addStepBefore(id) },
            SQMenuItem(title: "Add Serial Step") { model.addStep(after: id, kind: .serial) },
            SQMenuItem(title: "Add Parallel Step") { model.addStep(after: id, kind: .parallel) },
            SQMenuItem(title: "Add Layer Step") { model.addStep(after: id, kind: .layer) },
            .separator,
            SQMenuItem(title: "Rename…", isEnabled: !many && rename != nil) { rename?(id) },
            SQMenuItem(title: many ? (g.steps.filter { model.selectedSteps.contains($0.id) }.allSatisfy(\.enabled) ? SQL10n.format("Bypass %@ Steps", String(n)) : SQL10n.format("Turn On %@ Steps", String(n)))
                       : (s.enabled ? "Bypass" : "Turn On")) {
                if many { model.toggleSelectedSteps() } else { model.setStepEnabled(id, !s.enabled) }
            },
            SQMenuItem(title: "Duplicate", isEnabled: !many) { model.duplicateStep(id) },
            .separator,
            SQMenuItem(title: "Joins As", isEnabled: !many, submenu: StepKind.allCases.map { k in
                SQMenuItem(title: Self.kindTitle(k), isEnabled: i > 0 || k == .serial, isChecked: s.kind == k) { model.setStepKind(id, k) }
            }),
            SQMenuItem(title: "Tidy Up", isEnabled: g.steps.contains { $0.position != nil }) { tidyUp() },
            .separator,
            SQMenuItem(title: "Move Left", isEnabled: !many && i > 0) { model.moveStep(id, by: -1) },
            SQMenuItem(title: "Move Right", isEnabled: !many && i < g.steps.count - 1) { model.moveStep(id, by: 1) },
            .separator,
            SQMenuItem(title: "LUT", isEnabled: !many, submenu: lutItems(.step)),
            SQMenuItem(title: "Clear LUT", isEnabled: !many && s.lut != nil) { model.setStepLUT(id, nil) },
            SQMenuItem(title: "Import Color Decision…", isEnabled: !many && importDecision != nil, help: "ASC CDL (.cdl, .cc, .ccc) or CMX EDL") { importDecision?(id) },
            .separator,
            SQMenuItem(title: "Reset Step", isEnabled: !many && !s.isNeutral) { model.resetStep(id) },
            SQMenuItem(title: many ? SQL10n.format("Delete %@ Steps", String(n)) : (g.steps.count > 1 ? "Delete Step" : "Delete Step (resets the last one)")) {
                model.removeSelectedSteps()
            },
        ]
    }

    public static func kindTitle(_ k: StepKind) -> String {
        switch k {
        case .serial: "Serial (after the one before)"
        case .parallel: "Parallel (averaged)"
        case .layer: "Layer (over the result)"
        }
    }

    /// The "+" menu: where and how a new Step joins.
    public func addMenuItems() -> [SQMenuItem] {
        let model = model
        return [
            SQMenuItem(title: "Serial Step") { model.addStep(after: model.selectedStep, kind: .serial) },
            SQMenuItem(title: "Parallel Step") { model.addStep(after: model.selectedStep, kind: .parallel) },
            SQMenuItem(title: "Layer Step") { model.addStep(after: model.selectedStep, kind: .layer) },
            .separator,
            SQMenuItem(title: "Serial Step at the End") { model.addStepAtEnd(kind: .serial) },
        ]
    }

    /// A "+" on a wire: a new Step behind the column that ends there.
    public func insertMenuItems(after id: UUID) -> [SQMenuItem] {
        let model = model
        return [
            .header("Insert here"),
            SQMenuItem(title: "Serial Step") { model.addStep(after: id, kind: .serial) },
            SQMenuItem(title: "Parallel Step") { model.addStep(after: id, kind: .parallel) },
            SQMenuItem(title: "Layer Step") { model.addStep(after: id, kind: .layer) },
        ]
    }

    /// Right-click on a mixer box.
    public func mixerMenuItems(_ head: UUID) -> [SQMenuItem] {
        let model = model
        return [
            SQMenuItem(title: "Delete Mixer", help: "Its Steps become serial Steps in a row") { model.removeMixer(head) },
            SQMenuItem(title: "Reset Position", isEnabled: model.step(head)?.mixerPosition != nil) { model.setMixerPosition(head, nil) },
        ]
    }

    /// Right-click on empty canvas.
    public func canvasMenuItems() -> [SQMenuItem] {
        let tidyUp = tidyUp
        return addMenuItems() + [.separator, SQMenuItem(title: "Tidy Up") { tidyUp() }]
    }
}
