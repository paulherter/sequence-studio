import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

/// Save as Template / apply / slots / zones from the editor (TEMPLATE-ECOSYSTEM T3, DECISIONS 2026-10-06).
@MainActor @Suite struct TitleTemplateSessionTests {
    private let fd = Time(1, 30)

    private func fade(_ from: Double, _ to: Double, anchor: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, from, .linear), (Time(1, 2), to, .linear)])],
                         duration: Time(1, 2), anchor: anchor)
    }

    /// Host with a head clip on V1 and a 6 s text clip with a half-second fade in and out on V2 at 10 s.
    private func session() throws -> (EditorSession, Clip.ID) {
        var tracks = Timeline.defaultTracks(video: 3, audio: 1)
        try tracks[0].overwrite(Clip(name: "head", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(30, 1)), start: .zero))
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: tracks)
        let s = EditorSession(project: Project(name: "P", timelines: [tl]))
        let template = TextTemplate(name: "Hello", text: "Hello", style: TextStyle(fontName: "Helvetica-Bold", size: 90, color: .white))
        let ref = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: fade(0, 1, anchor: .start), out: fade(1, 0, anchor: .end)))
        var id: Clip.ID?
        try s.perform("Add text") { p in
            id = try p.addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: ref.payloadVersion, name: "Hello",
                                        in: tl.id, at: Time(10, 1), track: tl.tracks[1].id, duration: Time(6, 1))
        }
        return (s, try #require(id))
    }

    private func texts(_ s: EditorSession) -> [TextTemplate] {
        (s.activeTimeline?.tracks.flatMap(\.clips) ?? []).compactMap { c in c.generator.flatMap { try? TextGenerator.decode($0).0 } }
    }

    @Test func saveCapturesSlotsAndZonesFromTextAnimation() throws {
        let (s, id) = try session()
        s.select(clips: [id])
        #expect(s.canSaveSelectionAsTemplate)
        let t = try #require(s.titleTemplateFromSelection(name: "Intro"))
        #expect(t.name == "Intro")
        #expect(t.slots.map(\.kind) == [.text, .color, .font, .number])
        // The text animation is invisible to SQCore (no clip keyframes): the zones come from its in/out lengths.
        #expect(t.zones.introEnd == Time(1, 2))
        #expect(t.zones.outroLength == Time(1, 2))
    }

    @Test func headClipOnlyIsNotATemplate() throws {
        let (s, _) = try session()
        let head = try #require(s.activeTimeline?.tracks[0].clips.first)
        s.select(clips: [head.id])
        #expect(s.canSaveSelectionAsTemplate)          // any video clip may be saved; nothing selected may not
        s.select(clips: [])
        #expect(!s.canSaveSelectionAsTemplate)
        #expect(s.titleTemplateFromSelection(name: "x") == nil)
        #expect(s.lastError != nil)
    }

    @Test func insertPlacesOneNestedClipAndOneUndoStep() throws {
        let (s, id) = try session()
        s.select(clips: [id])
        let t = try #require(s.titleTemplateFromSelection(name: "Intro"))
        let depth = s.undoDepth
        let placed = try #require(s.insertTitleTemplate(t, at: Time(2, 1)))
        #expect(s.undoDepth == depth + 1)
        #expect(s.selection == [placed])
        let clip = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed })
        #expect(clip.start == Time(2, 1))
        #expect(clip.zones?.designDuration == t.duration)
        #expect(clip.templateSlots?.count == 4)
        s.undo()
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed } == nil)
    }

    @Test func slotsWriteIntoTheInnerTextAndUndo() throws {
        let (s, id) = try session()
        s.select(clips: [id])
        let t = try #require(s.titleTemplateFromSelection(name: "Intro"))
        let placed = try #require(s.insertTitleTemplate(t, at: Time(2, 1)))
        let clip = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed })
        let slots = try #require(clip.templateSlots)
        let text = try #require(slots.first { $0.kind == .text }), color = try #require(slots.first { $0.kind == .color })
        let font = try #require(slots.first { $0.kind == .font }), size = try #require(slots.first { $0.kind == .number })

        s.setTemplateSlot(text.id, to: .text("Bye"), clip: placed, continuesGesture: false)
        s.setTemplateSlot(color.id, to: .color(red: 1, green: 0, blue: 0, alpha: 1), clip: placed, continuesGesture: false)
        s.setTemplateSlot(font.id, to: .font("Courier"), clip: placed, continuesGesture: false)
        s.setTemplateSlot(size.id, to: .number(120), clip: placed, continuesGesture: false)
        let innerID = try #require(clip.sequence)
        let inner = try #require(s.project.timeline(innerID))
        let innerClip = try #require(inner.tracks.flatMap(\.clips).first)
        let gen = try #require(innerClip.generator)
        let decoded = try TextGenerator.decode(gen).0
        #expect(decoded.text == "Bye")
        #expect(decoded.style.fontName == "Courier")
        #expect(decoded.style.size == 120)
        #expect(decoded.style.color == RGBAColor(red: 1, green: 0, blue: 0))
        // The host clip keeps the value for the editor.
        let after = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed })
        #expect(after.templateSlots?.first { $0.kind == .text }?.value == .text("Bye"))
        let depth = s.undoDepth
        s.undo()
        #expect(s.undoDepth == depth - 1)
    }

    @Test func slotDragCoalescesIntoOneUndoStep() throws {
        let (s, id) = try session()
        s.select(clips: [id])
        let t = try #require(s.titleTemplateFromSelection(name: "Intro"))
        let placed = try #require(s.insertTitleTemplate(t, at: Time(2, 1)))
        let size = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed }?.templateSlots?.first { $0.kind == .number })
        let depth = s.undoDepth
        s.setTemplateSlot(size.id, to: .number(100), clip: placed, continuesGesture: false)
        s.setTemplateSlot(size.id, to: .number(110), clip: placed, continuesGesture: true)
        s.setTemplateSlot(size.id, to: .number(120), clip: placed, continuesGesture: true)
        #expect(s.undoDepth == depth + 1)
    }

    @Test func zonesToggleOffAndBackOnForATemplateClip() throws {
        let (s, id) = try session()
        s.select(clips: [id])
        let t = try #require(s.titleTemplateFromSelection(name: "Intro"))
        let placed = try #require(s.insertTitleTemplate(t, at: Time(2, 1)))
        func zones() -> AnimationZones? { s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == placed }?.zones }
        #expect(zones() != nil)
        #expect(s.setZonesEnabled(false, clip: placed))
        #expect(zones() == nil)
        #expect(s.setZonesEnabled(true, clip: placed))
        #expect(zones()?.introEnd == Time(1, 2))
        #expect(zones()?.outroLength == Time(1, 2))
        #expect(zones()?.designDuration == t.duration)
    }

    @Test func zonesOnAClipWithoutKeyframesSaysSo() throws {
        let (s, _) = try session()
        let head = try #require(s.activeTimeline?.tracks[0].clips.first)
        s.select(clips: [head.id])
        #expect(!s.setZonesEnabled(true, clip: head.id))
        #expect(s.lastError != nil)
    }
}
