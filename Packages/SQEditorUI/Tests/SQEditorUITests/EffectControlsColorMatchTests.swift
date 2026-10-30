import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// FB-B3: the Match row of a Color effect stores a reference and matches the wheels to it, one undo step each.
@MainActor @Suite struct EffectControlsColorMatchTests {
    func rig() -> (EffectControlsModel, ClipEffect.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.colorKind)!
        let m = EffectControlsModel()
        m.setClip(clip)
        m.playhead = Time(2, 1)
        return (m, id)
    }

    static func frame(cast: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        var px: [SIMD3<Float>] = []
        for i in 0..<400 {
            let y = Float(i % 20) / 19, hue = Float(i / 20) / 20
            let c = SIMD3<Float>(y * (0.8 + 0.2 * hue), y * 0.9, y * (1 - 0.2 * hue)) + cast * (1 - y * 0.5)
            px.append(SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1)))
        }
        return px
    }

    @Test func setReferenceThenMatchAreOneUndoStepEach() throws {
        let (m, id) = rig()
        var log: [String] = []
        m.onEdit = { _, n, _ in log.append(n) }
        #expect(m.colorMatchBlock(id) != nil)                       // no reference yet
        let stats = try #require(ColorMatchStats.measure(Self.frame(cast: SIMD3(0.08, 0, -0.06))))
        m.setColorMatchReference(id, ColorMatchReference(clip: nil, time: .zero, label: "A 00:00:00:00", stats: stats))
        #expect(m.colorMatchReference(id)?.label == "A 00:00:00:00")
        #expect(m.colorMatchBlock(id) == nil)
        #expect(m.applyColorMatch(id, display: Self.frame()))
        let w = try #require(m.clip?.effects.first { $0.id == id }?.colorEffect(atLocal: nil, id: 1).wheels)
        #expect(!w.isNeutral)
        #expect(log == ["Set Match Reference", "Match Color"])
        #expect(m.clip?.effects.first { $0.id == id }?.colorData.match != nil)  // the reference stays with the effect
    }

    @Test func blockedOffTheClipAndForLogFootage() throws {
        let (m, id) = rig()
        let stats = try #require(ColorMatchStats.measure(Self.frame()))
        m.setColorMatchReference(id, ColorMatchReference(clip: nil, time: .zero, label: "A", stats: stats))
        #expect(m.colorMatchBlock(id, source: .sLog3SGamut3Cine) != nil)
        m.colorSourceOf = { _ in .sLog3SGamut3Cine }
        #expect(!m.applyColorMatch(id, display: Self.frame()))
        m.colorSourceOf = nil
        m.playhead = Time(20, 1)
        #expect(m.colorMatchBlock(id) != nil)
    }

    @Test func matchRowFollowsTheOpenWheelsGroup() {
        let (m, id) = rig()
        m.collapsedSections.removeAll()
        func rows() -> [EffectRow.Kind] {
            EffectControlsLayout.rows(sections: m.visibleSections, collapsed: m.collapsedSections, expanded: m.expanded,
                                      openColorGroups: m.openColorGroups).map(\.kind)
        }
        #expect(!rows().contains(.colorMatch(id)))
        m.toggleColorGroup(id, ClipEffect.colorWheelsOnKey)
        #expect(rows().contains(.colorMatch(id)))
    }
}
