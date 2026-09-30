import Metal
import simd
@testable import SSRender

enum GPUTest {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    static func makeTexture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    static func upload(_ tex: MTLTexture, _ px: [SIMD3<Float>]) {
        let n = px.count
        if tex.pixelFormat == .rgba32Float {
            let data = px.map { SIMD4<Float>($0, 1) }
            data.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tex.width * 16) }
        } else {
            let data = px.map { SIMD4<Float16>(Float16($0.x), Float16($0.y), Float16($0.z), 1) }
            data.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tex.width * 8) }
        }
        precondition(n == tex.width * tex.height)
    }

    static func download(_ tex: MTLTexture) -> [SIMD3<Float>] {
        let n = tex.width * tex.height
        if tex.pixelFormat == .rgba32Float {
            var data = [SIMD4<Float>](repeating: .zero, count: n)
            data.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * 16, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
            return data.map { SIMD3($0.x, $0.y, $0.z) }
        }
        var data = [SIMD4<Float16>](repeating: .zero, count: n)
        data.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * 8, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
        return data.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
    }

    static func run(_ queue: MTLCommandQueue, _ body: (MTLCommandBuffer) -> Void) -> MTLCommandBuffer {
        let cb = queue.makeCommandBuffer()!
        body(cb)
        cb.commit()
        cb.waitUntilCompleted()
        return cb
    }
}
