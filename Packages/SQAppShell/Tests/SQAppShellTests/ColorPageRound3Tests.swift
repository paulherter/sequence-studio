import Foundation
@testable import SQAppShell
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

@MainActor
private final class LUTPickerStub: ShellFilePicker, PanelFileChooser {
    var asked: [Bool] = []
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { nil }
    func chooseMedia() async -> [URL] { [] }
    func chooseSubtitles() -> URL? { nil }
    func chooseSRTLocation(suggestedName: String) -> URL? { nil }
    func choosePNGLocation(suggestedName: String) -> URL? { nil }
    func chooseCSVLocation(suggestedName: String) -> URL? { nil }
    func chooseLUTs(multiple: Bool) -> [URL] {
        asked.append(multiple)
        return multiple ? [URL(fileURLWithPath: "/l/a.cube"), URL(fileURLWithPath: "/l/b.3dl")] : [URL(fileURLWithPath: "/l/a.cube")]
    }
}

/// Color page round 3 on the shared UI: strip tools, grade outline, split divider, loupe and the LUT chooser.
@MainActor
@Suite struct ColorPageRound3Tests {
    @Test func stripToolsAndTheGradeOutlineOnlyOnTheColorPage() throws {
        let (s, shell, host) = try ColorPageHostTests().rig()
        let clip = try #require(s.activeTimeline?.tracks.first?.clips.first?.id)
        host.layout()
        #expect(host.gradeOutline.isEmpty && shell.dock.stripTools(.colorClips) == 0)
        shell.dock.setPage(.color)
        _ = host.monitorCard(shell.dock.cardFrame(.programMonitor))
        shell.dock.layout()
        host.layout()
        #expect(host.gradeOutline == [clip])
        #expect(shell.dock.stripTools(.colorClips) > 2 * 24)
        #expect(host.controller.stripVisible == shell.dock.shows(.timeline))
        // A click on Add Step at the right end of the Steps strip opens its menu on release (Copy and Paste Grade use
        // the shared grade clipboard, so they are proven in ColorRound3DrawTests).
        let model = try #require(host.controller.model)
        model.setActiveGrade(.pro)
        model.startEmptyGraph()
        host.controller.sync([.project])
        host.layout()
        #expect(host.controller.proShown)
        shell.dock.select(.steps)
        shell.dock.layout()
        host.layout()
        var menu: [SQMenuItem] = []
        host.tools.onMenu = { items, _ in menu = items }
        let g = try #require(shell.dock.groups.first { $0.selected == .steps })
        let add = CGPoint(x: g.strip.maxX - 8 - 3 * 24 - 2 * 2 + 12, y: g.strip.midY)
        #expect(host.handle(.mouseDown(x: Float(add.x), y: Float(add.y), modifiers: []), scale: 1))
        #expect(menu.isEmpty)
        #expect(host.handle(.mouseUp(x: Float(add.x), y: Float(add.y)), scale: 1))
        #expect(!menu.isEmpty)
        // Back on Edit: no tools, no outline.
        shell.dock.setPage(.edit)
        host.layout()
        #expect(host.gradeOutline.isEmpty && shell.dock.stripTools(.colorClips) == 0)
    }

    @Test func splitDividerSitsOnTheSplitColumnOfTheVisiblePicture() {
        let canvas = CGRect(x: 100, y: 50, width: 960, height: 540)
        let r = ColorPageHost.splitDividerFrame(canvas: canvas, sequenceWidth: 1920, bounds: CGRect(x: 0, y: 0, width: 2000, height: 400))
        let x = 100 + 960 * CGFloat(ColorBypass.splitWidth(1920)) / 1920
        #expect(r == CGRect(x: (x - 0.5).rounded(), y: 50, width: 1, height: 350))
        #expect(ColorPageHost.splitDividerFrame(canvas: canvas, sequenceWidth: 1920, bounds: CGRect(x: 0, y: 700, width: 10, height: 10)) == nil)
    }

    @Test func theLoupeFollowsThePointerWhilePickingOverThePicture() throws {
        let (_, shell, host) = try ColorPageHostTests().rig()
        shell.dock.setPage(.color)
        host.layout()
        host.readProgramFrame = { _ in ProgramLinearFrame(width: 2, height: 2, pixels: Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 4)) }
        let grid = ColorLoupe(width: 3, height: 3, pixels: Array(repeating: SIMD3(10, 20, 30), count: 9))
        host.loupeUnderPointer = { grid }
        let panel = ColorPageHostTests().monitor(host)
        let r = panel.canvasRect
        let e = try #require(host.controller.model?.effects.first?.id)
        _ = host.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(host.loupe == nil, "no loupe without a pick")
        host.controller.model?.onPickWhiteBalance?(e)
        #expect(host.isPicking)
        _ = host.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(host.loupe?.grid == grid && host.loupe?.pointer == CGPoint(x: r.midX, y: r.midY))
        _ = host.handle(.mouseMoved(x: Float(r.maxX + 30), y: Float(r.midY)), scale: 1)
        #expect(host.loupe == nil)
        _ = host.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(host.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(host.loupe == nil && !host.isPicking)
    }

    @Test func addLUTsTakesSeveralFilesFromThePlatformChooser() throws {
        let (_, shell, host) = try ColorPageHostTests().rig()
        let picker = LUTPickerStub()
        shell.files = picker
        var got: [String] = []
        host.grade.chooseLUTFiles?(true) { got = $0 }
        #expect(got == ["/l/a.cube", "/l/b.3dl"] && picker.asked == [true])
        var one: String?
        host.steps.chooseLUTFile?({ one = $0 })
        #expect(one == "/l/a.cube" && picker.asked == [true, false])
    }
}
