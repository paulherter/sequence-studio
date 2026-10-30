import AppKit
import SQCore

/// The three footage rows under "Interpret As": Log Handling (camera LUT / built-in transform / off), Deliver As (the
/// space the conversion delivers) and the automatic HDR conform switch.
@MainActor
final class FootageRows: NSObject {
    let logPopup = SQPopup(frame: .zero, pullsDown: false)
    let targetPopup = SQPopup(frame: .zero, pullsDown: false)
    let conformBox = SQCheckbox(title: "Convert HDR automatically", target: nil, action: nil)
    let logRow: ColorControlRow
    let targetRow: ColorControlRow
    let conformRow: ColorControlRow
    var onLogMode: (LogMode) -> Void = { _ in }
    var onTarget: (TargetSpace) -> Void = { _ in }
    var onConform: (Bool) -> Void = { _ in }

    static func title(_ m: LogMode) -> String { ColorInputChoices.title(m) }
    static func title(_ t: TargetSpace) -> String { ColorInputChoices.title(t) }

    override init() {
        logRow = ColorControlRow(title: "Log Handling", controls: [logPopup], top: true, height: ColorGrid.popupRow)
        targetRow = ColorControlRow(title: "Deliver As", controls: [targetPopup], top: true, height: ColorGrid.popupRow)
        conformRow = ColorControlRow(title: "HDR Conform", controls: [conformBox], stretchFirst: false, top: true)
        super.init()
        for p in [logPopup, targetPopup] {
            p.font = Theme.Typography.body
            p.target = self
        }
        logPopup.action = #selector(logChanged)
        targetPopup.action = #selector(targetChanged)
        for m in LogMode.allCases { logPopup.addItem(withTitle: Self.title(m)) }
        for t in TargetSpace.allCases { targetPopup.addItem(withTitle: Self.title(t)) }
        conformBox.target = self
        conformBox.action = #selector(conformChanged)
        logPopup.setAccessibilityLabel("Log handling")
        targetPopup.setAccessibilityLabel("Deliver footage as")
        conformBox.setAccessibilityLabel("Convert HDR automatically")
        logPopup.sqToolTip = "How log footage reaches the picture: through the Input LUT, through the built-in transform, or not at all."
        targetPopup.sqToolTip = "The space the conversion delivers. The monitors and export render Rec. 709 today."
        conformBox.sqToolTip = "Rolls HLG and PQ highlights into the SDR range before the grade. Off clips them."
    }

    func reload(logMode: LogMode, target: TargetSpace, conform: Bool) {
        logPopup.selectItem(at: LogMode.allCases.firstIndex(of: logMode) ?? 0)
        targetPopup.selectItem(at: TargetSpace.allCases.firstIndex(of: target) ?? 0)
        conformBox.state = conform ? .on : .off
    }

    @objc private func logChanged() { onLogMode(LogMode.allCases[max(0, logPopup.indexOfSelectedItem)]) }
    @objc private func targetChanged() { onTarget(TargetSpace.allCases[max(0, targetPopup.indexOfSelectedItem)]) }
    @objc private func conformChanged() { onConform(conformBox.state == .on) }
}
