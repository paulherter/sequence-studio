import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct VariantOverrideResetTests {
    private func make() -> (EditorSession, Clip.ID, FormatVariant.ID) {
        let fd = Time(1, 30)
        let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1))
        let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var track = Track(kind: .video)
        try! track.overwrite(c)
        let t = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [track])
        let s = EditorSession(project: Project(name: "P", media: [m], timelines: [t]), engine: StubProgramEngine())
        let v = s.addVariant(name: "Vertical", width: 1080, height: 1920)!
        _ = s.attempt("Set") {
            try $0.editOverride(clip: c.id, variant: v) { o in
                o.position = AnimatedProperty(Vec2(10, 20))
                o.rotation = AnimatedProperty(15)
                o.tiltX = AnimatedProperty(5); o.tiltY = AnimatedProperty(7)
            }
        }
        return (s, c.id, v)
    }

    @Test func resetDropsOnlyThatProperty() {
        let (s, c, v) = make()
        #expect(s.hasVariantOverride(.position, clip: c))
        #expect(s.resetVariantOverride(.position, clip: c))
        let o = s.activeTimeline!.override(of: c, in: v)
        #expect(o?.position == nil)
        #expect(o?.rotation != nil)
        #expect(!s.hasVariantOverride(.position, clip: c))
        #expect(s.undo())
        #expect(s.hasVariantOverride(.position, clip: c))
    }

    @Test func tiltClearsBothAxes() {
        let (s, c, v) = make()
        #expect(s.resetVariantOverride(.tilt, clip: c))
        let o = s.activeTimeline!.override(of: c, in: v)
        #expect(o?.tiltX == nil && o?.tiltY == nil)
    }

    @Test func nothingToResetWithoutOverrideOrVariant() {
        let (s, c, _) = make()
        #expect(!s.resetVariantOverride(.scale, clip: c))
        s.setActiveVariant(nil)
        #expect(!s.hasVariantOverride(.position, clip: c))
        #expect(!s.resetVariantOverride(.position, clip: c))
    }
}
