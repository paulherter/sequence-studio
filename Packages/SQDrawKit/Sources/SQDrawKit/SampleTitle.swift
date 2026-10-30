import Foundation
import SQCore
import SQText

/// The title clip of the Windows comparison sample (`SampleProject.make(title:)`, scripts/win-app.sh with
/// SQ_SAMPLE_TITLE=1): bold Inter with kerning pairs, an outside stroke and a soft shadow, so the PC and Mac title rasters
/// are compared on the same text.
public enum SampleTitle {
    public static func ref() throws -> GeneratorRef {
        let style = TextStyle(size: 96, weight: .bold, stroke: TextStroke(color: RGBAColor(red: 0.1, green: 0.1, blue: 0.4), width: 3),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.7), offsetX: 4, offsetY: 4, blur: 8))
        return try TextGenerator.makeRef(template: TextTemplate(name: "Title", text: "AVATAR Toyota\nWave", style: style),
                                         animations: nil)
    }
}
