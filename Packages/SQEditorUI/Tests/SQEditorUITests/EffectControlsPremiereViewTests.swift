import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsPremiereViewTests {
    // MARK: Effects panel
    /// The catalog with the hidden ones left out, whatever `SQ_SHOW_HIDDEN` says.
    static var hiddenOut: [EffectsPanelView.Entry] { EffectsPanelView.offered(hiding: true) }
    @Test func effectsPanelListsOnlyWhatExistsUnderItsBin() {
        let rows = EffectsPanelView.rows(matching: "", in: Self.hiddenOut)
        #expect(rows.map(\.title) == ["Looks", "Film Look", "VHS", "Bad TV", "Film", "Gate Weave", "Aged Film",
                                      "Tape & TV", "Scanlines", "Chroma Bleed", "Tracking Noise", "Blur", "Blur", "Directional Blur", "Radial Blur", "Motion Blur",
                                      "Adjust", "Sharpen", "Unsharp Mask", "Invert", "Color", "Duotone",
                                      "Distort", "Lens Distortion", "Mirror", "Spherize", "Twirl", "Wave Warp", "Tile", "Kaleidoscope", "Corner Warp", "Glitch Displace",
                                      "Cutout", "Transparency", "Color Key", "Luma Key", "Track Mask", "Grain", "Film Grain",
                                      "Stylize", "Drop Shadow", "Long Shadow", "Outline", "Glow", "Gradient", "Light Leak", "Mosaic", "Halftone", "Edge Feather", "Posterize", "RGB Split", "Strobe Light", "Date Stamp",
                                      "Transform", "Crop", "Horizontal Flip", "Rounded Corners", "Stabilize", "Transform", "Vertical Flip",
"Motion", "Shake", "Bounce", "Pulse", "Wiggle", "Repair", "Video Denoise", "Deflicker", "Time", "Posterize Time", "Trails",
                                      "Presets", "Voice", "Rode NTG Indoor", "Level", "Compressor", "De-Esser", "Limiter", "Multiband Compressor", "Dialogue Leveler",
                                      "Tone", "EQ", "Graphic EQ", "Pitch Shift", "Disguise Voice", "Cleanup", "Enhance Speech", "Noise Reduction", "Noise Gate", "De-Hum", "De-Reverb", "Low Cut", "Notch", "High Cut", "Space", "Delay", "Reverb", "Stereo Width", "Chorus",
                                      "Transitions", "Dissolve", "Through Black", "Through White",
                                      "Quick Fade", "Push", "Slide", "Whip", "Zoom In", "Zoom Out", "Zoom Pop", "Soft Wipe", "Glitch", "Iris", "Light Leak", "Blur Dissolve", "Through Color", "Flash", "Spin", "Cross Zoom", "Static", "Light Noise", "Strobe Cut", "Additive Dissolve", "Clock Wipe", "Box Iris", "Diamond Iris", "Cross Iris", "Barn Doors", "Blinds", "Radial Wipe", "Wedge Wipe", "Pinwheel", "Checker Wipe", "Zig-Zag Blocks", "Inset", "Random Blocks", "Slice", "Mosaic Dissolve", "Flip 3D", "Spring", "Fall", "Burn", "Flare", "Warp", "Shake", "Stinger", "Move", "Zoom", "Pop",
                                      "Crossfades", "Smooth Crossfade", "Steady Crossfade", "Exponential Fade"])
        #expect(rows[0].isHeader && !rows[1].isHeader && rows[4].isHeader)
    }

    @Test func effectsSearchFiltersAndDropsEmptyBins() {
        #expect(EffectsPanelView.rows(matching: "round", in: Self.hiddenOut).map(\.title) == ["Transform", "Rounded Corners"])
        #expect(EffectsPanelView.rows(matching: "ROUND", in: Self.hiddenOut).count == 2)
        #expect(EffectsPanelView.rows(matching: "dissolve", in: Self.hiddenOut).map(\.title) == ["Transitions", "Dissolve", "Blur Dissolve", "Additive Dissolve", "Mosaic Dissolve"])
        #expect(EffectsPanelView.rows(matching: "nothing like it", in: Self.hiddenOut).isEmpty)
        #expect(EffectsPanelView.rows(matching: "transform", in: Self.hiddenOut).count == 7)   // matches the bin name: the bin and its six effects
        #expect(EffectsPanelView.rows(matching: "video", in: Self.hiddenOut).count == 52)      // the Video Transitions bin and its forty-nine, Repair > Video Denoise
    }

    // MARK: Tab order
    @Test func tabOrderGoesLeftToRightTopToBottom() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        func field(_ x: CGFloat, _ y: CGFloat) -> ScrubField {
            let f = ScrubField(frame: NSRect(x: x, y: y, width: 60, height: 20)); root.addSubview(f); return f
        }
        // not flipped root: larger y is higher on screen
        let a = field(10, 150), b = field(80, 150), c = field(10, 100)
        let all = [c, b, a]
        #expect(ScrubField.neighbour(of: a, in: all, forward: true) === b)
        #expect(ScrubField.neighbour(of: b, in: all, forward: true) === c)
        #expect(ScrubField.neighbour(of: c, in: all, forward: true) === a)          // wraps
        #expect(ScrubField.neighbour(of: a, in: all, forward: false) === c)
    }

    // MARK: Key menu
    func lanes(selectKey: Bool) -> EffectKeyframeLanesView {
        let m = EffectControlsModel()
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 1.0)])
        m.onEdit = { n, _, _ in m.setClip(n) }
        m.setClip(c)
        if selectKey { m.selectKey(.opacity, id: c.animation.opacity.track.keys[0].id, extend: false) }
        return EffectKeyframeLanesView(model: m)
    }

    @Test func keyMenuHasPremiereInterpolationEntries() {
        let items = lanes(selectKey: true).makeKeyItems(onKey: true)
        let titles = items.filter { $0.kind == .action }.map(\.title)
        #expect(titles == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold", "Hold Ahead", "Custom\u{2026}", "Temporal Interpolation", "Keyframe Velocity\u{2026}", "Scale Time\u{2026}", "Loop\u{2026}", "Convert to Keys", "Wiggle\u{2026}", "Presets", "Copy", "Delete"])
    }

    @Test func emptySpaceMenuHasNoDeadEntries() {
        #expect(lanes(selectKey: false).makeKeyItems(onKey: false).isEmpty)
    }
}
