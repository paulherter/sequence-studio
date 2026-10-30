import AppKit
import SQCore

/// One input color space choice of the Color page: "Interpret As" (per clip) and "Project Input" (project default).
/// One popup per row as on the design board: the first entry is Automatic / None (`automaticTitle`), then every color
/// space the camera profiles of W9.3 can describe (camera Log curves, SDR, HLG, PQ), each once.
@MainActor
final class InputPickerView: NSObject {
    let popup = SQPopup(frame: .zero, pullsDown: false)
    /// The row on the Color grid: label at the panel inset, the popup filling the rest.
    let row: ColorControlRow
    private let automaticTitle: () -> String
    private var shown: [ColorSpaceID] = []
    /// Called with the new override when the user picks something (nil = Automatic).
    var onChange: (ColorSpaceID?) -> Void = { _ in }

    /// Every color space the picker offers, in menu order, each once (`ColorInputChoices.spaces`).
    static var choices: [ColorSpaceID] { ColorInputChoices.spaces }

    init(label: String, automaticTitle: @escaping () -> String) {
        self.automaticTitle = automaticTitle
        row = ColorControlRow(title: label, controls: [popup], top: true, height: ColorGrid.popupRow)
        super.init()
        popup.font = Theme.Typography.body
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityLabel(label)
        reload(override: nil)
    }

    /// Shows `override` without calling `onChange`.
    func reload(override: ColorSpaceID?) {
        shown = ColorInputChoices.shown(current: override)
        popup.removeAllItems()
        popup.addItem(withTitle: automaticTitle())
        for s in shown { popup.addItem(withTitle: s.displayName) }
        popup.selectItem(at: override.flatMap { shown.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    @objc private func changed() {
        let i = popup.indexOfSelectedItem
        onChange(i <= 0 || i > shown.count ? nil : shown[i - 1])
    }
}

extension InputPickerState {
    /// The color space a camera / Log / range choice stands for.
    static func space(camera: CameraMake, log: Bool, range: DynamicRange) -> ColorSpaceID? {
        ColorInputChoices.space(camera: camera, log: log, range: range)
    }
}
