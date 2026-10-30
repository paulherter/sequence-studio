import Foundation
import SQCore
import SQFrame

/// Frame Blending (Time Interpolation): a layer shown at a source time between two decoded source frames is the mix of the
/// frame before and the frame after, weighted by the fractional position. `RenderLayer.blend` carries the second frame;
/// the compositor converts both to RGB (source-encoded), mixes `a * (1 - weight) + b * weight` on the GPU and goes on with
/// the mix like with any other frame (color pipeline, then the transform).
public struct FrameBlend: Sendable {
    /// The later source frame.
    public var next: SQFrame
    /// Share of `next` in the mix, 0 ..< 1.
    public var weight: Float
    /// Optical flow instead of the plain mix (`TimeInterpolation.opticalFlow`): both frames are moved along their
    /// measured motion to the instant. nil = plain mix.
    public var flow: OpticalFlowRequest?

    public init(next: SQFrame, weight: Float, flow: OpticalFlowRequest? = nil) {
        self.next = next; self.weight = weight; self.flow = flow
    }

    /// Fractional position of `sourceTime` inside the source frame that starts at `frameStart` and lasts `frameDuration`.
    /// 0 = exactly on the frame (no blend needed). Clamped to 0 ... 1.
    public static func weight(sourceTime: Time, frameStart: Time, frameDuration: Time) -> Float {
        guard frameDuration > .zero else { return 0 }
        let num = Int128(sourceTime.value) * Int128(frameStart.timescale) - Int128(frameStart.value) * Int128(sourceTime.timescale)
        let den = Int128(sourceTime.timescale) * Int128(frameStart.timescale)
        let w = Double(num) * Double(frameDuration.timescale) / (Double(den) * Double(frameDuration.value))
        return Float(min(max(w, 0), 1))
    }
}
