import Testing
import Metal
import simd
@testable import SSRender

@Suite struct ScopesTests {
    static func run(_ px: [SIMD3<Float>], width: Int, height: Int, layout: ScopeLayout = ScopeLayout(), stride: Int = 1,
                    format: MTLPixelFormat = .rgba32Float) throws -> (gpu: ScopeCounts, cpu: ScopeCounts, res: ScopeResources, queue: MTLCommandQueue)? {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return nil }
        let scopes = try ScopesGPU(device: device)
        let res = scopes.makeResources(layout: layout)!
        let t = GPUTest.makeTexture(device, width: width, height: height, format: format)
        GPUTest.upload(t, px)
        _ = GPUTest.run(queue) { scopes.encode(source: t, into: res, pixelStride: stride, commandBuffer: $0) }
        let cpuPx = format == .rgba32Float ? px : px.map { SIMD3(Float(Float16($0.x)), Float(Float16($0.y)), Float(Float16($0.z))) }
        return (res.readCounts(), ScopesReference.compute(pixels: cpuPx, width: width, height: height, layout: layout, pixelStride: stride), res, queue)
    }

    @Test func flatGreyOneLevelPerColumnAndCentreBin() throws {
        let w = 128, h = 64
        let px = [SIMD3<Float>](repeating: SIMD3(repeating: 0.18), count: w * h)
        guard let r = try Self.run(px, width: w, height: h) else { return }
        #expect(r.gpu == r.cpu)
        let l = r.gpu.layout
        // every column (512, source 128 wide: 4 columns per source pixel, only every 4th filled) has exactly one non-empty level
        var filled = 0
        for col in 0..<l.waveformWidth {
            let n = (0..<l.waveformLevels).filter { r.gpu.waveformLuma[$0 * l.waveformWidth + col] > 0 }
            if !n.isEmpty { filled += 1; #expect(n.count == 1) }
        }
        #expect(filled == w)
        let vs = r.gpu.vectorscope
        let c = l.vectorscopeSize / 2
        #expect(vs[c * l.vectorscopeSize + c] == UInt32(w * h))
        #expect(vs.reduce(0, +) == UInt32(w * h))
        #expect(r.gpu.maxVectorscope == UInt32(w * h))
        // grey: R'=G'=B'=Y' -> one bin per histogram channel
        for ch in 0..<4 { #expect(r.gpu.histogram[ch * 256..<(ch + 1) * 256].reduce(0, +) == UInt32(w * h)) }
        #expect(r.gpu.maxHistogram == UInt32(w * h))
    }

    @Test func pureRedBin() throws {
        let w = 32, h = 32
        let px = [SIMD3<Float>](repeating: SIMD3(1, 0, 0), count: w * h)
        guard let r = try Self.run(px, width: w, height: h) else { return }
        #expect(r.gpu == r.cpu)
        let n = r.gpu.layout.vectorscopeSize
        let cc = ScopesReference.cbcr(SIMD3(1, 0, 0))
        #expect(abs(cc.y - 0.5) < 1e-6 && abs(cc.x + 0.1146) < 1e-3)
        let b = ScopesReference.vectorscopeBin(cb: cc.x, cr: cc.y, size: n)
        #expect(b.col == 99 && b.row == 0)
        #expect(r.gpu.vectorscope[b.row * n + b.col] == UInt32(w * h))
        // parade: R at top level, G/B at bottom
        let l = r.gpu.layout
        #expect(r.gpu.waveformParade.reduce(0, +) == UInt32(3 * w * h))
        #expect(r.gpu.waveformParade[0 * 3 * l.waveformWidth + 0] > 0)  // R panel, row 0 (top), col 0
        #expect(r.gpu.waveformParade[(l.waveformLevels - 1) * 3 * l.waveformWidth + l.waveformWidth] > 0)  // G panel bottom
    }

    @Test func histogramTotalsWithStride() throws {
        let w = 100, h = 60
        var rng = LCG(s: 21)
        let px = (0..<(w * h)).map { _ in rng.rgb() }
        for stride in [1, 3, 4] {
            guard let r = try Self.run(px, width: w, height: h, stride: stride) else { return }
            let expected = UInt32(((w + stride - 1) / stride) * ((h + stride - 1) / stride))
            for ch in 0..<4 { #expect(r.gpu.histogram[ch * 256..<(ch + 1) * 256].reduce(0, +) == expected) }
            #expect(r.gpu.vectorscope.reduce(0, +) == expected)
            #expect(r.gpu.waveformLuma.reduce(0, +) == expected)
            #expect(r.gpu.waveformParade.reduce(0, +) == 3 * expected)
        }
    }

    @Test func randomImageMatchesReferenceAlmostExactly() throws {
        let w = 256, h = 128
        var rng = LCG(s: 5)
        let px = (0..<(w * h)).map { _ in rng.rgb() * 1.2 }
        guard let r = try Self.run(px, width: w, height: h) else { return }
        // pow() may differ by an ulp from powf(); allow a handful of pixels to land in a neighbouring bin.
        func l1(_ a: [UInt32], _ b: [UInt32]) -> Int { zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } }
        let total = w * h
        #expect(l1(r.gpu.histogram, r.cpu.histogram) <= total / 500)
        #expect(l1(r.gpu.vectorscope, r.cpu.vectorscope) <= total / 200)
        #expect(l1(r.gpu.waveformLuma, r.cpu.waveformLuma) <= total / 200)
        #expect(l1(r.gpu.waveformParade, r.cpu.waveformParade) <= total / 100)
        print("scope random-image L1 diff hist/vec/wave/parade:", l1(r.gpu.histogram, r.cpu.histogram),
              l1(r.gpu.vectorscope, r.cpu.vectorscope), l1(r.gpu.waveformLuma, r.cpu.waveformLuma), l1(r.gpu.waveformParade, r.cpu.waveformParade))
    }

    @Test func resolvedTextureIsNormalized() throws {
        let w = 16, h = 16
        let px = [SIMD3<Float>](repeating: SIMD3(repeating: 0.18), count: w * h)
        guard let r = try Self.run(px, width: w, height: h, layout: ScopeLayout(waveformWidth: 16, waveformLevels: 64, vectorscopeSize: 32)) else { return }
        let device = GPUTest.device!
        let tex = r.res.vectorscope
        let buf = device.makeBuffer(length: tex.width * tex.height * 4, options: .storageModeShared)!
        _ = GPUTest.run(r.queue) { cb in
            let b = cb.makeBlitCommandEncoder()!
            b.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                   to: buf, destinationOffset: 0, destinationBytesPerRow: tex.width * 4, destinationBytesPerImage: tex.width * tex.height * 4)
            b.endEncoding()
        }
        let v = Array(UnsafeBufferPointer(start: buf.contents().bindMemory(to: Float.self, capacity: tex.width * tex.height), count: tex.width * tex.height))
        #expect(v[16 * 32 + 16] == 1)
        #expect(v.reduce(0, +) == 1)
    }

    @Test func timing4K() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let scopes = try ScopesGPU(device: device)
        let res = scopes.makeResources()!
        let t = GPUTest.makeTexture(device, width: 3840, height: 2160, format: .rgba16Float)
        // Non-trivial content so atomics do not all hit one address.
        var px = [SIMD3<Float>](); px.reserveCapacity(3840 * 2160)
        var rng = LCG(s: 1)
        for _ in 0..<(3840 * 2160) { px.append(rng.rgb()) }
        GPUTest.upload(t, px)
        for stride in [1, 4] {
            var best = Double.infinity
            for _ in 0..<5 {
                let cb = GPUTest.run(queue) { scopes.encode(source: t, into: res, pixelStride: stride, commandBuffer: $0) }
                best = min(best, cb.gpuEndTime - cb.gpuStartTime)
            }
            print("GPU scopes (waveform+parade+vectorscope+histogram) 3840x2160 stride \(stride): \(best * 1000) ms")
        }
    }
}
