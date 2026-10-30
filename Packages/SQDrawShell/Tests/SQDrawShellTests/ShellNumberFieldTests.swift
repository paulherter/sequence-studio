import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Number rows (`SQDialog.makeNumberField` on the canvas), the link toggle, disabled rows, and the Speed and Audio Gain
/// dialogs built on them.
@MainActor
@Suite struct ShellNumberFieldTests {
    func dialog(_ form: ShellForm) -> ShellDialog {
        let d = ShellDialog("Speed")
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        d.form = form
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        return d
    }

    func click(_ d: ShellDialog, _ p: CGPoint) {
        d.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
    }

    func type(_ d: ShellDialog, _ s: String) { for ch in s { d.handle(.keyDown(.character(ch), modifiers: []), scale: 1) } }
    func backspace(_ d: ShellDialog, _ n: Int) { for _ in 0..<n { d.handle(.keyDown(.backspace, modifiers: []), scale: 1) } }

    @Test func numberRowScrubsTypesAndKeepsTheMacWidths() throws {
        let f = ShellForm([.number(label: "Gain", .init(id: "g", value: 2, range: 0...10, unit: "dB")),
                           .number(label: "Name", .init(id: "n", value: 1, range: 0...100))])
        let d = dialog(f)
        let box = try #require(f.scrubFrames["g"])
        #expect(box.width == 72)                                  // a unit makes it 72 wide
        #expect(try #require(f.scrubFrames["n"]).width > 200)     // without one it fills the row
        // Drag 5 pt to the right: 3 pt threshold, then one step per point.
        d.handle(.mouseDown(x: Float(box.midX), y: Float(box.midY), modifiers: []), scale: 1)
        d.handle(.mouseDragged(x: Float(box.midX + 3), y: Float(box.midY)), scale: 1)
        d.handle(.mouseDragged(x: Float(box.midX + 5), y: Float(box.midY)), scale: 1)
        d.handle(.mouseUp(x: Float(box.midX + 5), y: Float(box.midY)), scale: 1)
        #expect(f.number("g") == 7)                               // 2 + 5 steps
        #expect(!f.isEditing)
        // A click without a drag opens the field for typing.
        click(d, CGPoint(x: box.midX, y: box.midY))
        #expect(f.isEditing)
        backspace(d, 4)
        type(d, "4")
        d.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(f.number("g") == 4)
        #expect(!f.isEditing)
    }

    @Test func disabledRowsTakeNoInputAndTheLinkToggles() throws {
        let f = ShellForm([.number(label: "Speed", .init(id: "s", value: 100, range: 1...1000, unit: "%")),
                           .number(label: "Duration", .init(id: "d", value: 50, range: 1...1000)),
                           .check(id: "p", title: "Keep Pitch", on: false)])
        f.link = ShellForm.Link(id: "link", fields: ["s", "d"])
        f.set("link", .bool(true))
        f.disabled = ["p"]
        let d = dialog(f)
        let dur = try #require(f.scrubFrames["d"])
        #expect(dur.maxX == f.linkFrame.minX - 20)                // the linked rows end sidePad + 24 before the edge
        click(d, CGPoint(x: f.linkFrame.midX, y: f.linkFrame.midY))
        #expect(f.bool("link") == false)
        let p = f.rowFrames[2]
        click(d, CGPoint(x: p.minX + 30, y: p.midY))
        #expect(f.bool("p") == false)
        f.disabled.insert("d")
        click(d, CGPoint(x: f.linkFrame.midX, y: f.linkFrame.midY))
        #expect(f.bool("link") == false)                          // the link is off with a disabled field
        click(d, CGPoint(x: dur.midX, y: dur.midY))
        #expect(!f.isEditing)
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test func numberRadioRowsPickOptionsAndSkipDisabledOnes() throws {
        let fields: [ShellForm.NumberField] = ["a", "b", "c"].map { .init(id: $0, value: 0, range: -10...10, unit: "dB") }
        let f = ShellForm([.radioNumbers(id: "mode", options: ["One", "Two", "Three"], selected: 0, fields: fields)])
        f.disabled = ["c"]
        let d = dialog(f)
        let box = f.controlFrames[0]
        #expect(abs(box.height - 108) < 0.01)                     // 3 rows of 28, 12 apart
        #expect(try #require(f.scrubFrames["b"]).minX == box.minX + 206)   // 190 label column + 16 gap, like SQDialog.radioRow
        click(d, CGPoint(x: box.minX + 30, y: box.minY + 40 + 14))
        #expect(f.index("mode") == 1)
        click(d, CGPoint(x: box.minX + 30, y: box.minY + 80 + 14))
        #expect(f.index("mode") == 1)                             // the disabled option stays off
        d.handle(.keyDown(.down, modifiers: []), scale: 1)
        #expect(f.index("mode") == 1)
        d.handle(.keyDown(.up, modifiers: []), scale: 1)
        #expect(f.index("mode") == 0)
    }

    func speedModel(clips: Int = 1, audio: Bool = false) -> SpeedDialogModel {
        let fd = Time(1, 25)
        let all = (0..<clips).map { n in
            Clip(name: "c\(n)", media: UUID(), kind: audio ? .audio : .video, source: TimeRange(start: .zero, duration: fd * 50),
                 start: fd * Int64(n * 60))
        }
        return SpeedDialogModel(clips: all, frameDuration: fd)
    }

    @Test func speedDialogLinksSpeedAndDurationLikeTheMacSheet() throws {
        let s = ShellSpeedDuration.make(model: speedModel(), timecode: Timecode(frameDuration: Time(1, 25), dropFrame: false))
        let d = dialog(s.form)
        #expect(s.form.bool("link") == true)
        #expect(s.form.number("duration") == 50)
        #expect(s.form.disabled == ["pitch"])                     // a video clip: Keep Pitch off, Duration on
        let speed = try #require(s.form.scrubFrames["speed"])
        click(d, CGPoint(x: speed.midX, y: speed.midY))
        backspace(d, 8)
        type(d, "200")
        d.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(s.model.percent == 200)
        #expect(s.form.number("duration") == 25)                  // linked: half the length
        #expect(ShellSpeedDuration.answer(s) != nil)
    }

    @Test func speedDialogDisablesDurationForSeveralClips() {
        let s = ShellSpeedDuration.make(model: speedModel(clips: 2, audio: true), timecode: Timecode(frameDuration: Time(1, 25), dropFrame: false))
        #expect(s.form.disabled == ["duration"])
        #expect(!s.form.rows.contains { if case .popup = $0 { true } else { false } })   // no Frames row for audio
    }

    @Test func audioGainKeepsLoudnessOffUntilMeasuredAndReadsTheSelectedField() {
        let item = AudioGainPlan.Item(id: UUID(), name: "a", gainDB: 1.5, peak: 0.5)
        let f = ShellAudioGain.form(items: [item], target: -14, ready: false)
        #expect(f.disabled.contains("lufs"))
        #expect(f.number("set") == 1.5)
        #expect(ShellAudioGain.choice(f) == AudioGainPlan.choice(index: 1, value: 0))
        f.set("peak", ShellForm.Value.number(-3))
        f.choose(row: 0, option: 2)
        #expect(ShellAudioGain.choice(f) == AudioGainPlan.choice(index: 2, value: -3))
    }
}

/// New Sequence / Sequence Settings rows as the Mac `SequenceSettingsSheet`: Frame Size with swap, group captions,
/// segmented choices, 120 pt popups.
@MainActor
@Suite struct ShellSequenceRowsTests {
    @Test func frameSizeSwapsAndTheChoicesAreSegments() throws {
        let settings = SequenceSettings(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25)))
        let s = ShellSequenceSettings.make(settings: settings, isNew: false)
        let d = ShellDialog("Sequence Settings")
        d.addButton("OK")
        d.form = s.form
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
        let f = s.form
        let row = try #require(f.rows.firstIndex { if case .size = $0 { true } else { false } })
        #expect(try #require(f.scrubFrames["width"]).width == 72)
        let swap = f.swapFrame(row)
        _ = f.mouseDown(CGPoint(x: swap.midX, y: swap.midY)); f.mouseUp()
        #expect(f.number("width") == 1920 && f.number("height") == 1080)
        let rate = try #require(f.rows.firstIndex { if case .popup("rate", _, _, _) = $0 { true } else { false } })
        #expect(f.controlFrames[rate].width == 120)
        let mode = try #require(f.rows.firstIndex { if case .segmented("mode", _, _, _, _) = $0 { true } else { false } })
        let seg = f.controlFrames[mode]
        _ = f.mouseDown(CGPoint(x: seg.minX + 1 + 84 + 10, y: seg.midY))
        #expect(f.index("mode") == 1)
        let r = try #require(ShellSequenceSettings.answer(s, settings: settings, projectDucking: nil))
        #expect(r.settings.format.width == 1920 && r.settings.editMode == .magnetic)
        var c = Canvas(width: 1200, height: 900, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 900))
    }
}
