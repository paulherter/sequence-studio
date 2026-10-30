import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite(.serialized) struct SafeZoneSnapTests {
    let canvas = CGSize(width: 1080, height: 1920)
    var zone: CGRect { SafeZoneChoice.tiktok.offsetRect(canvasWidth: 1080, canvasHeight: 1920)! }

    @Test func zoneEdgesBecomeSnapTargets() {
        let t = SnapGuides.targets(canvas: canvas, others: [], zone: zone)
        #expect(t.xs.contains(Double(zone.minX)) && t.xs.contains(Double(zone.maxX)))
        #expect(t.ys.contains(Double(zone.minY)) && t.ys.contains(Double(zone.maxY)))
        #expect(SnapGuides.targets(canvas: canvas, others: [], zone: nil) == SnapGuides.targets(canvas: canvas, others: []))
    }

    @Test func captionDragSnapsItsBoxToTheZoneEdge() {
        // A box whose bottom is 5 px past the zone's bottom edge is pulled back onto it.
        let box = CGRect(x: -200, y: zone.maxY - 80 + 5, width: 400, height: 80)
        let r = CaptionDrag.moved(start: .default, textRect: box, delta: .zero, canvas: canvas, threshold: 8, zone: zone)
        #expect(abs(r.guides.dy + 5) < 1e-6)
        #expect(abs(r.position.offsetY - (-5.0 / 1920)) < 1e-9)
    }

    @Test func farFromTheZoneNothingMoves() {
        let box = CGRect(x: -200, y: 0, width: 400, height: 80)
        let r = CaptionDrag.moved(start: .default, textRect: box, delta: Vec2(0, 7), canvas: canvas, threshold: 3, zone: zone)
        #expect(abs(r.position.offsetY - 7.0 / 1920) < 1e-9)
    }

    @Test func optionBypassIsThresholdZero() {
        let box = CGRect(x: -200, y: zone.maxY - 80 + 5, width: 400, height: 80)
        let r = CaptionDrag.moved(start: .default, textRect: box, delta: .zero, canvas: canvas, threshold: 0, zone: zone)
        #expect(r.guides == .none && r.position.offsetY == 0)
    }

    @Test func choiceIsRememberedUnderTheDocumentedKey() {
        let d = UserDefaults.standard
        let old = d.object(forKey: "sq.monitor.safeZone")
        defer { if let old { d.set(old, forKey: "sq.monitor.safeZone") } else { d.removeObject(forKey: "sq.monitor.safeZone") } }
        d.removeObject(forKey: "sq.monitor.safeZone")
        #expect(SafeZoneChoice.stored == .off)
        SafeZoneChoice.reels.remember()
        #expect(d.string(forKey: "sq.monitor.safeZone") == "reels")
        #expect(SafeZoneChoice.stored == .reels)
    }

    @Test func menuChecksTheCurrentChoice() {
        var picked: SafeZoneChoice?
        let items = MonitorMenus.safeZoneItems(current: .shorts, set: { picked = $0 })
        #expect(items.map(\.title) == ["Off", "TikTok", "Reels", "Shorts", "YouTube"])
        #expect(items.filter(\.isChecked).map(\.title) == ["Shorts"])
        items[1].action?()
        #expect(picked == .tiktok)
    }
}
