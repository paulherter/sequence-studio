import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Mac shared UI round 8: the Color panel as the AppKit `ColorInspectorView` shows it (folded sections at start, LUT
/// labels, color ramp tracks, the "Input color" foot).
@MainActor @Suite struct ColorRound8DrawTests {
    func rig() throws -> (EditorSession, ColorGradeDraw) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        let controller = ColorGradeController(session: session)
        controller.sync([.project, .selection])
        let panel = ColorGradeDraw(controller: controller)
        panel.size = CGSize(width: 340, height: 4000)
        return (session, panel)
    }

    @Test func onlyBasicAndCreativeAreOpenAtStartAndTheLUTRowsUseTheMacLabels() throws {
        let (_, panel) = try rig()
        let open = panel.rows.filter { $0.style == .section && $0.open }.compactMap(\.label)
        #expect(open == [ColorSectionKind.basicCorrection.title, ColorSectionKind.creative.title])
        let labels = panel.rows.compactMap(\.label)
        #expect(labels.contains("Source LUT") && labels.contains("Look LUT"))
        #expect(!labels.contains("Input LUT") && !labels.contains("Look"))
    }

    @Test func temperatureTintAndSaturationSlidersUseColorRamps() throws {
        let (_, panel) = try rig()
        let id = try #require(panel.model?.effects.first?.id)
        #expect(panel.ramp(.param(id, .temperature)) == .temperature)
        #expect(panel.ramp(.param(id, .tint)) == .tint)
        #expect(panel.ramp(.param(id, .saturation)) == .saturation)
        #expect(panel.ramp(.param(id, .creativeVibrance)) == .saturation)
        #expect(panel.ramp(.param(id, .exposure)) == .plain)
        // The ramp runs from its first to its last stop (blue to orange for Temperature).
        let blue = try #require(InspectorColorRamp.temperature.color(at: 0)), orange = try #require(InspectorColorRamp.temperature.color(at: 1))
        #expect(blue.b > blue.r && orange.r > orange.b)
        #expect(InspectorColorRamp.plain.stops == nil)
    }

    @Test func inputColorFoldsAtTheFootAndItsPopupsSetTheModel() throws {
        let (_, panel) = try rig()
        let model = try #require(panel.model)
        let last = try #require(panel.rows.last)
        #expect(last.label == "Input color" && !last.open)
        #expect(last.summary == ColorInputChoices.automaticTitle(detected: model.detectedSource))
        let f = try #require(panel.frame(.inputSection))
        panel.mouseDown(at: CGPoint(x: f.midX, y: f.midY - panel.scrollY), clickCount: 1)
        panel.mouseUp(at: CGPoint(x: f.midX, y: f.midY - panel.scrollY))
        #expect(panel.inputOpen)
        let labels = panel.rows.compactMap(\.label)
        #expect(Array(labels.suffix(5)) == ["Interpret As", "Log Handling", "Deliver As", "HDR Conform", "Project Input"])
        var opened: [SQMenuItem] = []
        panel.onMenu = { items, _ in opened = items }
        let pf = try #require(panel.frame(.input(.deliver)))
        panel.mouseDown(at: CGPoint(x: pf.midX, y: pf.midY - panel.scrollY), clickCount: 1)
        #expect(opened.map(\.title) == TargetSpace.allCases.map(ColorInputChoices.title))
        opened.first { $0.title == "Rec. 2020" }?.action?()
        #expect(model.targetSpace == .rec2020)
        let interpret = panel.inputMenu(.interpret)
        #expect(interpret.first?.isChecked == true && interpret.count == ColorInputChoices.spaces.count + 1)
    }

    @Test func aRampSliderDrawsItsPiecesAndTheBarThumb() throws {
        let atlas = try #require(GlyphAtlas())
        var plain = Canvas(width: 200, height: 20, atlas: atlas, scale: 1)
        InspectorDraw.colorSlider(&plain, fraction: 0.5, neutral: 0.5, ramp: .plain, in: CGRect(x: 0, y: 0, width: 200, height: 20),
                                  enabled: true, DrawTheme())
        var ramp = Canvas(width: 200, height: 20, atlas: atlas, scale: 1)
        InspectorDraw.colorSlider(&ramp, fraction: 0.5, neutral: 0.5, ramp: .temperature, in: CGRect(x: 0, y: 0, width: 200, height: 20),
                                  enabled: true, DrawTheme())
        #expect(ramp.list.quads.count > plain.list.quads.count + 40)
        #expect(InspectorDraw.colorSliderFraction(x: 2, in: CGRect(x: 0, y: 0, width: 200, height: 20)) == 0)
        #expect(InspectorDraw.colorSliderFraction(x: 198, in: CGRect(x: 0, y: 0, width: 200, height: 20)) == 1)
    }
}
