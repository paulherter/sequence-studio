import Foundation
import SQCore
import SQUIKit

extension PixelAspectChoices {
    /// The rows of the Pixel Aspect submenu. `pick(nil)` = From File; `custom` opens the ratio sheet.
    @MainActor
    public static func items(_ s: State, pick: @escaping @MainActor (PixelAspect?) -> Void,
                             custom: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        let fileText = s.sharedFile.map { "From File (\(ratioText($0)))" } ?? "From File"
        var rows = [SQMenuItem(title: fileText, isChecked: s.fromFile, action: { pick(nil) }), .separator]
        let choice = s.sharedChoice
        for n in named {
            rows.append(SQMenuItem(title: "\(n.title) (\(ratioText(n.aspect)))", isChecked: choice == n.aspect, action: { pick(n.aspect) }))
        }
        let isCustom = choice.map { c in !named.contains { $0.aspect == c } } ?? false
        rows += [.separator, SQMenuItem(title: isCustom ? "Custom (\(ratioText(choice!)))\u{2026}" : "Custom Ratio\u{2026}", isChecked: isCustom, action: custom)]
        return rows
    }
}
