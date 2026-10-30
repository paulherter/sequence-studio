import Foundation
import SQAnalysis
import SQCore
import SQDrawKit

/// `--magic-test <media> <dir> [--point x,y] [--frames N] [--from I]` (headless): loads the EdgeTAM models on ONNX Runtime +
/// DirectML, picks the object at the point (frame fractions, default the middle) on frame I, tracks N frames on, and writes
/// the first, middle and last frame with the mask laid over them (red) as PNG into <dir>. Prints the time of each step.
enum WinMagicBench {
    static func run(media: String, directory: String, point: Vec2, frames: Int, from: Int) async -> Bool {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func ms(_ t0: ContinuousClock.Instant) -> Double {
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let engine = WinMagicEngine(store: FrameMatteStore())
        do {
            var t0 = ContinuousClock.now
            _ = try engine.model()
            print(String(format: "magic test: models loaded in %.0f ms (%@)", ms(t0), engine.modelsFolder?.path ?? "?"))
            let id = UUID()
            let src = try engine.source(path: media, media: id)
            print("magic test: \(media) \(src.info.width)x\(src.info.height), \(src.frameCount) frames")
            let key = "bench"
            let at = WinMagicEngine.time(src, index: min(from, src.frameCount - 1))
            let time = Time(Int64((at * 60000).rounded()), 60000)
            t0 = ContinuousClock.now
            let matte = try await engine.pick(path: media, media: id, key: key, points: [MagicPoint(position: point, subtract: false, sourceTime: time)], at: at)
            print(String(format: "magic test: pick %.0f ms (cold: encoder, decoder, memory encoder), matte %@", ms(t0), matte.map { "\($0.width)x\($0.height) area \(Int($0.area))" } ?? "none"))
            guard matte != nil else { print("magic test: nothing picked"); return false }
            try await save(engine, src, key: key, index: from, to: dir.appendingPathComponent("magic-first.png"))
            let last = min(from + frames, src.frameCount - 1)
            t0 = ContinuousClock.now
            let result = try await engine.track(path: media, media: id, key: key, from: at, to: WinMagicEngine.time(src, index: last))
            let total = ms(t0)
            print(String(format: "magic test: tracked %d frames in %.0f ms = %.0f ms per frame (decode, RGBA, encoder, memory attention, decoder, memory encoder), lost: %@",
                         result.frames, total, total / Double(max(result.frames, 1)), result.lost ? "yes" : "no"))
            if result.frames > 0 {
                try await save(engine, src, key: key, index: from + result.frames / 2, to: dir.appendingPathComponent("magic-middle.png"))
                try await save(engine, src, key: key, index: from + result.frames, to: dir.appendingPathComponent("magic-last.png"))
            }
            let parts = (try engine.model()).takeTimings()
            for (name, v) in parts.sorted(by: { $0.key < $1.key }) {
                print(String(format: "magic test: part %@ %d calls, %.1f ms each", name, v.count, v.seconds / Double(max(v.count, 1)) * 1000))
            }
            return result.frames > 0
        } catch {
            print("magic test: failed: \(error)")
            return false
        }
    }

    /// The frame `index` with its stored matte over it in red.
    private static func save(_ engine: WinMagicEngine, _ src: WinMediaSource, key: String, index: Int, to url: URL) async throws {
        guard let item = try await WinMagicEngine.frames(src, index...index).first else { return }
        var px = item.frame.rgba
        let t = WinMagicEngine.time(src, index: item.index)
        if let m = engine.store.matte(key: key, pts: t) {
            let w = item.frame.width, h = item.frame.height
            for y in 0..<h { for x in 0..<w {
                let mx = min(m.width - 1, x * m.width / w), my = min(m.height - 1, y * m.height / h)
                let a = min(max(m[mx, my], 0), 1) * 0.55
                let i = (y * w + x) * 4
                px[i] = UInt8(Float(px[i]) * (1 - a) + 255 * a)
                px[i + 1] = UInt8(Float(px[i + 1]) * (1 - a))
                px[i + 2] = UInt8(Float(px[i + 2]) * (1 - a))
            } }
        } else { print("magic test: no matte at frame \(index)") }
        try PNGWriter.write(RGBAImage(width: item.frame.width, height: item.frame.height, pixels: px), to: url)
    }
}
