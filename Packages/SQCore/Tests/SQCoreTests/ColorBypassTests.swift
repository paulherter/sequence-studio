import Foundation
import Testing
@testable import SQCore

/// Before / After / Split on the Color page: what "ungraded" means and which half of the picture shows it.
@Suite struct ColorBypassTests {
    @Test func ungradedKeepsTheFootageInterpretationAndDropsTheGrade() {
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        c.useEmbeddedLUT = false
        c.effects[0].basic.exposure = 2
        c.effects[0].inputLUT = .file("/luts/convert.cube")
        c.effects[0].creative.look = .file("/luts/look.cube")
        c.addEffect()
        c.effects[1].basic.contrast = 40
        let u = c.ungraded
        #expect(u.source == .sLog3SGamut3Cine)
        #expect(!u.useEmbeddedLUT)
        #expect(u.effects == ClipColor.defaultEffects)
        #expect(ClipColor.default.ungraded == .default)
    }

    @Test func modesAndTargets() {
        let a = UUID(), b = UUID()
        #expect(ColorBypass(clips: [], mode: .before).isEmpty)
        let before = ColorBypass(clips: [a], mode: .before)
        #expect(!before.isEmpty)
        #expect(before.bypasses(a) && !before.bypasses(b))
        #expect(!before.isSplit)
        #expect(ColorBypass(clips: [a], mode: .split).isSplit)
    }

    @Test func splitShowsTheUngradedPictureOnTheLeftHalf() {
        #expect(ColorBypass.splitWidth(1920) == 960)
        #expect(ColorBypass.splitWidth(1921) == 960)
        #expect(ColorBypass.splitWidth(1) == 0)
        #expect(ColorBypass.splitWidth(0) == 0)
    }

    @Test func ungradedSlotIsItsOwnAndStable() {
        let a = UUID(), b = UUID()
        #expect(ColorBypass.ungradedOwner(a) != a)
        #expect(ColorBypass.ungradedOwner(a) == ColorBypass.ungradedOwner(a))
        #expect(ColorBypass.ungradedOwner(a) != ColorBypass.ungradedOwner(b))
        #expect(ColorBypass.ungradedOwner(ColorBypass.ungradedOwner(a)) == a, "the slot flip is its own inverse")
    }

    @Test func ungradedColorOnlyForBypassedLayers() {
        let a = UUID(), b = UUID()
        var c = ClipColor.default
        c.effects[0].basic.exposure = 1.5
        func request(_ clip: UUID) -> LayerRequest {
            LayerRequest(clip: clip, media: UUID(), track: UUID(), sourceTime: .zero, transform: ClipTransform(), color: c)
        }
        let bypass = ColorBypass(clips: [a], mode: .before)
        let u = bypass.ungraded(request(a))
        #expect(u?.color == c.ungraded && u?.owner == ColorBypass.ungradedOwner(a))
        #expect(bypass.ungraded(request(b)) == nil)
    }
}
