#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQGPU
import SQGPUKernels
import SQGPUMetal

extension Compositor {
    /// The temporal kernels, compiled once per compositor on first use.
    func temporalPipelines() -> TemporalPasses<MetalGPUDevice>? {
        temporalLock.lock(); defer { temporalLock.unlock() }
        if let p = temporalStore { return p }
        guard let p = try? TemporalPasses(device: gpu) else { return nil }
        temporalStore = p
        return p
    }

    /// Runs Deflicker, Video Denoise and Trails on the layer's source frame (with its neighbors) into a pooled intermediate, then the
    /// layer's color pipeline (or the inverse BT.709 OETF without one): straight working-linear color + alpha, drawn with
    /// `linearize = 0` like `blendIntermediate`. nil when anything fails: the layer then draws its plain frame.
    func temporalIntermediate(center: (MTLTexture, MTLTexture), frames tf: TemporalFrames, info: PixelFormatInfo, u: Uniforms,
                              pipeline: ColorPipeline?, width w: Int, height h: Int,
                              commandBuffer: MTLCommandBuffer, retainer: Retainer) -> MTLTexture? {
        guard let tp = temporalPipelines() else { return nil }
        // Neighbor planes (same size and layout as the center only), nearest first.
        func planes(_ list: [SQFrame], limit: Int) -> [TemporalPasses<MetalGPUDevice>.Planes] {
            var out: [TemporalPasses<MetalGPUDevice>.Planes] = []
            for frame in list where out.count < limit {
                let pb = frame.pixelBuffer
                guard CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h,
                      PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb))?.layout == info.layout else { break }
                guard let y = planeTexture(pb, plane: 0, format: info.yFormat, retainer: retainer) else { break }
                var c = dummy
                if !info.singlePlane {
                    guard let ct = planeTexture(pb, plane: 1, format: info.cbcrFormat, retainer: retainer) else { break }
                    c = ct
                }
                out.append((MetalGPUTexture(y), MetalGPUTexture(c)))
            }
            return out
        }
        let limits = TemporalPasses<MetalGPUDevice>.neighborLimits(tf.filter)
        let cb = gpu.wrap(commandBuffer)
        let grade: ((MetalGPUTexture) -> Bool)? = pipeline.map { pipeline in
            { out in
                (try? self.colorGPU.encode(pipeline, source: out.texture, destination: out.texture, commandBuffer: commandBuffer,
                                           quarterTurned: u.quarter & 1 == 1)) != nil
            }
        }
        return tp.run(tf.filter, center: (MetalGPUTexture(center.0), MetalGPUTexture(center.1)),
                      before: planes(tf.before, limit: limits.before), after: planes(tf.after, limit: limits.after), u: u,
                      width: w, height: h, cb, dummy: MetalGPUTexture(dummy), dummyBuffer: MetalGPUBuffer(dummyBuffer),
                      acquire: { w, h in
                          guard let t = self.acquireIntermediate(width: w, height: h) else { return nil }
                          retainer.pooled.append(t)
                          return MetalGPUTexture(t)
                      }, buffer: { self.gpu.makeBuffer(length: $0) }, grade: grade)?.texture
    }
}
#endif
