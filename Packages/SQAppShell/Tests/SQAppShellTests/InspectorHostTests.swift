import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

/// A screen sampler stand-in: per-event samples (Windows) or the platform's own eyedropper (Mac `SQLoupe`).
@MainActor
final class SamplerStub: AppScreenSampler {
    var own: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)?
    var color: SQColorValue? = SQColorValue(r: 1, g: 0, b: 0, a: 1)
    var colorReads = 0
    var ownEyedropper: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? { own }
    func colorUnderPointer() -> SQColorValue? { colorReads += 1; return color }
    func loupeUnderPointer() -> ColorLoupe? { nil }
}

@MainActor
struct InspectorHostTests {
    private func make(_ sampler: SamplerStub) -> (InspectorHost, ShellHost, EditorSession) {
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: PictureEngineStub())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        shell.size = CGSize(width: 1280, height: 800)
        return (InspectorHost(session: s, menus: shell.menuBar.controller, shell: shell, sampler: sampler), shell, s)
    }

    @Test func pickerForAnotherPanelTakesEventsAndAnOutsidePressClosesIt() {
        let (host, _, _) = make(SamplerStub())
        var answers: [EffectColor?] = []
        #expect(!host.handlePopover(.mouseDown(x: 10, y: 10, modifiers: []), scale: 1))   // nothing open
        host.pickColor(EffectColor(red: 0, green: 0, blue: 1, alpha: 1), anchor: CGRect(x: 600, y: 300, width: 20, height: 20)) {
            answers.append($0)
        }
        #expect(host.handlePopover(.keyDown(.tab, modifiers: []), scale: 1))
        #expect(host.handlePopover(.mouseDown(x: 2, y: 2, modifiers: []), scale: 1))     // outside: taken, closes
        #expect(answers.count == 1 && answers[0] == nil)
        #expect(!host.handlePopover(.mouseDown(x: 2, y: 2, modifiers: []), scale: 1))
    }

    @Test func eyedropperSamplesOnTheNextPressAndHoldsThatPressBack() {
        let sampler = SamplerStub()
        let (host, _, _) = make(sampler)
        var picked: [SQColorValue?] = []
        host.beginSampling { picked.append($0) }
        #expect(host.isSampling)
        #expect(!host.handlePopover(.mouseMoved(x: 5, y: 5), scale: 1))
        #expect(host.handlePopover(.mouseDown(x: 5, y: 5, modifiers: []), scale: 1))
        #expect(picked == [sampler.color])
        #expect(!host.isSampling)
    }

    @Test func platformEyedropperAnswersWithoutArmingTheHost() {
        let sampler = SamplerStub()
        var pending: (@MainActor (SQColorValue?) -> Void)?
        sampler.own = { pending = $0 }
        let (host, _, _) = make(sampler)
        var picked: [SQColorValue?] = []
        host.beginSampling { picked.append($0) }
        #expect(!host.isSampling)
        #expect(!host.handlePopover(.mouseDown(x: 5, y: 5, modifiers: []), scale: 1))
        pending?(SQColorValue(r: 0, g: 1, b: 0, a: 1))
        #expect(picked == [SQColorValue(r: 0, g: 1, b: 0, a: 1)])
        #expect(sampler.colorReads == 0)
    }

    @Test func graphicsCardTakesFocusOnlyInsideAndControlsFollowsTheSession() {
        let (host, shell, s) = make(SamplerStub())
        let g = GraphicsHost(session: s, menus: shell.menuBar.controller, shell: shell, inspector: host)
        g.layout(nil)
        #expect(!g.handle(.mouseDown(x: 10, y: 10, modifiers: []), scale: 2))
        g.layout(CGRect(x: 100, y: 50, width: 300, height: 400))
        #expect(g.handle(.mouseDown(x: 400, y: 300, modifiers: []), scale: 2))
        #expect(g.hasFocus)
        _ = g.handle(.mouseUp(x: 400, y: 300), scale: 2)
        host.layout(DrawRect(x: 0, y: 0, w: 600, h: 800), scale: 2)
        #expect(host.panel.size == CGSize(width: 300, height: 400))
        #expect(host.handle(.mouseDown(x: 100, y: 100, modifiers: []), scale: 2))
        #expect(host.hasFocus)
    }
}

@MainActor
struct SharedCommandRoutingTests {
    private func make() -> (InspectorHost, ShellHost) {
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: PictureEngineStub())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        shell.size = CGSize(width: 1280, height: 800)
        let inspector = InspectorHost(session: s, menus: shell.menuBar.controller, shell: shell, sampler: SamplerStub())
        _ = GraphicsHost(session: s, menus: shell.menuBar.controller, shell: shell, inspector: inspector)
        return (inspector, shell)
    }

    @Test func addKeyframeWithoutAFocusedPropertySaysSo() {
        let (inspector, shell) = make()
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        #expect(inspector.addKeyframeAtPlayhead() == "Select a property in Effect Controls first.")
        #expect(shell.onCommand?(.addKeyframe) == true)
        #expect(lines.last == "Select a property in Effect Controls first.")
    }

    @Test func selectLayerAboveWithoutAGraphicSaysSo() {
        let (_, shell) = make()
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        #expect(shell.onCommand?(.selectLayerAbove) == true)
        #expect(shell.onCommand?(.selectLayerBelow) == true)
        #expect(lines == ["No Graphic with layers is open.", "No Graphic with layers is open."])
    }
}

/// The hosts fill the panel facts the shell's menu rules read (the Mac `commandEnabled` asks its panels the same).
@MainActor
struct HostPanelFactsTests {
    @Test func graphicsAndControlsFactsStartEmptyAndFeedTheMenuRules() {
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: PictureEngineStub())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        shell.size = CGSize(width: 1280, height: 800)
        let inspector = InspectorHost(session: s, menus: shell.menuBar.controller, shell: shell, sampler: SamplerStub())
        let graphics = GraphicsHost(session: s, menus: shell.menuBar.controller, shell: shell, inspector: inspector)
        let f = shell.currentFacts()
        #expect(f.graphicsHasSelection == false)
        #expect(f.graphicsHasLayers == false)
        #expect(!f.effectControlsClip)
        #expect(f.effectSelectionEmpty)
        #expect(!f.textEditing)
        shell.focus = .graphics
        #expect(!shell.menuEnabled(.delete))                 // no layer picked: Delete is off like the Mac's
        #expect(!shell.menuEnabled(.selectAll))              // and no layers to select
        #expect(!shell.enabled(.toggleGraphEditor))
        _ = graphics
    }

    @Test func colorPanelsReportTheGradeClipboard() throws {
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: PictureEngineStub())
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let color = ColorPageHost(session: s, menus: MenuController(), shell: shell)
        #expect(shell.currentFacts().canCopyGrade == color.controller.canCopyGrade)
        #expect(shell.currentFacts().canPasteGrade == color.controller.canPasteGrade)
        shell.focus = .colorInspector
        #expect(shell.menuEnabled(.copy) == color.controller.canCopyGrade)
    }
}
