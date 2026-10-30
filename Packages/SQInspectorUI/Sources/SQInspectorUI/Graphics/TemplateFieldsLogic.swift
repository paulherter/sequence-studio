import Foundation
import SQCore
import SQText

/// G10: the template fields a graphics clip would make (`TitleTemplate.capture` + the style slots of
/// `EditorSession.titleTemplateFromSelection`), as display rows for the Graphics panel.
enum TemplateFieldsLogic {
    struct Field: Equatable { var title: String; var value: String }

    static func fields(of clip: Clip) -> [Field] {
        guard clip.isGraphics, let doc = clip.graphics else { return [] }
        var out: [Field] = []
        var first: TextTemplate?
        for l in doc.layers {
            guard case let .text(ref) = l.content else { continue }
            let t = (try? TextGenerator.decode(ref))?.0
            if first == nil { first = t }
            out.append(Field(title: SQL10n.format("Text %@", String(out.count + 1)), value: t?.text ?? ""))
        }
        guard let t = first else { return out }
        out.append(Field(title: "Color", value: "First text"))
        out.append(Field(title: "Font", value: t.style.fontName))
        out.append(Field(title: "Size", value: String(Int(t.style.size.rounded()))))
        return out
    }
}
