import AppKit
import Foundation
import Testing
import SQCore
import SQUIKit
@testable import SQEditorUI
@testable import SQInspectorUI

/// Item lanes, rest 8: the two holds have their own key shape, one ease list, and the Graph Editor toolbar fits.
@MainActor @Suite struct ItemLanesRest8Tests {
    // MARK: Key shape per ease kind

    private func shape(_ i: Interpolation, handle: EaseHandle = .linear) -> KeyShape {
        let a = Keyframe(time: .zero, value: 0.0, interpolation: i, outHandle: handle)
        let b = Keyframe(time: Time(1, 1), value: 1.0)
        return KeyGlyph.glyphs(of: KeyframeTrack(keys: [a, b])).first!.glyph.shape
    }

    @Test func eachEaseKindHasItsOwnKeyShape() {
        #expect(shape(.linear) == .diamond)
        #expect(shape(.bezier, handle: EaseHandle(dx: 0.42, dy: 0)) == .circle)
        #expect(shape(.hold) == .square)
        #expect(shape(.holdAhead) == .ahead)
        #expect(KeyShape.ahead != KeyShape.square)
    }

    @Test func holdAheadReachesTheNextKeyAndTheSummary() {
        let a = Keyframe(time: .zero, value: 0.0, interpolation: .holdAhead)
        let b = Keyframe(time: Time(1, 1), value: 1.0)
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [a, b])).map(\.glyph)
        #expect(g[1].incoming == .holdAhead && g[1].shape == .ahead)
        let ahead = KeyGlyph(incoming: .holdAhead, outgoing: .holdAhead), hold = KeyGlyph(incoming: .hold, outgoing: .hold)
        #expect(KeyGlyph.merged([ahead, ahead]).shape == .ahead)
        #expect(KeyGlyph.merged([ahead, hold]).shape == .square)
        #expect(KeyShape.ahead.corners(at: .zero, size: 13).count == 5)
    }

    // MARK: One ease list

    @Test func laneMenuAndGraphicsMenuShareOneList() {
        let m = EffectControlsModel()
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 1.0)])
        m.onEdit = { n, _, _ in m.setClip(n) }
        m.setClip(c)
        m.selectKey(.opacity, id: c.animation.opacity.track.keys[0].id, extend: false)
        let titles = EffectKeyframeLanesView(model: m).makeKeyItems(onKey: true).filter { $0.kind == .action }.map(\.title)
        #expect(Array(titles.prefix(6)) == EaseName.keyframeMenuWithHoldAhead)
        // Graphics keys store a curve (no Hold Ahead): the same list without it.
        #expect(Array(GraphicsKeyEase.menuTitles.prefix(5)) == EaseName.keyframeMenu)
        #expect(!GraphicsKeyEase.menuTitles.contains(EaseName.holdAhead))
        #expect(EaseName.keyframeMenuWithHoldAhead.filter { $0 != EaseName.holdAhead } == EaseName.keyframeMenu)
    }

    // MARK: Graph Editor toolbar

    @Test(arguments: [324.0, 364.0, 520.0]) func graphToolbarFitsItsRow(width: Double) {
        let bar = GraphEditorToolbar(model: EffectControlsModel())
        bar.frame = NSRect(x: 0, y: 0, width: width, height: GraphEditorGeometry.toolbarHeight)
        bar.layoutSubtreeIfNeeded()
        let frames = bar.buttons.map(\.frame)
        #expect(frames.count == 8)
        for f in frames {
            #expect(f.minX >= 0 && f.maxX <= width && f.minY >= 0 && f.maxY <= bar.bounds.height && f.width > 0)
        }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b.minX - a.maxX >= 0) }   // outlines never overlap
    }
}
