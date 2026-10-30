// Mac side of the shader check. `SQGradeMac render lib.metallib out.png` renders the test image through the Slang-made
// MSL with Metal; `SQGradeMac compare a.png b.png` prints max/mean channel difference.
#if canImport(Metal) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import Metal

let size = 256
let exposure: Float = 0.5, saturation: Float = 1.4, vignette: Float = 0.6  // same numbers as SQWinSpike --grade-test

func testImage() -> [UInt8] {  // mirrored in main.swift of SQWinSpike
    var px = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size { for x in 0..<size {
        let i = (y * size + x) * 4
        px[i] = UInt8(x); px[i + 1] = UInt8(y); px[i + 2] = (((x >> 5) ^ (y >> 5)) & 1) == 1 ? 220 : 40
    } }
    return px
}

func writePNG(_ rgba: [UInt8], _ path: String) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    rgba.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: rgba.count) }
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
}

func readRGBA(_ path: String) -> [UInt8]? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width == size, img.height == size else { return nil }
    var px = [UInt8](repeating: 0, count: size * size * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx != nil
    }
    return ok ? px : nil
}

let a = CommandLine.arguments
if a.count == 4, a[1] == "render" {
    guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue(),
          let lib = try? dev.makeLibrary(URL: URL(fileURLWithPath: a[2])) else { print("metal setup failed"); exit(1) }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "vsMain")
    pd.fragmentFunction = lib.makeFunction(name: "psMain")
    pd.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pso: MTLRenderPipelineState
    do { pso = try dev.makeRenderPipelineState(descriptor: pd) } catch { print("pipeline failed: \(error)"); exit(1) }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    let src = dev.makeTexture(descriptor: td)!
    td.usage = [.renderTarget]; td.storageMode = .shared
    let dst = dev.makeTexture(descriptor: td)!
    src.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: testImage(), bytesPerRow: size * 4)
    // Params: exposure, saturation, vignette, pad, size(2), origin(2), texScale(2), pad(2)
    var params: [Float] = [exposure, saturation, vignette, 0, Float(size), Float(size), 0, 0, 1, 1, 0, 0]
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(pso)
    enc.setVertexBytes(&params, length: 48, index: 0); enc.setFragmentBytes(&params, length: 48, index: 0)
    enc.setVertexTexture(src, index: 0); enc.setFragmentTexture(src, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: size * size * 4)
    dst.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    writePNG(px, a[3])
    print("metal wrote \(a[3]) on \(dev.name)")
} else if a.count == 4, a[1] == "compare" {
    guard let p = readRGBA(a[2]), let q = readRGBA(a[3]) else { print("cannot read \(size)x\(size) PNGs"); exit(1) }
    var maxD = 0, sum = 0, n = 0, over1 = 0
    for i in 0..<(size * size) { for c in 0..<3 {
        let d = abs(Int(p[i * 4 + c]) - Int(q[i * 4 + c]))
        maxD = max(maxD, d); sum += d; n += 1; if d > 1 { over1 += 1 }
    } }
    print(String(format: "compare: max channel diff %d (of 255), mean diff %.4f, channels differing by more than 1: %d of %d", maxD, Double(sum) / Double(n), over1, n))
} else {
    print("usage: SQGradeMac render lib.metallib out.png | compare a.png b.png")
}
#else
print("SQGradeMac needs Metal (Mac only)")
#endif
