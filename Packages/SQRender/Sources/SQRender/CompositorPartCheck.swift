#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Synchronization

// Reading a partial buffer in place (`RenderLayer.contentPart`, ENGINE-NOTES "Animated captions") must give the bits of
// the whole picture. Three things in that read are the same on every GPU by construction:
// - texel centers and the half-pixel offset: both samplers follow Metal's own rule (a texel's center at +0.5), the
//   part's coordinate is the whole picture's minus a whole number of texels, and that subtraction is exact in single
//   precision (the result needs no more bits than the larger operand had);
// - the edges of the part: outside it the whole picture is transparent, which is what `clamp_to_zero` returns for a
//   texture with alpha, so a filter tap across the edge mixes with the same zeros;
// - the edges of the whole picture: the coordinate is held half a texel inside, where `clamp_to_edge` would hold it.
// One thing is not: how the sampler turns a coordinate into its two filter weights. The whole picture is read with a
// normalized coordinate (the GPU multiplies by the texture size itself, in whatever precision it likes), the part with
// one multiplied in the shader in single precision. Where the two products differ in the last bit a weight can land
// on the other side of a rounding step. Apple GPUs give the same bits (`PartialContentTests`); for every other GPU
// this file asks the GPU itself, once per process: it draws parts both ways and reads in place only if every value is
// the same. Until it has asked, and when the answer is no, parts are copied into a whole picture first, which moves
// texels without sampling and is exact on any GPU. Only a comparison is an answer: a check that could not be made (no
// queue, no texture, a failed command buffer) is tried again later, `partCheckAttempts` times in all.
/// What the check found per GPU (`MTLDevice.registryID`). One for the process (`Compositor.sharedPartReadLedger`);
/// tests give a compositor its own.
final class PartReadLedger: Sendable {
    private enum Entry { case answer(Bool), failed(Int) }
    private let entries = Mutex<[UInt64: Entry]>([:])

    func answer(_ id: UInt64) -> Bool? {
        entries.withLock { if case .answer(let a) = $0[id] { a } else { nil } }
    }

    /// Notes one run of the check: a comparison result is the answer from now on; a run that could not be made (nil)
    /// counts, and the `Compositor.partCheckAttempts`th such run is a no. Returns the answer, nil = ask again later.
    func record(_ result: Bool?, _ id: UInt64) -> Bool? {
        entries.withLock { all in
            if case .answer(let a) = all[id] { return a }
            if let result { all[id] = .answer(result); return result }
            var failed = 1
            if case .failed(let n) = all[id] { failed = n + 1 }
            if failed >= Compositor.partCheckAttempts { all[id] = .answer(false); return false }
            all[id] = .failed(failed)
            return nil
        }
    }
}

extension Compositor {
    enum PartRead: Sendable { case trusted, unchecked, refused }

    static let sharedPartReadLedger = PartReadLedger()
    /// Runs of the check that could not be made (no queue, no texture, a failed command buffer) before the answer is no.
    static let partCheckAttempts = 3
    /// Renders with a part a compositor lets pass (copying) after such a run before it asks again.
    static let partCheckRetryRenders = 60

    static func initialPartRead(_ device: MTLDevice) -> PartRead {
        if device.supportsFamily(.apple1) { return .trusted }
        guard let known = sharedPartReadLedger.answer(device.registryID) else { return .unchecked }
        return known ? .trusted : .refused
    }

    /// Runs the check a part layer asked for (`partCheckWanted`) and settles `partRead`. Called at the start of a
    /// render, before anything of it is encoded (in split view that is between the two renders of one tick). The check
    /// draws on a compositor and a queue of its own, so nothing of this one moves (plane memo, pools, counters); it
    /// waits for the GPU and compiles that compositor's shaders: one hitch, once per GPU and process. A check that could
    /// not be made settles nothing: parts stay copied and a later render asks again.
    func settlePartRead() {
        partCheckWanted = false
        guard partRead == .unchecked else { return }
        // A skewed read (tests) never answers for the GPU.
        if partReadSkew != .zero, partReadLedger === Self.sharedPartReadLedger { partReadLedger = PartReadLedger() }
        let id = device.registryID
        var answer = partReadLedger.answer(id)   // another compositor may have asked meanwhile
        if answer == nil {
            if partCheckHoldoff > 0 { partCheckHoldoff -= 1; return }
            let result: Bool?
            if let partCheckRunner { result = partCheckRunner() }
            else { result = Self.partReadMatchesCopy(device: device, skew: partReadSkew) }
            answer = partReadLedger.record(result, id)
            if result == nil {
                NSLog("SQRender: the check of the in-place read of text parts could not be made on %@%@", device.name,
                      answer == nil ? " (asked again later)" : "")
            }
        }
        guard let answer else { partCheckHoldoff = Self.partCheckRetryRenders; return }
        partRead = answer ? .trusted : .refused
        if !answer {
            NSLog("SQRender: text parts are copied before drawing on %@ (the in-place read is not known to be bit-equal)", device.name)
        }
    }

    /// Draws parts of small pictures in place and copied into the whole picture first and compares every value:
    /// scaled up and down, turned, off the pixel grid, the part inside the picture and in its corners, and at texel
    /// coordinates in the thousands (a 4K raster), where single precision has the fewest bits left for the weights.
    /// On a compositor, a queue and a target of its own. false: a value differs, or the frames showed nothing. nil: the
    /// check could not be made (nothing is known about the GPU). `managed`: the target's storage, by default shared on
    /// Apple GPUs and managed (synchronized before it is read) on GPUs with memory of their own.
    static func partReadMatchesCopy(device: MTLDevice, skew: SIMD2<Float> = .zero, managed: Bool? = nil) -> Bool? {
        guard let queue = device.makeCommandQueue(), let probe = try? Compositor(device: device) else { return nil }
        probe.partRead = .trusted; probe.partReadSkew = skew
        let managed = managed ?? !device.supportsFamily(.apple1)
        let (cw, ch) = (96, 64)
        let format = SequenceFormat(width: cw, height: ch, frameDuration: Time(1, 25))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: cw, height: ch, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = managed ? .managed : .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        func picture(_ layer: RenderLayer, inPlace: Bool) -> [UInt16]? {
            probe.drawsContentPartsDirectly = inPlace
            guard let cb = queue.makeCommandBuffer(),
                  (try? probe.render(nodes: [.layer(layer)], format: format, into: target, commandBuffer: cb)) != nil else { return nil }
            if managed {
                guard let blit = cb.makeBlitCommandEncoder() else { return nil }
                blit.synchronize(resource: target); blit.endEncoding()
            }
            cb.commit(); cb.waitUntilCompleted()
            guard cb.error == nil else { return nil }
            var out = [UInt16](repeating: 0, count: cw * ch * 4)
            target.getBytes(&out, bytesPerRow: cw * 8, from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0)
            return out
        }
        typealias Case = (whole: (w: Int, h: Int), part: (x: Int, y: Int, w: Int, h: Int), scale: Vec2, rotation: Double, radius: Double)
        let cases: [Case] = [
            ((80, 48), (22, 9, 31, 17), Vec2(1.3, 0.85), 19, 0),
            ((80, 48), (22, 9, 31, 17), Vec2(1.3, 0.85), 19, 6),       // the whole quad, not limited by a scissor
            ((80, 48), (22, 9, 31, 17), Vec2(0.37, 0.61), -41, 0),
            ((80, 48), (22, 9, 31, 17), Vec2(2.73, 2.73), 0, 0),
            ((80, 48), (0, 0, 31, 17), Vec2(1.17, 1.4), 7, 0),
            ((80, 48), (49, 31, 31, 17), Vec2(1.17, 1.4), -7, 0),
            ((4096, 8), (4051, 1, 40, 6), Vec2(1.31, 3.3), 17, 0),
            ((4096, 8), (4051, 1, 40, 6), Vec2(0.83, 2.1), -3, 0),
            ((8, 2304), (1, 2259, 6, 40), Vec2(3.3, 0.87), 11, 0),
            ((8, 2304), (1, 2259, 6, 40), Vec2(2.1, 1.31), -29, 0),
        ]
        for c in cases {
            guard let pb = Self.partCheckPattern(c.part.w, c.part.h) else { return nil }
            var layer = RenderLayer(content: .linearPremultiplied(pb, width: Double(c.whole.w), height: Double(c.whole.h)))
            layer.contentPart = RenderLayer.ContentPart(x: c.part.x, y: c.part.y, wholeWidth: c.whole.w, wholeHeight: c.whole.h)
            layer.cornerRadius = c.radius
            // The part's center a little off the canvas center, whatever the size of the whole picture.
            layer.transform.anchor = Vec2(Double(c.part.x) + Double(c.part.w) / 2 - Double(c.whole.w) / 2,
                                          Double(c.part.y) + Double(c.part.h) / 2 - Double(c.whole.h) / 2)
            layer.transform.position = Vec2(3.37, -2.61)
            layer.transform.scale = c.scale; layer.transform.rotation = c.rotation
            guard let a = picture(layer, inPlace: true), let b = picture(layer, inPlace: false) else { return nil }
            guard a == b else { return false }
            // Something was drawn: red is zero in the cleared target and never in the pattern.
            guard stride(from: 0, to: a.count, by: 4).contains(where: { a[$0] != 0 }) else { return false }
        }
        return true
    }

    /// A premultiplied half-float picture that differs in every texel, with soft alpha (bit patterns written directly).
    private static func partCheckPattern(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any]
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &made) == kCVReturnSuccess,
              let pb = made else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let a = 0.25 + 0.75 * Float((x * 7 + y * 13) % 17) / 16
                row[x * 4] = Float16(a * (0.2 + 0.8 * Float(x) / Float(w)))
                row[x * 4 + 1] = Float16(a * Float(y) / Float(h))
                row[x * 4 + 2] = Float16(a * 0.6)
                row[x * 4 + 3] = Float16(a)
            }
        }
        return pb
    }
}
#endif
