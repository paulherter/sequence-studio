import AppKit
import SQAppShell
import SQCore
import SQDrawShell
import SQEditorSession
import SQInspectorUI

/// The Color page variants of the Mac parity audit (`render-panels.sh` `window-color-*-online`): the demo footage online,
/// the Simple grade, a wide window, the Pro grade (empty, with Steps, a Step off, groups), the lower panel on Timeline
/// and on Sources. `SQ_SHOT_ONLY=color` runs only this (one minute instead of ten).
@MainActor
extension SharedUIShot {
    static func colorSweep(_ c: SharedUIController, resize: (Int, Int) -> Void, shot: (String) -> Void) async {
        func settle(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        guard (try? await RenderDemoProject.writeMedia(into: FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderDemoMedia", isDirectory: true))) != nil,
              let online = try? RenderDemoProject.make(mediaDir: FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderDemoMedia", isDirectory: true))
        else { print("shared ui shot: online demo media failed"); return }
        RenderDemoProject.load(online, into: c.session)
        c.shell.dock.setPage(.edit)
        await settle(6)
        shot("shared-edit-online.png")
        c.shell.dock.setPage(.color)
        await settle(3)
        shot("shared-color-online.png")
        resize(5120, 2880)
        await settle(2)
        shot("shared-color-wide-online.png")
        resize(2880, 1800)
        await settle(1)
        let ctl = c.colorPage.controller
        if let m = ctl.model {      // every Simple section and Input color open (`window-color-expanded-online`)
            for e in m.effects { for k in ColorSectionKind.allCases { m.setCollapsed(ColorPanelKey(e.id, k), false) } }
            c.colorPage.grade.inputOpen = true
            resize(2880, 5200)
            await settle(3)
            shot("shared-color-expanded-online.png")
            resize(2880, 1800)
            c.colorPage.grade.inputOpen = false
            await settle(1)
        }
        if let m = ctl.model, m.graph == nil {
            m.setActiveGrade(.pro)
            await settle(3)
            shot("shared-color-pro-empty-online.png")
            m.setActiveGrade(.simple)
            await settle(2)
        }
        if let m = ctl.model {
            m.startEmptyGraph()
            m.addStep(after: m.selectedStep)
            m.addStep(after: m.selectedStep)
            await settle(3)
            shot("shared-color-pro-online.png")
            for (i, name) in ["curves", "qualifier", "window", "lut", "effects"].enumerated() {
                c.colorPage.grade.proTab = i + 1
                await settle(1)
                shot("shared-color-pro-\(name)-online.png")
            }
            c.colorPage.grade.proTab = 0
            c.colorPage.grade.inputOpen = true
            await settle(1)
            shot("shared-color-pro-input-online.png")
            c.colorPage.grade.inputOpen = false
            await settle(1)
            resize(5120, 2880)
            await settle(2)
            shot("shared-color-pro-wide-online.png")
            resize(2880, 1800)
            await settle(1)
            if let id = m.selectedStep {
                m.setStepEnabled(id, false)
                await settle(2)
                shot("shared-color-pro-off-online.png")
                m.setStepEnabled(id, true)
            }
            if let first = m.graph?.steps.first?.id {
                m.addStep(after: first, kind: .parallel)
                m.addStep(after: m.selectedStep, kind: .serial)
                m.addStep(after: m.selectedStep, kind: .serial)
                m.addStep(after: m.selectedStep, kind: .layer)
                m.tidyUpSteps()
                await settle(3)
                shot("shared-color-pro-groups-online.png")
            }
            m.setActiveGrade(.simple)
            await settle(2)
        }
        c.shell.dock.show(.timeline)
        await settle(2)
        shot("shared-color-timeline-online.png")
        c.shell.dock.show(.colorClips)
        await settle(3)
        shot("shared-color-clips-online.png")
    }
}
