import SQGPU

/// A fixed headless graph through every converted pass, run the same way on every backend (Mac: Metal, Windows: D3D12):
/// the cross-backend compare renders it on both and compares the PNGs (scripts/win-gpu-check.sh). Two graphs stacked: the
/// effect filters on top, every other shader family (ReferenceFamilies.swift) below.
public enum GPUReferenceGraph {
    /// Size of the whole image (both graphs); each graph is `width x graphHeight`.
    public static let width = 320, height = 2 * graphHeight
    public static let graphHeight = 180

    /// Straight-alpha test picture (rgba32Float rows): ramps, a checker, an alpha falloff in one corner.
    public static func inputPixels() -> [Float] {
        let height = graphHeight
        var px = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let fx = Float(x) / Float(width - 1), fy = Float(y) / Float(height - 1)
                let checker: Float = ((x / 20) + (y / 20)) % 2 == 0 ? 0.9 : 0.1
                let dx = fx - 0.85, dy = fy - 0.8
                px[i] = fx; px[i + 1] = fy * 1.4; px[i + 2] = checker
                px[i + 3] = min(1, max(0, ((dx * dx + dy * dy).squareRoot() - 0.05) * 6))
            }
        }
        return px
    }

    /// Runs both graphs and returns the image as 8-bit RGBA rows: the filter graph on top, the families graph below.
    public static func render<D: GPUDevice>(on device: D, kernels: GPUKernels<D>) throws -> [UInt8] {
        try renderFilters(on: device, kernels: kernels) + renderFamilies(on: device, kernels: kernels)
    }

    /// The filter graph (BT.709-encoded straight color, alpha), `width x graphHeight`.
    static func renderFilters<D: GPUDevice>(on device: D, kernels: GPUKernels<D>) throws -> [UInt8] {
        let w = width, h = graphHeight
        func tex(_ format: GPUPixelFormat = .rgba16Float, cpu: Bool = false, _ tw: Int = w, _ th: Int = h) throws -> D.Texture {
            guard let t = device.makeTexture(GPUTextureDescriptor(width: tw, height: th, format: format, cpuAccessible: cpu)) else {
                throw GPUError.deviceUnavailable("texture \(tw)x\(th)")
            }
            return t
        }
        let input = try tex(.rgba32Float, cpu: true)
        inputPixels().withUnsafeBytes { device.upload($0, bytesPerRow: w * 16, to: input) }
        let a = try tex(), b = try tex(), c = try tex(), d = try tex(), e = try tex(), f = try tex(), g = try tex(), hh = try tex()
        let out = try tex(.rgba32Float, cpu: true)
        var scratch: [D.Texture] = []
        let acquire: (Int, Int) -> D.Texture? = { tw, th in
            guard let t = try? tex(.rgba16Float, cpu: false, tw, th) else { return nil }
            scratch.append(t)
            return t
        }
        guard let cb = device.makeCommandBuffer() else { throw GPUError.deviceUnavailable("command buffer") }
        kernels.premultiply(cb, input, into: a)
        kernels.blur(cb, a, via: b, weights: gaussianWeights(sigma: 3))
        let frameSize = SIMD2<Float>(Float(w - 32), Float(h - 32)), center = SIMD2<Float>(Float(w), Float(h)) / 2
        let rect = GPUFilterPlan.pixelRect(origin: center - frameSize / 2, size: frameSize, width: w, height: h)
        kernels.sharpen(cb, a, into: c, amount: 1.5, rect: rect)
        let angle = Float(30) * .pi / 180
        kernels.mirror(cb, c, into: d, normal: SIMD2(cosApprox(angle), sinApprox(angle)), center: center + SIMD2(40, 0))
        kernels.noise(cb, d, into: e, amount: 0.2, color: true, clip: true, seed: 7)
        kernels.directionalBlur(cb, e, into: f, d: SIMD2(60, 20), acquire: acquire)
        kernels.mosaic(cb, f, into: g, frameCenter: center, frameSize: frameSize, columns: 12, rows: 8, sharp: false, acquire: acquire)
        kernels.blendFrames(cb, g, a, into: hh, weight: 0.3, encoded: false)
        kernels.encode709(cb, hh, into: out)
        device.commitAndWait(cb)
        _ = scratch
        return bytes8(device.download(out), count: w * h * 4)
    }

    /// rgba32Float rows -> 8-bit, clamped to 0...1.
    static func bytes8(_ raw: [UInt8], count: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: count)
        raw.withUnsafeBytes { p in
            let f = p.bindMemory(to: Float.self)
            for i in 0..<count { rgba[i] = UInt8(min(max(f[i], 0), 1) * 255 + 0.5) }
        }
        return rgba
    }

    /// Normalized Gaussian taps -r...r, r = ceil(3 sigma) (same formula as SQRender GaussianBlur.weights).
    public static func gaussianWeights(sigma: Float) -> [Float] {
        let r = Int((3 * sigma).rounded(.up))
        var w = (-r...r).map { k in expApprox(-Float(k * k) / (2 * sigma * sigma)) }
        let sum = w.reduce(0, +)
        for i in w.indices { w[i] /= sum }
        return w
    }

    // No Foundation on purpose (the package stays dependency-free); these only need to match across backends, which they
    // do: both run the same Swift on the CPU.
    static func expApprox(_ x: Float) -> Float {
        var term: Double = 1, sum: Double = 1
        for n in 1..<40 { term *= Double(x) / Double(n); sum += term }
        return Float(sum)
    }
    static func sinApprox(_ x: Float) -> Float {
        var term = Double(x), sum = Double(x)
        for n in stride(from: 3, to: 31, by: 2) { term *= -Double(x) * Double(x) / Double((n - 1) * n); sum += term }
        return Float(sum)
    }
    static func cosApprox(_ x: Float) -> Float { sinApprox(x + .pi / 2) }
}

/// Minimal PNG writer (8-bit RGBA, stored deflate blocks): enough for headless renders on every platform.
public enum GPUPNG {
    public static func encode(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height { raw.append(0); raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)]) }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, raw.count - i), last: UInt8 = i + n >= raw.count ? 1 : 0
            z.append(last); z.append(UInt8(n & 0xff)); z.append(UInt8(n >> 8))
            z.append(UInt8(~n & 0xff)); z.append(UInt8((~n >> 8) & 0xff))
            z.append(contentsOf: raw[i..<(i + n)])
            i += n
        } while i < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in raw { a = (a + UInt32(v)) % 65_521; b = (b + a) % 65_521 }
        z.append(contentsOf: be((b << 16) | a))
        var png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        var ihdr = be(UInt32(width)) + be(UInt32(height))
        ihdr += [8, 6, 0, 0, 0]
        chunk(&png, "IHDR", ihdr); chunk(&png, "IDAT", z); chunk(&png, "IEND", [])
        return png
    }

    static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    static func chunk(_ out: inout [UInt8], _ type: String, _ data: [UInt8]) {
        let t = Array(type.utf8)
        out += be(UInt32(data.count)) + t + data
        var c: UInt32 = 0xffff_ffff
        for v in t + data {
            c ^= UInt32(v)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        }
        out += be(~c)
    }
}
