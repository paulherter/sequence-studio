import SQCore
import SQGPU

extension GPUCompositor {
    /// A premultiplied working-linear picture (rgba16Float, a `render` target) stretched to `target`'s size, alpha kept:
    /// the image-sequence frame at another size than the sequence (the Mac `encodeRGBAHalf`: one bilinear tap per output
    /// pixel, clamped to the edge). Drawn as the compositor's plain layer (Layer.slang mode 3), so it needs no own kernel.
    public func resampleLinear(_ source: D.Texture, into target: D.Texture, commandBuffer cb: D.CommandBuffer) throws {
        let canvas = SequenceFormat(width: target.width, height: target.height, frameDuration: Time(1, 25))
        let d = plain(source, canvas: canvas, size: SIMD2(Float(target.width), Float(target.height)))
        try drawAll([d], into: target, cb, clear: SIMD4(0, 0, 0, 0), additive: false)
    }
}
