import AppKit
import CoreGraphics
import Metal
import MetalPerformanceShaders
import simd
import SQRender

extension Notification.Name {
    /// Posted when the colour picker (white-balance eyedropper) starts or ends, so the Program monitor can show a crosshair.
    static let colorPickStateChanged = Notification.Name("SQColorPickStateChanged")
}

/// Meeting point between a colour control that wants a pixel (white-balance eyedropper) and the Program monitor
/// surface that receives the click. The surface reports the click as a position inside the picture (0…1, y down).
@MainActor
public final class ColorPickHub {
    public static let shared = ColorPickHub()
    private var pending: ((SIMD2<Double>?) -> Void)?
    public var isPicking: Bool { pending != nil }

    /// Starts a pick. `completion` gets the picture position of the next click on the monitor, or nil if cancelled.
    public func begin(_ completion: @escaping (SIMD2<Double>?) -> Void) {
        cancel()
        pending = completion
        NotificationCenter.default.post(name: .colorPickStateChanged, object: self)
    }

    public func cancel() { finish(nil) }

    /// Picture position (0…1, y down) of a click at `p` in the monitor view, for any zoom or pan: the position is taken
    /// inside the canvas rectangle the picture is drawn into (`MonitorViewMapping.canvasRect`). Outside the canvas the
    /// result lies outside 0…1 and cancels the pick.
    public static func position(forClick p: CGPoint, mapping: MonitorViewMapping) -> SIMD2<Double> {
        let r = mapping.canvasRect
        guard r.width > 0, r.height > 0 else { return SIMD2(-1, -1) }
        return SIMD2(Double((p.x - r.minX) / r.width), Double((p.y - r.minY) / r.height))
    }

    /// Called by the Program monitor surface. Positions outside the picture (outside 0…1) cancel.
    public func complete(at p: SIMD2<Double>) {
        let inside = p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1
        finish(inside ? p : nil)
    }

    private func finish(_ p: SIMD2<Double>?) {
        guard let done = pending else { return }
        pending = nil
        NotificationCenter.default.post(name: .colorPickStateChanged, object: self)
        done(p)
    }
}

/// Readback of the Program composite (rgba16Float, working-linear Rec.709, private storage) for the eyedropper, Auto and
/// the look thumbnail. The engine encodes the readback on its own command buffer right after the frame (so it cannot race
/// the next render, see `ProgramEngine.requestFrameCapture`); results arrive asynchronously on the main actor. Nothing
/// here waits for the GPU. The `encode...` functions are the pure parts; the synchronous `...Now` helpers are for tests.
public enum FrameSampler {
    /// Reads the result of an encoded readback after its command buffer completed.
    typealias Reader<T> = @Sendable () -> T?

    // MARK: Async entry points (main actor)

    /// Mean linear RGB of a (2·radius+1)² patch around `position` (0…1, y down); 5 x 5 like Premiere's eyedropper.
    @MainActor
    public static func sampleColor(engine: any ProgramEngine, at position: SIMD2<Double>, radius: Int = 2,
                                   _ done: @escaping @MainActor (SIMD3<Float>?) -> Void) {
        engine.requestFrameCapture(key: "color.pick") { frame, cb in
            guard let read = encodePatch(of: frame, at: position, radius: radius, commandBuffer: cb) else {
                Task { @MainActor in done(nil) }
                return nil
            }
            return { let v = read(); Task { @MainActor in done(v) } }
        }
    }

    /// The composite scaled to about `width` px as linear RGB samples (Auto) or an sRGB image (look thumbnail).
    @MainActor
    public static func sampleScaled(engine: any ProgramEngine, width: Int, key: String,
                                    _ done: @escaping @MainActor ((width: Int, height: Int, linear: [SIMD3<Float>])?) -> Void) {
        engine.requestFrameCapture(key: key) { frame, cb in
            guard let read = encodeScaled(of: frame, width: width, commandBuffer: cb) else {
                Task { @MainActor in done(nil) }
                return nil
            }
            return { let v = read(); Task { @MainActor in done(v.map { (width: $0.0, height: $0.1, linear: $0.2) }) } }
        }
    }

    /// Display luma (BT.709-encoded, 0…1, unclamped above 1 up to 4) of linear samples: the statistics for Auto.
    public static func displayLuma(_ linear: [SIMD3<Float>]) -> [Float] {
        let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        return linear.map { TransferFunctions.bt709OETF(min(max(simd_dot(luma, $0), 0), 4)) }
    }

    // MARK: Encoding (render thread, on the engine's command buffer)

    static func encodePatch(of texture: MTLTexture, at position: SIMD2<Double>, radius: Int,
                            commandBuffer cb: MTLCommandBuffer) -> Reader<SIMD3<Float>>? {
        guard texture.pixelFormat == .rgba16Float, texture.width > 0, texture.height > 0,
              let (x0, y0, w, h) = patch(width: texture.width, height: texture.height, at: position, radius: radius) else { return nil }
        let rowBytes = (w * 8 + 255) / 256 * 256
        guard let buffer = texture.device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        let box = Unchecked(buffer)
        return {
            let raw = box.value.contents()
            var sum = SIMD3<Float>.zero
            for y in 0..<h {
                let row = raw.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { sum += SIMD3(halfToFloat(row[x * 4]), halfToFloat(row[x * 4 + 1]), halfToFloat(row[x * 4 + 2])) }
            }
            return sum / Float(w * h)
        }
    }

    /// Patch rectangle around a 0…1 position, clamped to the texture.
    static func patch(width: Int, height: Int, at p: SIMD2<Double>, radius: Int) -> (Int, Int, Int, Int)? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let cx = min(max(Int(p.x * Double(width)), 0), width - 1), cy = min(max(Int(p.y * Double(height)), 0), height - 1)
        let x0 = max(cx - radius, 0), y0 = max(cy - radius, 0)
        return (x0, y0, min(cx + radius, width - 1) - x0 + 1, min(cy + radius, height - 1) - y0 + 1)
    }

    static func encodeScaled(of texture: MTLTexture, width: Int,
                             commandBuffer cb: MTLCommandBuffer) -> Reader<(Int, Int, [SIMD3<Float>])>? {
        guard texture.pixelFormat == .rgba16Float, texture.width > 0, texture.height > 0 else { return nil }
        let w = min(width, texture.width), h = max(Int((Double(w) * Double(texture.height) / Double(texture.width)).rounded()), 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let small = texture.device.makeTexture(descriptor: d) else { return nil }
        MPSImageBilinearScale(device: texture.device).encode(commandBuffer: cb, sourceTexture: texture, destinationTexture: small)
        let box = Unchecked(small)
        return {
            var half = [UInt16](repeating: 0, count: w * h * 4)
            box.value.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return (w, h, (0..<(w * h)).map { i in SIMD3(halfToFloat(half[i * 4]), halfToFloat(half[i * 4 + 1]), halfToFloat(half[i * 4 + 2])) })
        }
    }

    // MARK: Conversions

    /// sRGB image of linear samples (the look thumbnail).
    public static func image(width w: Int, height h: Int, linear: [SIMD3<Float>]) -> CGImage? {
        guard linear.count == w * h, w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let px = display8(linear[i])
            bytes[i * 4] = px.x; bytes[i * 4 + 1] = px.y; bytes[i * 4 + 2] = px.z
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 0...1 to 0...255, rounded; NaN (a broken pixel or LUT output) becomes 0 instead of trapping.
    static func byte(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max(v, 0), 1) * 255 + 0.5) }

    /// Working-linear Rec.709 -> 8-bit display values (clamped, BT.709 encoded like the monitor path).
    static func display8(_ linear: SIMD3<Float>) -> SIMD3<UInt8> {
        let e = Rec709Output.encode(linear)
        return SIMD3(byte(e.x), byte(e.y), byte(e.z))
    }

    /// IEEE half -> float (no Float16 dependency, so it also builds for x86_64).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = h & 0x8000 != 0 ? -1 : 1
        let e = Int((h >> 10) & 0x1F), m = Float(h & 0x3FF)
        if e == 0 { return sign * m * powf(2, -24) }
        if e == 31 { return m == 0 ? sign * .infinity : .nan }
        return sign * (1 + m / 1024) * powf(2, Float(e - 15))
    }

    // MARK: Synchronous helpers (tests only: they wait for the GPU)

    static func meanColorNow(of texture: MTLTexture, at p: SIMD2<Double>, radius: Int = 2) -> SIMD3<Float>? {
        guard let queue = texture.device.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
              let read = encodePatch(of: texture, at: p, radius: radius, commandBuffer: cb) else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        return cb.status == .completed ? read() : nil
    }

    static func scaledNow(of texture: MTLTexture, width: Int) -> (Int, Int, [SIMD3<Float>])? {
        guard let queue = texture.device.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
              let read = encodeScaled(of: texture, width: width, commandBuffer: cb) else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        return cb.status == .completed ? read() : nil
    }
}

/// Carries a non-Sendable Metal object to the completion handler (it is only read after the command buffer completed).
private final class Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
