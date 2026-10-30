import AppKit
import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

/// G10 review fixes: section placement and graphics text animation in zones.
@MainActor @Suite struct TemplateFieldsPlacementTests {
    private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

    @Test func middleRowStaysInIntroAndOutro() throws {
        let tracks = Timeline.defaultTracks(video: 2, audio: 1)
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: tracks)
        let s = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: s)
        let panel = GraphicsPanelView(editor: e)
        e.newGraphicsClip()
        e.addText()
        let id = try #require(e.clip?.id)
        try s.perform("Zones") {
            try $0.setAnimationZones(AnimationZones(introEnd: Time(1, 2), outroStart: Time(9, 2), designDuration: Time(5, 1), middle: .hold), clip: id)
        }
        e.select([])
        panel.sync([.project, .selection])
        let sections = allViews(panel).compactMap { $0 as? InspectorSection }
        #expect(sections.map(\.header.title).contains("Template Fields"))
        func owner(ofRow title: String) -> String? {
            sections.first { sec in allViews(sec.body).contains { ($0 as? InspectorRow)?.title == title } }?.header.title
        }
        #expect(owner(ofRow: "Middle") == "Intro and Outro")
        #expect(owner(ofRow: "Text 1") == "Template Fields")
    }

    @Test func graphicsTextAnimationGivesZoneKeyTimes() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 2), 1, .linear)])],
                                    duration: Time(1, 2), anchor: .start)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "a", text: "a", style: TextStyle(fontName: "Helvetica", size: 50, color: .white)),
                                            animations: AnimationSet(in: fade, out: nil))
        var c = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(10, 1))
        c.graphics = GraphicsDocument(layers: [GraphicsLayer(name: "a", content: .text(ref: ref))])
        #expect(EditorSession.textAnimationKeyTimes(of: [c], shift: Time(10, 1)) == [Time(1, 2)])
    }
}
