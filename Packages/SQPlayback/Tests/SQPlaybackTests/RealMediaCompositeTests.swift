import Testing
import Foundation
import CoreVideo
import Metal
import simd
import SQCore
import SQMedia
import SQRender

/// Real camera clips (skipped when absent): VT-decoded frames must be sampleable by the compositor (no `.damaged`
/// placeholder). Sony XAVC 4:2:2 10-bit used to come out of VT as the lossless-compressed `&xf2`.
@Suite(.serialized) struct RealMediaCompositeTests {
    static let videos = NSHomeDirectory() + "/Documents/Videos"

    static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: videos) else { return nil }
        for case let p as String in e where (p as NSString).lastPathComponent == name {
            return URL(fileURLWithPath: videos + "/" + p)
        }
        return nil
    }

    static func fourCCString(_ f: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xff) }, encoding: .macOSRoman) ?? "\(f)"
    }

    static func check(_ url: URL, label: String) async throws {
        let demuxer = try await AVDemuxer(url: url)
        let dec = try VTVideoDecoder(demuxer: demuxer, media: UUID())
        let frames = try await dec.decode(0...5)
        let pb = try #require(frames.last?.pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        print("[composite \(label)] codec=\(dec.info.codec) \(dec.info.chroma) \(dec.info.bitDepth)-bit hw=\(dec.isHardware) fullRangeTag=\(DecodePixelFormat.isFullRange(demuxer.formatDescription)) decoded=\(fourCCString(fmt))")

        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let comp = try Compositor(device: device)
        let (w, h) = (1920, 1080)
        let format = SequenceFormat(width: w, height: h, frameDuration: dec.info.nominalFrameDuration)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: d))
        let cb = try #require(queue.makeCommandBuffer())
        try comp.render([RenderLayer(content: .frame(pb, colorHint: dec.info))], format: format, into: target, commandBuffer: cb)
        cb.commit(); await cb.completed()
        #expect(cb.error == nil)
        #expect(comp.unsupportedFrameCount == 0, "\(label): decoded \(fourCCString(fmt)) not sampleable")

        var px = [Float16](repeating: 0, count: w * h * 4)
        target.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let amber = SIMD3<Float>(0.45, 0.33, 0.05)   // display-encoded; compare loosely after linearising
        func lin(_ e: Float) -> Float { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }
        let amberLin = SIMD3(lin(amber.x), lin(amber.y), lin(amber.z))
        var samples: [SIMD3<Float>] = []
        for gy in stride(from: 60, to: h, by: 120) {
            for gx in stride(from: 80, to: w, by: 160) {
                let i = (gy * w + gx) * 4
                samples.append(SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])))
            }
        }
        let amberCount = samples.filter { simd_distance($0, amberLin) < 0.01 }.count
        #expect(amberCount < samples.count / 2, "\(label): \(amberCount)/\(samples.count) samples are the damaged placeholder")
        let mean = samples.reduce(SIMD3<Float>(repeating: 0), +) / Float(samples.count)
        let spread = samples.map { simd_distance($0, mean) }.max() ?? 0
        #expect(spread > 0.02, "\(label): image is constant (spread \(spread))")
    }

    @Test func sonyXAVC422TenBit() async throws {
        guard let url = Self.find("C2160.MP4") else { return }
        try await Self.check(url, label: "Sony C2160")
    }

    /// Decode throughput of the first 240 Sony frames (chunks of 24, continuing; frames dropped after each chunk).
    @Test func sonyDecodeFPS() async throws {
        guard let url = Self.find("C2160.MP4") else { return }
        let demuxer = try await AVDemuxer(url: url)
        let dec = try VTVideoDecoder(demuxer: demuxer, media: UUID())
        let n = min(240, demuxer.index.count) / 24 * 24
        let clock = ContinuousClock()
        var fmt: OSType = 0
        let t = try await clock.measure {
            for c in stride(from: 0, to: n, by: 24) {
                let f = try await dec.decode(c...(c + 23))
                fmt = CVPixelBufferGetPixelFormatType(f[0].pixelBuffer)
            }
        }
        let fps = Double(n) / (Double(t.components.seconds) + Double(t.components.attoseconds) * 1e-18)
        print(String(format: "[composite Sony fps] %d frames %.1f fps hw=%d format=%@", n, fps, dec.isHardware ? 1 : 0, Self.fourCCString(fmt)))
    }

    @Test func iPhoneHEVC() async throws {
        let url = URL(fileURLWithPath: Self.videos + "/iPhone 18 Pro/Ohne Titel.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try await Self.check(url, label: "iPhone HEVC")
    }

    @Test func p1000065TenBit420() async throws {
        guard let url = Self.find("P1000065.MP4") else { return }
        try await Self.check(url, label: "P1000065")
    }
}
