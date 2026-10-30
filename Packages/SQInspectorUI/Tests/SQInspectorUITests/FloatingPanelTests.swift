import AppKit
import Testing
import SQCore
@testable import SQInspectorUI
@testable import SQUIKit

@MainActor @Suite struct FloatingPanelTests {
    @Test func memoryKeepsOriginPerKey() {
        let m = SQFloatingPanelMemory()
        #expect(m.origin(for: "a") == nil)
        m.remember(NSPoint(x: 10, y: 20), for: "a")
        m.remember(NSPoint(x: 30, y: 40), for: "b")
        #expect(m.origin(for: "a") == NSPoint(x: 10, y: 20))
        #expect(m.origin(for: "b") == NSPoint(x: 30, y: 40))
        m.forget("a")
        #expect(m.origin(for: "a") == nil)
    }

    @Test func clampKeepsTitleBarReachable() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 500, height: 400)
        let far = SQFloatingPanel.clamp(NSPoint(x: 5000, y: 5000), size: size, visible: visible)
        #expect(far.x <= visible.maxX - 80 && far.y <= visible.maxY - size.height)
        let low = SQFloatingPanel.clamp(NSPoint(x: -5000, y: -5000), size: size, visible: visible)
        #expect(low.x >= visible.minX - size.width + 80 && low.y >= visible.minY)
    }

    @Test func showRemembersMovedOriginAndCloseReports() {
        let mem = SQFloatingPanelMemory()
        let p = SQFloatingPanel(key: "k", title: "T", subtitle: "S", content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        p.memory = mem
        var closed = 0
        p.onClose = { closed += 1 }
        #expect(!p.isShown)
        p.show(near: nil)
        #expect(p.isShown)
        p.window?.setFrameOrigin(NSPoint(x: 123, y: 234))
        p.close()
        #expect(!p.isShown)
        #expect(closed == 1)
        #expect(mem.origin(for: "k") == NSPoint(x: 123, y: 234))
        p.close()
        #expect(closed == 1)   // closing twice reports once
        p.show(near: nil)
        #expect(p.window?.frame.origin == NSPoint(x: 123, y: 234))
        p.close()
    }

    @Test func windowIsFloatingAndNonModal() {
        let p = SQFloatingPanel(key: "k2", title: "T", content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        p.memory = SQFloatingPanelMemory()
        p.show(near: nil)
        #expect(p.window?.level == .floating)
        #expect(p.window?.hidesOnDeactivate == false)
        #expect(p.size.height == 100 + SQFloatingPanel.titleBarHeight)
        p.close()
    }
}

@MainActor @Suite struct MultibandParametersDisclosureTests {
    func rig() -> (EffectControlsModel, ClipEffect.ID) {
        var clip = Clip(name: "Interview", media: UUID(), kind: .audio,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.audioMultibandKind)!
        let m = EffectControlsModel()
        m.setClip(clip)
        return (m, id)
    }

    func propertyRows(_ m: EffectControlsModel) -> Int {
        EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], openColorGroups: m.openColorGroups)
            .filter { if case .property(let p) = $0.kind, case .fx(_, let k, _) = p, k == ClipEffect.audioMultibandKind { true } else { false } }.count
    }

    @Test func parametersAreCollapsedByDefault() {
        let (m, id) = rig()
        #expect(!m.isMultibandParametersOpen(id))
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], openColorGroups: m.openColorGroups)
        #expect(rows.contains { if case .multibandParams(let r) = $0.kind { r == id } else { false } })
        #expect(rows.contains { if case .multiband(let r) = $0.kind { r == id } else { false } })
        #expect(propertyRows(m) == 0)
    }

    @Test func openingShowsEveryParameterRowAgain() {
        let (m, id) = rig()
        m.toggleMultibandParameters(id)
        #expect(m.isMultibandParametersOpen(id))
        #expect(propertyRows(m) > 20)
        m.toggleMultibandParameters(id)
        #expect(propertyRows(m) == 0)
    }

    @Test func clipNameFindsTheEffectOwner() {
        let (m, id) = rig()
        #expect(m.multibandClipName(id) == "Interview")
        #expect(m.multibandClipName(UUID()) == nil)
    }
}
