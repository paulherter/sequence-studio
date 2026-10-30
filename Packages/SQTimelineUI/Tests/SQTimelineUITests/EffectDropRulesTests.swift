import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@Suite struct EffectDropRulesTests {
    func clip(_ kind: TrackKind, linked: Bool = false) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, end: Time(1, 1)), start: .zero,
             link: linked ? UUID() : nil)
    }
    let audioFX = ClipEffect.audioKindPrefix + "gain"

    @Test func lockedTrackNeverLightsUp() {
        #expect(!EffectDropRules.accepts(effectIDs: [ClipEffect.gaussianBlurKind], clip: clip(.video), trackLocked: true))
        #expect(EffectDropRules.accepts(effectIDs: [ClipEffect.gaussianBlurKind], clip: clip(.video), trackLocked: false))
    }

    @Test func pictureEffectNeedsPictureAndSoundEffectNeedsSound() {
        #expect(!EffectDropRules.accepts(effectIDs: [ClipEffect.gaussianBlurKind], clip: clip(.audio), trackLocked: false))
        #expect(!EffectDropRules.accepts(effectIDs: [audioFX], clip: clip(.video), trackLocked: false))
        #expect(EffectDropRules.accepts(effectIDs: [audioFX], clip: clip(.audio), trackLocked: false))
        #expect(EffectDropRules.accepts(effectIDs: [audioFX], clip: clip(.video, linked: true), trackLocked: false))   // its linked sound
        #expect(EffectDropRules.accepts(effectIDs: [ClipEffect.gaussianBlurKind], clip: clip(.audio, linked: true), trackLocked: false))
    }

    @Test func aFolderLightsUpWhenAnyOfItsEffectsFits() {
        #expect(EffectDropRules.accepts(effectIDs: [ClipEffect.gaussianBlurKind, audioFX], clip: clip(.audio), trackLocked: false))
    }

    @Test func libraryPresetsAreLeftToTheApplyPath() {
        #expect(EffectDropRules.accepts(effectIDs: [PresetDrop.effectID(for: UUID())], clip: clip(.audio), trackLocked: false))
    }
}
