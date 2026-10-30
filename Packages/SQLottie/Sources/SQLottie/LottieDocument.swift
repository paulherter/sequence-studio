import CThorVG
import Foundation
import SQCore
import SQRender
import Synchronization

/// Lottie clips drawn by ThorVG's software renderer (MIT, vendored in CThorVG). This part is portable: the documents, the
/// frame timing and the 8-bit to linear conversion; the Mac turns frames into CoreVideo buffers (LottieRenderer.swift),
/// Windows into GPU textures through `portableFrame(for:canvas:)`.
///
/// Limits: no Lottie expressions, no text layers that rely on fonts (outlined text is fine), no 3D layers; unsupported parts
/// are skipped by ThorVG. Colors in the file are display-encoded (BT.709 OETF) like solids and shapes and are linearised
/// with the same inverse OETF.
public enum LottieRenderer {
    /// Byte budget of the Mac frame cache.
    public static let cacheBudget = 256 << 20

    /// True when the clip's file can be drawn (tests, UI).
    public static func canRender(_ g: GeneratorRef) -> Bool { document(for: g, clip: UUID()) != nil }

    /// Drops all cached documents and frames (memory pressure, tests).
    public static func clearCache() {
        docs.withLock { $0 = [:] }
        clearFrameCache()
    }

    /// One frame of a Lottie clip without CoreVideo (Windows): linear premultiplied RGBA floats, top row first, the size
    /// `layer(for:canvas:)` gives on the Mac. `key` names the frame (same key, same pixels) for the caller's texture cache.
    public enum PortableFrame: Sendable {
        case offline, hidden
        case picture(key: FrameKey, width: Int, height: Int, pixels: [Float])
    }

    /// A drawn frame's identity: the document, the animation frame and the raster size.
    public struct FrameKey: Hashable, Sendable { var doc: UInt64; var frame: UInt32; var width: Int; var height: Int }

    /// The key of the frame `r` shows (nil for an unreadable file), so a cached texture can skip the draw.
    public static func frameKey(for r: LayerRequest, canvas: SequenceFormat) -> FrameKey? {
        guard let g = r.generator, let doc = document(for: g, clip: r.clip) else { return nil }
        let (frame, w, h) = placement(doc, r, canvas)
        return FrameKey(doc: doc.id, frame: frame.bitPattern, width: w, height: h)
    }

    /// The Mac `layer(for:canvas:)` picture as floats: unreadable is `.offline`, a failed draw `.hidden`.
    public static func portableFrame(for r: LayerRequest, canvas: SequenceFormat) -> PortableFrame {
        guard let g = r.generator, let doc = document(for: g, clip: r.clip) else { return .offline }
        let (frame, w, h) = placement(doc, r, canvas)
        guard let rgba = doc.render(frame: frame, width: w, height: h) else { return .hidden }
        return .picture(key: FrameKey(doc: doc.id, frame: frame.bitPattern, width: w, height: h), width: w, height: h,
                        pixels: linearPixels(rgba))
    }

    /// The animation frame (from the in point) and the raster size of `r` on `canvas`.
    static func placement(_ doc: Document, _ r: LayerRequest, _ canvas: SequenceFormat) -> (Float, Int, Int) {
        let size = LottieTiming.rasterSize(info: doc.info, canvasWidth: canvas.displayWidth, canvasHeight: canvas.height)
        let frame = Float(LottieTiming.frame(localTime: r.localTime, info: doc.info, spec: doc.spec) - doc.info.inPoint)
        return (frame, size.width, size.height)
    }

    // MARK: Documents

    /// A parsed animation: the spec, its header, and the ThorVG handle (used under `lock`).
    final class Document: @unchecked Sendable {
        let spec: LottieSpec
        let info: LottieInfo
        let id: UInt64
        private let handle: OpaquePointer
        private let lock = Mutex(())
        init?(spec: LottieSpec, info: LottieInfo, id: UInt64) {
            guard let h = spec.json.withUnsafeBytes({ raw -> OpaquePointer? in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
                return sqlottie_open(p, UInt32(raw.count))
            }) else { return nil }
            self.spec = spec; self.info = info; self.id = id; self.handle = h
        }
        deinit { sqlottie_close(handle) }

        /// Straight RGBA8 pixels of `frame` at `width` x `height`, or nil when ThorVG fails.
        func render(frame: Float, width: Int, height: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            let rc = lock.withLock { _ in
                out.withUnsafeMutableBufferPointer { sqlottie_render(handle, frame, UInt32(width), UInt32(height), $0.baseAddress) }
            }
            return rc == 0 ? out : nil
        }
    }

    struct DocKey: Hashable { var clip: Clip.ID; var print: UInt64 }
    static let docs = Mutex([DocKey: Document]())
    static let nextID = Atomic<UInt64>(1)

    /// Cheap content fingerprint of a payload (size + sampled bytes + the tail, where the play settings sit); a full hash of
    /// several MB per frame would cost more than a cached draw.
    static func fingerprint(_ d: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 ^ UInt64(d.count)
        func mix(_ b: UInt8) { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        d.withUnsafeBytes { raw in
            let n = raw.count
            let step = max(n / 512, 1)
            var i = 0
            while i < n { mix(raw[i]); i += step }
            for j in max(0, n - 512)..<n { mix(raw[j]) }
        }
        return h
    }

    static func document(for g: GeneratorRef, clip: Clip.ID) -> Document? {
        guard g.kind == GeneratorRef.lottie else { return nil }
        let key = DocKey(clip: clip, print: fingerprint(g.payload))
        if let d = docs.withLock({ $0[key] }) { return d }
        guard let spec = g.lottieSpec, let info = LottieInfo.parse(spec.json),
              let d = Document(spec: spec, info: info, id: nextID.wrappingAdd(1, ordering: .relaxed).oldValue) else { return nil }
        docs.withLock { m in
            if m.count >= 16 { m.removeAll() }       // a handful of Lottie clips per project: simple reset beats an LRU
            m[key] = d
        }
        return d
    }

    // MARK: Pixels

    /// Display-encoded 8-bit -> linear (BT.709 inverse OETF, the shape renderer's), once per value.
    static let linearLUT: [Float] = (0..<256).map { i in
        let e = Double(i) / 255
        return Float(e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45))
    }

    /// Straight display-encoded RGBA8 -> linear premultiplied RGBA floats.
    static func linearPixels(_ rgba: [UInt8]) -> [Float] {
        let lut = linearLUT
        var out = [Float](repeating: 0, count: rgba.count)
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] != 0 {
            let a = Float(rgba[i + 3]) / 255
            out[i] = lut[Int(rgba[i])] * a
            out[i + 1] = lut[Int(rgba[i + 1])] * a
            out[i + 2] = lut[Int(rgba[i + 2])] * a
            out[i + 3] = a
        }
        return out
    }
}

#if !canImport(CoreVideo)
extension LottieRenderer {
    static func clearFrameCache() {}
}
#endif
