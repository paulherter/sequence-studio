import Foundation
import Testing
@testable import SQCore

// Hidden layers (PLAYBACK-PERF "Export: hidden layers"): a layer under an opaque picture that fills the canvas is never seen,
// so export does not decode or grade it. The rule only ever says "hidden" when the output cannot change.

private let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
private let upright4K = LayerOcclusion.Picture(width: 2160, height: 3840)

@Suite struct LayerOcclusionTests {
    private func layer(scale: Double = 0.5, position: Vec2 = .zero, opacity: Double = 1, rotation: Double = 0,
                       groups: [LayerGroup] = []) -> LayerRequest {
        LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero,
                     transform: ClipTransform(position: position, scale: Vec2(scale, scale), rotation: rotation, opacity: opacity),
                     groups: groups)
    }

    private func text() -> LayerRequest {
        LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero,
                     generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
    }

    private func hidden(_ layers: [LayerRequest], picture: LayerOcclusion.Picture? = upright4K) -> LayerOcclusion.Result {
        LayerOcclusion.evaluate(layers, canvas: canvas) { _ in picture }
    }

    @Test func aFullOpaquePictureHidesEverythingBelowIt() {
        let r = hidden([layer(), layer(scale: 0.6), layer(), text()])
        #expect(r.hidden == [0, 1])
        #expect(r.cover == 2)
    }

    @Test func nothingIsHiddenUnderTheBottomLayerOrWithoutACover() {
        #expect(hidden([layer(), text()]).hidden.isEmpty)
        #expect(hidden([layer(), text()]).cover == nil)
        #expect(hidden([]).hidden.isEmpty)
    }

    @Test func aPictureThatLeavesCanvasFreeHidesNothing() {
        #expect(hidden([layer(), layer(scale: 0.49)]).hidden.isEmpty)                       // too small
        #expect(hidden([layer(), layer(scale: 0.5, position: Vec2(1, 0))]).hidden.isEmpty)  // exact fit moved by a pixel
        #expect(hidden([layer(), layer(scale: 0.55, position: Vec2(0, -56))]).hidden == [0]) // bigger, moved inside its margin
        #expect(hidden([layer(), layer(scale: 0.55, position: Vec2(0, -120))]).hidden.isEmpty)
    }

    @Test func anchorMovesThePicture() {
        var l = layer(scale: 0.5)
        l.transform.anchor = Vec2(10, 0)
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l.transform.scale = Vec2(0.6, 0.6)
        #expect(hidden([layer(), l]).hidden == [0])
    }

    @Test func aCoverMustBePlainOpaqueAndUpright() {
        #expect(hidden([layer(), layer(opacity: 0.99)]).hidden.isEmpty)
        #expect(hidden([layer(), layer(scale: 2, rotation: 3)]).hidden.isEmpty)
        var l = layer(); l.blendMode = .multiply
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.effects = ClipEffects(cornerRadius: 20); l.cornerRadius = 20
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.effects = ClipEffects(pre: EffectMasks(crop: CropInsets(left: 0.1)))
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.inTransition = true
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.gyro = GyroflowOptions()
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.motionBlur = MotionBlurSamples(format: canvas, transforms: [.identity])
        #expect(hidden([layer(), l]).hidden.isEmpty)
        // Frame Blending / Optical Flow need a second frame; without it the layer is a placeholder.
        l = layer(); l.interpolation = .frameBlend
        #expect(hidden([layer(), l]).hidden.isEmpty)
        l = layer(); l.interpolation = .opticalFlow
        #expect(hidden([layer(), l]).hidden.isEmpty)
        // A source that is not known to be opaque (alpha video, a still, not decoded yet).
        #expect(hidden([layer(), layer()], picture: nil).hidden.isEmpty)
        // A generator never covers.
        #expect(hidden([layer(), text()]).hidden.isEmpty)
    }

    @Test func layersThatBelongToATransitionOrKeepStateStayEvenWhenCovered() {
        var inTransition = layer(); inTransition.inTransition = true
        var temporal = layer(); temporal.effects.temporal = TemporalFilter(denoise: .init(framesEachSide: 2))
        let r = hidden([inTransition, temporal, text(), layer(), layer()])
        #expect(r.hidden == [3])      // only the plain media layer goes: generators cost no decode and stay
        #expect(r.cover == 4)
    }

    @Test func theTopmostCoverCounts() {
        let r = hidden([layer(), layer(), text(), layer(), layer(opacity: 0.5)])
        #expect(r.cover == 3)
        #expect(r.hidden == [0, 1])
    }

    @Test func aCoverInsideANestNeedsTheNestToFillTheCanvasToo() {
        let inner = SequenceFormat(width: 2160, height: 3840, frameDuration: Time(1, 30))
        func group(scale: Double, opacity: Double = 1) -> LayerGroup {
            LayerGroup(clip: UUID(), track: UUID(), sequence: UUID(), format: inner,
                       transform: ClipTransform(scale: Vec2(scale, scale), opacity: opacity))
        }
        // The inner picture fills the inner canvas (2160x3840 at scale 1), the nest fills the outer one at 0.5.
        let full = group(scale: 0.5)
        #expect(hidden([layer(), layer(scale: 1, groups: [full])]).hidden == [0])
        // A lower layer of the same nest is hidden as well.
        #expect(hidden([layer(), layer(scale: 1, groups: [full]), layer(scale: 1, groups: [full])]).hidden == [0, 1])
        // The nest is smaller than the canvas, or faded: only what lies under the picture inside the nest is hidden.
        let small = group(scale: 0.4)
        #expect(hidden([layer(), layer(scale: 1, groups: [small]), layer(scale: 1, groups: [small])]).hidden == [1])
        let faded = group(scale: 0.5, opacity: 0.5)
        #expect(hidden([layer(), layer(scale: 1, groups: [faded])]).hidden.isEmpty)
        // The inner picture does not fill the nest.
        #expect(hidden([layer(), layer(scale: 0.5, groups: [full])]).hidden.isEmpty)
    }
}
