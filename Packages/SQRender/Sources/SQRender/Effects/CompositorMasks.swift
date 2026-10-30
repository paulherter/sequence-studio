#if canImport(Metal)
import Accelerate
import Metal
import SQCore
import SQGPU
import simd

extension Compositor {
    /// W6.7: puts a layer's clip masks on its final draw (into the composite, after every effect pass). The mask points are
    /// fractions of the clip's own frame (`maskSize`, or the layer size when that is zero); they go to the shader in centered
    /// layer px, like the fragment's `local`. Layout (float2 entries): per mask (start, count), (mode, inverted),
    /// (feather, expansion), (opacity, source); then all polygons' points. Mirrors `MaskCoverage` (CPU reference).
    /// W9.8: subject masks read `matte` (fragment texture 2); source entry 1 = sample the matte, 2 = no matte (no person:
    /// matte 0 everywhere, like `MaskCoverage` with a nil matte).
    /// Magic masks read `mattes[matteKey]`; several mattes of one draw are packed into one texture (source 1/3/4/5 = its
    /// r/g/b/a channel). `edgeScale` converts Feather / Expansion from layer px to the draw's px (effect passes at 1/pf).
    /// C6 Picture masks read the current level's matte image of their track (`Retainer.pictureScopes`), at most two
    /// distinct images per draw (fragment textures 3 / 4; flag 6 + 2 * slot, + 1 for Brightness), mapped through `screen`
    /// (the draw's px -> the level's canvas px). Without an image or `screen` such a mask covers nothing (flag 2).
    func applyMasks(_ masks: [MaskShape], matte: SubjectMatte?, mattes: [UUID: SubjectMatte] = [:], edgeScale: Float = 1,
                    screen: ScreenMap? = nil, retainer: Retainer, to p: inout Prepared) {
        guard !masks.isEmpty else { return }
        let scope = retainer.pictureScopes.last ?? [:]
        var pictures: [MTLTexture] = []
        var pictureSlot: [Int] = []                 // per mask: index into pictures, -1 = none
        for m in masks {
            guard m.source == .picture, screen != nil, let t = m.pictureTrack.flatMap({ scope[$0] }) else { pictureSlot.append(-1); continue }
            if let i = pictures.firstIndex(where: { $0 === t }) { pictureSlot.append(i) }
            else if pictures.count < 2 { pictures.append(t); pictureSlot.append(pictures.count - 1) }
            else { pictureSlot.append(-1) }
        }
        let (distinct, slot) = Self.matteSlots(masks, matte: matte, mattes: mattes)
        var matteTex: MTLTexture?
        if distinct.count == 1 { matteTex = matteTexture(distinct[0], retainer: retainer) }
        else if distinct.count > 1 { matteTex = packedMatteTexture(distinct, retainer: retainer) }
        let all = Self.maskEntries(masks, frame: p.u.maskSize.x > 0 ? p.u.maskSize : p.u.size, edgeScale: edgeScale,
                                   screen: screen, pictureSlot: pictureSlot, matteSlot: slot, hasMatte: matteTex != nil)
        let bytes = all.count * MemoryLayout<SIMD2<Float>>.stride
        guard let buf = maskBuffer(bytes, retainer: retainer) else { return }
        _ = all.withUnsafeBytes { memcpy(buf.contents(), $0.baseAddress!, $0.count) }
        p.maskData = buf
        p.u.maskCount = UInt32(masks.count)
        p.matteTex = matteTex
        p.picture0 = pictures.first
        p.picture1 = pictures.count > 1 ? pictures[1] : nil
    }

    /// Effect mask input: `out` = `pre` where `masks` do not cover, `post` (the effect's result) where they do. The clip's frame
    /// (`frame`, pass px = layer px / `pf`) sits centered in the textures. false = nothing encoded (`post` stays the result).
    /// `screen`: the layer's final draw (layer px -> the level's canvas px), for Picture masks; pass px are `pf` layer px.
    func encodeMaskScope(_ masks: [MaskShape], layer: RenderLayer, pre: MTLTexture, post: MTLTexture, out: MTLTexture,
                         frame: SIMD2<Float>, pf: Float, screen: ScreenMap? = nil, commandBuffer: MTLCommandBuffer,
                         retainer: Retainer) -> Bool {
        var u = Uniforms()
        u.size = frame; u.maskSize = frame; u.scale = SIMD2(1, 1)
        var q = Prepared(u: u, tex0: pre, tex1: dummy)
        applyMasks(masks, matte: layer.subjectMatte, mattes: layer.mattes, edgeScale: 1 / max(pf, 1),
                   screen: screen?.scaled(pf), retainer: retainer, to: &q)
        guard let md = q.maskData, let enc = computeEncoder(commandBuffer) else { return false }
        var uu = q.u
        enc.setComputePipelineState(maskScopePipeline)
        enc.setTexture(pre, index: 0)
        enc.setTexture(post, index: 1)
        enc.setTexture(out, index: GPUBinding.metalOutputIndex)
        enc.setTexture(q.matteTex ?? dummy, index: 3)
        enc.setTexture(q.picture0 ?? dummy, index: 4)
        enc.setTexture(q.picture1 ?? dummy, index: 5)
        enc.setBytes(&uu, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBuffer(md, offset: 0, index: 2)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (out.width + 15) / 16, height: (out.height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        return true
    }

    /// Up to 4 mattes in the r/g/b/a channels of one texture at the largest one's size (smaller ones resampled), cached
    /// by the mattes' storages so a redraw uploads nothing. The texture is in flight for `retainer`'s frame.
    func packedMatteTexture(_ ms: [SubjectMatte], retainer: Retainer) -> MTLTexture? {
        let keys = ms.map { m in m.values.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        matteLock.lock()
        if let hit = packedMatteCache.first(where: { $0.keys == keys }) {
            let t = inFlight(hit.texture, retainer)
            matteLock.unlock()
            return t
        }
        matteLock.unlock()
        guard let big = ms.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let w = big.width, h = big.height
        let fitted = ms.map { $0.width == w && $0.height == h ? $0 : $0.resampled(width: w, height: h) }
        matteLock.lock(); defer { matteLock.unlock() }
        guard let t = pooledMatte(.rgba16Float, w, h) else { return nil }
        if matteScratch.count < w * h * 4 { matteScratch = [Float16](repeating: 0, count: w * h * 4) }
        // vImage, not a per-pixel loop: two 1920 px mattes every played frame cost 790 ms in a debug build (1 FPS).
        if matteInterleaved.count < w * h * 4 { matteInterleaved = [Float](repeating: 0, count: w * h * 4) }
        let zero = [Float](repeating: 0, count: fitted.count < 4 ? w * h : 0)
        Self.withPlanes(fitted, zero) { planes in
            matteInterleaved.withUnsafeMutableBytes { inter in
                var dst = vImage_Buffer(data: inter.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 16)
                // "ARGB" is only the argument order: channel c of the texture is plane c.
                vImageConvert_PlanarFtoARGBFFFF(&planes[0], &planes[1], &planes[2], &planes[3], &dst, vImage_Flags(kvImageNoFlags))
                matteScratch.withUnsafeMutableBytes { px in
                    var src = vImage_Buffer(data: inter.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w * 4), rowBytes: w * 16)
                    var half = vImage_Buffer(data: px.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w * 4), rowBytes: w * 8)
                    vImageConvert_PlanarFtoPlanar16F(&src, &half, vImage_Flags(kvImageNoFlags))
                    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px.baseAddress!, bytesPerRow: w * 8)
                }
            }
        }
        matteUploads += 1
        packedMatteCache.append((ms, keys, t))
        if packedMatteCache.count > 4 {
            for old in packedMatteCache.prefix(packedMatteCache.count - 4) { retireMatte(old.texture) }
            packedMatteCache.removeFirst(packedMatteCache.count - 4)
        }
        return inFlight(t, retainer)
    }

    /// The matte's texture: cached when this matte (same storage) was drawn recently, else uploaded (into a pooled texture
    /// when one of its size is free). The texture is in flight for `retainer`'s frame.
    func matteTexture(_ m: SubjectMatte, retainer: Retainer) -> MTLTexture? {
        func storage(_ x: SubjectMatte) -> UnsafeRawPointer? { x.values.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        let key = storage(m)
        matteLock.lock(); defer { matteLock.unlock() }
        if let i = matteCache.firstIndex(where: { storage($0.matte) == key && $0.matte.width == m.width && $0.matte.height == m.height }) {
            return inFlight(matteCache[i].texture, retainer)
        }
        guard let t = pooledMatte(.r16Float, m.width, m.height) else { return nil }
        let n = m.width * m.height
        if matteScratch.count < n { matteScratch = [Float16](repeating: 0, count: n) }
        matteScratch.withUnsafeMutableBytes { px in
            m.values.withUnsafeBytes { v in
                // vImage, not a per-pixel loop: a 1920 px matte every played frame cost 180 ms in a debug build.
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v.baseAddress), height: vImagePixelCount(m.height),
                                        width: vImagePixelCount(m.width), rowBytes: m.width * 4)
                var dst = vImage_Buffer(data: px.baseAddress, height: vImagePixelCount(m.height), width: vImagePixelCount(m.width),
                                        rowBytes: m.width * 2)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
            // Row 0 at the top like the layer's `local` y.
            t.replace(region: MTLRegionMake2D(0, 0, m.width, m.height), mipmapLevel: 0, withBytes: px.baseAddress!,
                      bytesPerRow: m.width * 2)
        }
        matteUploads += 1
        matteCache.append((m, t))
        if matteCache.count > 8 {
            for old in matteCache.prefix(matteCache.count - 8) { retireMatte(old.texture) }
            matteCache.removeFirst(matteCache.count - 8)
        }
        return inFlight(t, retainer)
    }

    /// Four planar vImage buffers over `mattes` (all one size), `zero` (that many zeros) for the missing ones.
    private static func withPlanes(_ mattes: [SubjectMatte], _ zero: [Float], _ body: (inout [vImage_Buffer]) -> Void) {
        let w = mattes[0].width, h = mattes[0].height
        func go(_ i: Int, _ acc: [vImage_Buffer]) {
            guard i < 4 else { var planes = acc; body(&planes); return }
            (i < mattes.count ? mattes[i].values : zero).withUnsafeBytes { v in
                go(i + 1, acc + [vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v.baseAddress), height: vImagePixelCount(h),
                                               width: vImagePixelCount(w), rowBytes: w * 4)])
            }
        }
        go(0, [])
    }

    // MARK: Pooling (callers hold `matteLock`)

    /// A free matte texture of this format and size, else a new one (r16Float / rgba16Float are filterable on every GPU).
    private func pooledMatte(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
        if let i = freeMattes.firstIndex(where: { $0.pixelFormat == format && $0.width == w && $0.height == h }) {
            return freeMattes.remove(at: i)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        matteAllocations += 1
        return t
    }

    private func inFlight(_ t: MTLTexture, _ retainer: Retainer) -> MTLTexture {
        matteInFlight[ObjectIdentifier(t), default: 0] += 1
        retainer.mattes.append(t)
        return t
    }

    /// `t` left its cache: free now, or once the frames reading it completed.
    private func retireMatte(_ t: MTLTexture) {
        if matteInFlight[ObjectIdentifier(t)] == nil { keepFree(t) } else { retiredMattes[ObjectIdentifier(t)] = t }
    }

    private func keepFree(_ t: MTLTexture) {
        freeMattes.append(t)
        if freeMattes.count > 8 { freeMattes.removeFirst(freeMattes.count - 8) }
    }

    /// A mask data buffer of at least `length` bytes (power-of-two size class), in flight for `retainer`'s frame.
    func maskBuffer(_ length: Int, retainer: Retainer) -> MTLBuffer? {
        var size = 256
        while size < length { size *= 2 }
        matteLock.lock()
        let reused = freeMaskBuffers.firstIndex(where: { $0.length == size }).map { freeMaskBuffers.remove(at: $0) }
        matteLock.unlock()
        guard let b = reused ?? device.makeBuffer(length: size, options: .storageModeShared) else { return nil }
        retainer.maskBuffers.append(b)
        return b
    }

    /// A frame completed: its matte textures and mask buffers may be reused.
    func releaseMasks(_ mattes: [MTLTexture], buffers: [MTLBuffer]) {
        guard !mattes.isEmpty || !buffers.isEmpty else { return }
        matteLock.lock(); defer { matteLock.unlock() }
        for t in mattes {
            let id = ObjectIdentifier(t)
            let n = (matteInFlight[id] ?? 1) - 1
            if n > 0 { matteInFlight[id] = n; continue }
            matteInFlight[id] = nil
            if let r = retiredMattes.removeValue(forKey: id) { keepFree(r) }
        }
        freeMaskBuffers.append(contentsOf: buffers)
        if freeMaskBuffers.count > 64 { freeMaskBuffers.removeFirst(freeMaskBuffers.count - 64) }
    }

    /// Matte textures allocated so far (bench / tests); a pooled re-upload does not count.
    public var matteTexturesMade: Int { matteLock.lock(); defer { matteLock.unlock() }; return matteAllocations }
}
#endif
