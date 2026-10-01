import AppKit
import Metal
import simd

extension Notification.Name {
    /// Posted when the colour picker (white-balance eyedropper) starts or ends, so the Program monitor can show a crosshair.
    static let colorPickStateChanged = Notification.Name("SSColorPickStateChanged")
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

/// Reads a small patch of the composite (rgba16Float, working-linear Rec.709, private storage) back to the CPU.
public enum FrameSampler {
    /// Mean linear RGB of a (2·radius+1)² patch centred on `position` (0…1, y down). nil when the texture is unusable.
    @MainActor
    public static func meanColor(of texture: MTLTexture, at position: SIMD2<Double>, radius: Int = 3) -> SIMD3<Float>? {
        guard texture.pixelFormat == .rgba16Float, texture.width > 0, texture.height > 0 else { return nil }
        let cx = min(max(Int(position.x * Double(texture.width)), 0), texture.width - 1)
        let cy = min(max(Int(position.y * Double(texture.height)), 0), texture.height - 1)
        let x0 = max(cx - radius, 0), y0 = max(cy - radius, 0)
        let w = min(cx + radius, texture.width - 1) - x0 + 1, h = min(cy + radius, texture.height - 1) - y0 + 1
        let rowBytes = (w * 8 + 255) / 256 * 256
        let device = texture.device
        guard let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let raw = buffer.contents()
        var sum = SIMD3<Float>.zero
        for y in 0..<h {
            let row = raw.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w {
                sum += SIMD3(halfToFloat(row[x * 4]), halfToFloat(row[x * 4 + 1]), halfToFloat(row[x * 4 + 2]))
            }
        }
        return sum / Float(w * h)
    }

    /// IEEE half -> float (no Float16 dependency, so it also builds for x86_64).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = h & 0x8000 != 0 ? -1 : 1
        let e = Int((h >> 10) & 0x1F), m = Float(h & 0x3FF)
        if e == 0 { return sign * m * powf(2, -24) }
        if e == 31 { return m == 0 ? sign * .infinity : .nan }
        return sign * (1 + m / 1024) * powf(2, Float(e - 15))
    }
}
