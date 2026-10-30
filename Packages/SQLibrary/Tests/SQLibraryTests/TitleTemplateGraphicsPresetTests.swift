import Foundation
import SQCore
import Testing
@testable import SQLibrary

@Suite struct TitleTemplateGraphicsPresetTests {
    @Test func graphicsSlotSurvivesTheLibrary() throws {
        let id = UUID(), layer = UUID()
        var track = Track(kind: .video)
        try track.overwrite(Clip(id: id, name: "G", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero))
        let content = Timeline(name: "G", frameDuration: Time(1, 30), tracks: [track])
        let slot = TemplateSlot(name: "Text 1", kind: .text, layer: id, graphicsLayer: layer, path: "template.text", value: .text("Hi"))
        let t = TitleTemplate(name: "G", content: content, slots: [slot])
        let item = try TitleTemplatePreset(template: t, thumbnail: nil).presetItem(name: "G")
        let back = try TitleTemplatePreset(preset: item)
        #expect(back.template.slots.first?.graphicsLayer == layer)
    }
}
