import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// W2.2: Opacity lives inside Motion, Video on top and Audio below, a distinct switch symbol instead of the Premiere fx look.
@Suite @MainActor struct EffectControlsGroupingTests {
    private func clip(_ kind: TrackKind) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
    }

    @Test func motionListsOpacityDirectlyUnderAnchorPoint() {
        #expect(EffectSection.motion.properties == [.position, .scale, .rotation, .tiltX, .tiltY, .anchor, .opacity, .shutterAngle, .antiFlicker])
    }

    @Test func videoClipHasNoSeparateOpacitySection() {
        let m = EffectControlsModel()
        m.setClip(clip(.video))
        #expect(m.visibleSections == [.motion])
    }

    @Test func rowsPutOpacityAndBlendModeUnderAnchor() {
        let rows = EffectControlsLayout.rows(sections: [.motion], collapsed: [], expanded: [], blendModeRow: true)
        #expect(rows.map(\.kind) == [.section(.motion), .property(.position), .property(.scale), .property(.rotation),
                                     .property(.tiltX), .property(.tiltY), .property(.anchor), .property(.opacity), .blendMode, .property(.shutterAngle), .property(.antiFlicker)])
    }

    @Test func groupHeadersSplitVideoAndAudio() {
        let rows = EffectControlsLayout.rows(sections: [.motion, .volume], collapsed: [], expanded: [], groupHeaders: true)
        let kinds = rows.map(\.kind)
        #expect(kinds.first == .group(.video) && kinds[1] == .section(.motion))   // board: VIDEO label above the first section
        #expect(kinds.firstIndex(of: .group(.audio)) == kinds.firstIndex(of: .section(.volume))! - 1)
        #expect(EffectControlsLayout.group(of: .motion) == .video && EffectControlsLayout.group(of: .volume) == .audio)
    }

    @Test func audioClipOnlyGetsAudioGroupWithVolumeRow() {
        let rows = EffectControlsLayout.rows(sections: [.volume], collapsed: [], expanded: [], groupHeaders: true)
        #expect(rows.map(\.kind) == [.group(.audio), .section(.volume), .property(.volume)])
    }

    @Test func audioClipShowsVolumeKeyframes() {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.playhead = Time(2, 1)
        m.setClip(clip(.audio))
        #expect(m.visibleSections == [.volume])
        #expect(m.toggleStopwatch(.volume) == .added)
        #expect(m.isAnimated(.volume) && m.keys(.volume).count == 1)
    }

    @Test func resettingMotionAlsoResetsOpacityAndBlend() {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        var c = clip(.video)
        c.blendMode = .multiply
        m.setClip(c)
        _ = m.setValue(.opacity, to: 40)
        m.resetSection(.motion)
        #expect(m.clip!.blendMode == .normal && m.scalarValue(.opacity) == 1)
    }

    @Test func switchSymbolIsNotThePremiereFX() {
        #expect(EffectControlsSwitch.symbol(on: true) != EffectControlsSwitch.symbol(on: false))
        #expect(EffectControlsSwitch.symbol(on: true) != .unknown && EffectControlsSwitch.symbol(on: false) != .unknown)
    }

    @Test func tiltRowsAreScalarDegreesInMotion() {
        for p in [EffectProperty.tiltX, .tiltY] {
            #expect(p.kind == .scalar && p.section == .motion && p.displayUnit == "\u{00B0}")
            #expect(EffectProperty(rawValue: p.rawValue) == p)
            #expect(p.clampedNative(200) == 89 && p.clampedNative(-200) == -89)
        }
        #expect(EffectProperty.tiltX.title == "Tilt X" && EffectProperty.tiltY.title == "Tilt Y")
    }
}
