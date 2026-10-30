import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Color panel's foot (the Mac `ColorInspectorView` "Input color" header, closed at start): Interpret As, Log
/// Handling, Deliver As, HDR Conform and Project Input; the folded header reads the Interpret As choice. Also the
/// sliders' color ramps (the Mac `ColorParam.Track`).
extension ColorGradeDraw {
    func inputRows(_ model: ColorInspectorModel, add: (Row) -> Void, full: CGRect,
                   box: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect) {
        let hh = Mac.sectionGap + Mac.section
        add(Row(label: "Input color", style: .section, y: 0, height: hh,
                controls: [(.inputSection, CGRect(x: 0, y: 0, width: size.width, height: hh))],
                summary: inputTitle(.interpret), open: inputOpen))
        guard inputOpen else { return }
        let popup = CGRect(x: Mac.topControlX, y: ((Mac.popupRow - CGFloat(DrawTheme.Metrics.capsule)) / 2).rounded(),
                           width: max(size.width - Mac.inset - Mac.topControlX, 0), height: CGFloat(DrawTheme.Metrics.capsule))
        func row(_ label: String, _ c: Control, _ f: CGRect, height: CGFloat = Mac.popupRow) {
            add(Row(label: label, style: .plain, y: 0, height: height, controls: [(c, f)], labelX: Mac.inset))
        }
        row("Interpret As", .input(.interpret), popup)
        row("Log Handling", .input(.logMode), popup)
        row("Deliver As", .input(.deliver), popup)
        row("HDR Conform", .conform, CGRect(x: Mac.topControlX, y: 0, width: max(size.width - Mac.inset - Mac.topControlX, 0), height: 30), height: 30)
        row("Project Input", .input(.project), popup)
    }

    /// The popup's current title.
    func inputTitle(_ r: InputRow) -> String {
        guard let m = model else { return "" }
        switch r {
        case .interpret: return m.sourceOverride?.displayName ?? ColorInputChoices.automaticTitle(detected: m.detectedSource)
        case .logMode: return ColorInputChoices.title(m.logMode)
        case .deliver: return ColorInputChoices.title(m.targetSpace)
        case .project: return m.projectInput?.displayName ?? ColorInputChoices.noProjectInput
        }
    }

    /// The popup's items, the current one checked (InputPickerView, FootageRows).
    func inputMenu(_ r: InputRow) -> [SQMenuItem] {
        guard let m = model else { return [] }
        func spaces(current: ColorSpaceID?, automatic: String, set: @escaping @MainActor (ColorSpaceID?) -> Void) -> [SQMenuItem] {
            [SQMenuItem(title: automatic, isChecked: current == nil) { set(nil) }]
                + ColorInputChoices.shown(current: current).map { s in
                    SQMenuItem(title: s.displayName, isChecked: current == s) { set(s) }
                }
        }
        switch r {
        case .interpret:
            return spaces(current: m.sourceOverride, automatic: ColorInputChoices.automaticTitle(detected: m.detectedSource)) { s in
                m.gesture { m.setSourceOverride(s) }
            }
        case .project:
            return spaces(current: m.projectInput, automatic: ColorInputChoices.noProjectInput) { m.setProjectInput($0) }
        case .logMode:
            return LogMode.allCases.map { l in SQMenuItem(title: ColorInputChoices.title(l), isChecked: m.logMode == l) { m.setLogMode(l) } }
        case .deliver:
            return TargetSpace.allCases.map { t in
                SQMenuItem(title: ColorInputChoices.title(t), isChecked: m.targetSpace == t) { m.setTargetSpace(t) }
            }
        }
    }

    func inputHelp(_ k: Control) -> String? {
        switch k {
        case .input(.logMode): "How log footage reaches the picture: through the Input LUT, through the built-in transform, or not at all."
        case .input(.deliver): "The space the conversion delivers. The monitors and export render Rec. 709 today."
        case .input(.project): "Applies to every untagged clip in the project that is set to Automatic."
        case .conform: "Rolls HLG and PQ highlights into the SDR range before the grade. Off clips them."
        default: nil
        }
    }

    /// The slider's track: Temperature, Tint and the Saturation / Vibrance rows show their color ramp.
    func ramp(_ s: Slider) -> InspectorColorRamp {
        let t: ColorParam.Track
        switch s {
        case .param(_, let p): t = p.track
        case .range(_, let p): t = p.track
        case .sharpen, .zoneSat, .step, .primary, .stepQual, .window, .mix: t = .plain
        }
        switch t {
        case .plain: return .plain
        case .temperature: return .temperature
        case .tint: return .tint
        case .saturation: return .saturation
        }
    }
}
