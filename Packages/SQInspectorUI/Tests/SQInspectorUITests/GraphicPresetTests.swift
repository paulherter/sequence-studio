import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

// CREATOR 7: built-in stickers and lower thirds are Graphics clips (layers of shapes and text), so every part stays
// editable in the Graphics panel and no media or project-file field is needed.

@MainActor @Suite struct GraphicPresetTests {
    private func session(w: Int = 1080, h: Int = 1920) -> EditorSession {
        let t = Timeline(name: "Main", format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)),
                         tracks: [Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func catalogHasTheAskedSetWithUniqueIDs() {
        let stickers = GraphicPresetCatalog.all.filter { $0.category == .sticker }
        let lower = GraphicPresetCatalog.all.filter { $0.category == .lowerThird }
        #expect(stickers.count >= 7 && lower.count == 6)
        #expect(Set(GraphicPresetCatalog.all.map(\.id)).count == GraphicPresetCatalog.all.count)
        let names = Set(stickers.map(\.name))
        for n in ["Arrow", "Circle", "Swipe Up", "Link in Bio"] { #expect(names.contains(n)) }
        #expect(stickers.filter { $0.name.hasPrefix("Pop ") }.count >= 3)              // emoji pops
        #expect(GraphicPresetCatalog.entry(id: lower[0].id)?.name == lower[0].name)
        #expect(GraphicPresetCatalog.entry(id: "nope") == nil)
    }

    @Test func calloutSetHasOwnNamedItemsThatFadeInAndOut() throws {
        let callouts = GraphicPresetCatalog.all.filter { $0.category == .callout }
        #expect(callouts.count >= 5)
        for e in callouts {
            let layers = try e.layers(canvasWidth: 1080, canvasHeight: 1920)
            for l in layers {
                let a = l.animation
                // Opacity (or scale) animates both in and out: invisible at the first and the last frame.
                let last = e.duration
                #expect(a.opacity.value(atLocal: .zero) < 0.05 || a.scale.value(atLocal: .zero).x < 0.05, "\(e.name)/\(l.name) in")
                #expect(a.opacity.value(atLocal: last) < 0.05 || a.scale.value(atLocal: last).x < 0.05, "\(e.name)/\(l.name) out")
                #expect(a.opacity.value(atLocal: Time(2, 1)) > 0.95 || a.scale.value(atLocal: Time(2, 1)).x > 0.5, "\(e.name)/\(l.name) holds")
            }
        }
    }

    @Test(arguments: [(1080, 1920), (1920, 1080), (1080, 1080)])
    func everyPresetBuildsInsideTheCanvasAndPopsIn(w: Int, h: Int) throws {
        for e in GraphicPresetCatalog.all {
            let layers = try e.layers(canvasWidth: w, canvasHeight: h)
            #expect(!layers.isEmpty, "\(e.name)")
            #expect(e.duration > .zero)
            for l in layers {
                for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let at = Time(Int64((t * Double(e.duration.value) * 100).rounded()), e.duration.timescale * 100)
                    let p = l.animation.position.value(atLocal: at)
                    #expect(abs(p.x) <= Double(w) / 2 + 1 && abs(p.y) <= Double(h) / 2 + 1, "\(e.name)/\(l.name) at \(t)")
                }
                // Starts hidden (scale 0, opacity 0 or off to the side), so the first frame is not a hard cut.
                let a = l.animation
                let hidden = a.scale.value(atLocal: .zero).x < 0.05 || a.opacity.value(atLocal: .zero) < 0.05
                    || abs(a.position.value(atLocal: .zero).x) > Double(w) / 2 * 0.5
                #expect(hidden, "\(e.name)/\(l.name) is visible on its first frame")
            }
        }
    }

    @Test func lowerThirdsHaveEditableNameAndRoleText() throws {
        for e in GraphicPresetCatalog.all where e.category == .lowerThird {
            let layers = try e.layers(canvasWidth: 1920, canvasHeight: 1080)
            let texts = layers.filter(\.isText)
            #expect(texts.map(\.name) == ["Name", "Role"], "\(e.name)")
            guard case .text(let ref) = texts[0].content else { Issue.record("text"); continue }
            #expect(try TextGenerator.decode(ref).0.text == "Your Name")
            // Sits in the lower third of the frame.
            #expect(texts[0].animation.position.value(atLocal: e.duration - Time(1, 2)).y > 1080 * 0.1)
        }
    }

    @Test func stickerLayersUseOnlyShapesAndText() throws {
        for e in GraphicPresetCatalog.all {
            for l in try e.layers(canvasWidth: 1080, canvasHeight: 1920) {
                switch l.content { case .shape, .text, .path: break }
            }
        }
    }

    @Test func commandPlacesOneGraphicsClipAsOneUndoStep() throws {
        let s = session()
        let e = try #require(GraphicPresetCatalog.all.first { $0.name == "Swipe Up" })
        let depth = s.undoDepth
        let id = try #require(s.addGraphicPreset(e.id, at: Time(2, 1)))
        #expect(s.undoDepth == depth + 1)
        let clip = try #require(s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(clip.isGraphics && clip.start == Time(2, 1) && clip.timeline.duration == e.duration)
        #expect((clip.graphics?.layers.count ?? 0) >= 2)
        s.undo()
        #expect(s.activeTimeline?.tracks.lazy.flatMap(\.clips).isEmpty == true)
    }

    @Test func unknownIDIsRefused() {
        let s = session()
        #expect(s.addGraphicPreset("missing") == nil)
    }

    @Test func libraryListsThemAndDropPlacesThem() throws {
        let stickers = TextTemplateCatalog.all.filter { $0.kindLabel == "Sticker" }
        let lower = TextTemplateCatalog.all.filter { $0.kindLabel == "Lower Third" }
        #expect(stickers.count == GraphicPresetCatalog.all.filter { $0.category == .sticker }.count && lower.count == 6)
        #expect(TextTemplateCatalog.all.filter { $0.name.lowercased().contains("lower third") }.count == 6)
        let e = try #require(lower.first)
        #expect(e.graphicPresetID == e.id && !e.isCTA)
        let s = session()
        #expect(s.addGraphicPreset(try #require(e.graphicPresetID)) != nil)
    }

    @Test func libraryFilterFindsThemByName() {
        #expect(GraphicPresetCatalog.matching("swipe").map(\.name) == ["Swipe Up"])
        #expect(GraphicPresetCatalog.matching("").count == GraphicPresetCatalog.all.count)
        #expect(GraphicPresetCatalog.matching("BAR").map(\.name) == ["Bar"])
        #expect(GraphicPresetCatalog.matching("pop").count >= 3)
    }
}
