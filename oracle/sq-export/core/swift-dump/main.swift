import Foundation

// MARK: Stubs (verbatim copies of small pieces whose files need SQCore)

public enum GainMath {
    public static let silenceFloorDB: Double = -120
    public static func linear(fromDB db: Double) -> Double {
        if db.isNaN || db <= silenceFloorDB { return 0 }
        return pow(10, db / 20)
    }
    public static func dB(fromLinear g: Double) -> Double { g <= 0 ? -.infinity : 20 * log10(g) }
}

public struct LoudnessNormalization: Sendable, Hashable, Codable {
    public var targetLUFS: Double
    public var truePeakCeilingDB: Double
    public init(targetLUFS: Double = -14, truePeakCeilingDB: Double = -1) {
        self.targetLUFS = targetLUFS; self.truePeakCeilingDB = truePeakCeilingDB
    }
}

public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var channels: Int
    public init(samples: [Float], channels: Int) { self.samples = samples; self.channels = channels }
    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
}
public protocol AudioSource: Sendable {
    var sampleRate: Int { get }
    var channels: Int { get }
    func nextChunk(maxFrames: Int) async throws -> AudioChunk?
}
public protocol RewindableAudioSource: AudioSource { func rewind() async throws }

// `Time` lives in SQCore; the dump needs the two fields only.
public struct Time { public var value: Int64; public var timescale: Int64; public init(_ v: Int64, _ s: Int64) { value = v; timescale = s } }

enum ExportQueue {
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let s = name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix(".") ? "Export" + s : s
    }
}

// MARK: Sources without transcendental functions (bit-exact input on every platform)

final class WaveSource: RewindableAudioSource, @unchecked Sendable {
    let sampleRate = 48_000, channels = 2
    let base: Float, burst: Float, total: Int, burstLen: Int
    private var pos = 0
    init(base: Float, burst: Float, seconds: Int, burstLen: Int = 48) { self.base = base; self.burst = burst; total = seconds * 48_000; self.burstLen = burstLen }
    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        let n = min(maxFrames, total - pos)
        guard n > 0 else { return nil }
        var s = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let f = pos + i
            // A 240-sample triangle (200 Hz) with a burst every half second.
            let ph = f % 240
            let tri = Float(ph < 120 ? ph : 240 - ph) / 60 - 1
            let a: Float = (f % 24_000) < burstLen ? burst : base
            s[i * 2] = a * tri; s[i * 2 + 1] = a * tri * 0.5
        }
        pos += n
        return AudioChunk(samples: s, channels: 2)
    }
    func rewind() async throws { pos = 0 }
}

/// The sine source of LoudnessLimitingTests: uses `sin`, so the Rust side compares these rows with a tolerance.
final class SinSource: RewindableAudioSource, @unchecked Sendable {
    let sampleRate = 48_000, channels = 2
    let base: Float, burst: Float, total: Int
    private var pos = 0
    init(base: Float, burst: Float, seconds: Int) { self.base = base; self.burst = burst; total = seconds * 48_000 }
    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        guard pos < total else { return nil }
        let n = min(maxFrames, total - pos)
        var s = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let f = pos + i
            let a = (f % 24_000) < 48 ? burst : base
            let v = a * Float(sin(2 * Double.pi * 1000 * Double(f) / 48_000))
            s[i * 2] = v; s[i * 2 + 1] = v
        }
        pos += n
        return AudioChunk(samples: s, channels: 2)
    }
    func rewind() async throws { pos = 0 }
}

func hex(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func line(_ name: String, _ fields: [String]) { print(([name] + fields).joined(separator: "\t")) }
func dbl(_ d: Double) -> String { d.isInfinite ? (d < 0 ? "-inf" : "inf") : "\(d)" + "|" + hex(d) }

func fnv(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

func run() async throws {
    // Loudness: measurement, plan, report.
    let cases: [(String, Float, Float, Int, Int, LoudnessNormalization)] = [
        ("quiet", 0.05, 0.05, 4, 48, LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)),
        ("loud", 0.9, 0.9, 4, 48, LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)),
        ("peaky", 0.1, 0.8, 6, 48, LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)),
        ("lowceiling", 0.25, 0.25, 4, 48, LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -20)),
        ("ebu", 0.05, 0.3, 4, 48, LoudnessNormalization(targetLUFS: -23, truePeakCeilingDB: -1)),
        ("short1", 0.2, 1.0, 6, 6, LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)),
        ("short2", 0.15, 0.95, 6, 12, LoudnessNormalization(targetLUFS: -12, truePeakCeilingDB: -3)),
        ("short3", 0.1, 0.9, 6, 240, LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -2)),
    ]
    for (name, base, burst, secs, bl, s) in cases {
        let src = WaveSource(base: base, burst: burst, seconds: secs, burstLen: bl)
        let m = try await LoudnessNormalizer.measure(src)
        line("measure.\(name)", [dbl(m.integratedLUFS), dbl(m.truePeakDB)])
        line("gain.\(name)", [dbl(LoudnessNormalizer.gainDB(for: m, settings: s))])
        let plan = try await LoudnessNormalizer.plan(for: src, measured: m, settings: s)
        line("plan.\(name)", [dbl(plan.gainDB), plan.limiterCeilingDB.map(dbl) ?? "none", dbl(plan.result.integratedLUFS), dbl(plan.result.truePeakDB)])
        let n = try await NormalizedAudioSource.make(WaveSource(base: base, burst: burst, seconds: secs, burstLen: bl), settings: s)
        let r = LoudnessReport(normalized: n, settings: s)
        line("report.\(name)", [r.summary, "\(r.limitedByCeiling)", "\(r.limiterUsed)", dbl(r.outputLUFS), dbl(r.outputTruePeakDB)])
        // First chunk of the normalized stream: exact float bits.
        var bytes: [UInt8] = []
        if let c = try await n.nextChunk(maxFrames: 2048) { for v in c.samples.prefix(4096) { withUnsafeBytes(of: v.bitPattern) { bytes += $0 } } }
        line("stream.\(name)", [fnv(bytes)])
    }
    for (name, base, burst, secs, s) in [("peaky", Float(0.1), Float(0.8), 6, LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)),
                                         ("tone", Float(0.05), Float(0.05), 4, LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -1)),
                                         ("lowceiling", Float(0.25), Float(0.25), 4, LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -20))] {
        let src = SinSource(base: base, burst: burst, seconds: secs)
        let m = try await LoudnessNormalizer.measure(src)
        let n = try await NormalizedAudioSource.make(SinSource(base: base, burst: burst, seconds: secs), settings: s)
        let r = LoudnessReport(normalized: n, settings: s)
        line("sin.\(name)", [dbl(m.integratedLUFS), dbl(m.truePeakDB), dbl(n.gainDB), n.limiterCeilingDB.map(dbl) ?? "none",
                             dbl(n.result.integratedLUFS), dbl(n.result.truePeakDB), "\(r.limiterUsed)", "\(r.limitedByCeiling)", r.summary])
    }
    for (l, p) in [(-20.0, -10.0), (-20, -4), (-10, -0.5), (-.infinity, -.infinity), (-20, -.infinity)] {
        let m = LoudnessMeasurement(integratedLUFS: l, truePeakDB: p)
        let r = LoudnessReport(measurement: m, settings: LoudnessNormalization())
        line("report.fixed", ["\(l)", "\(p)", dbl(r.gainDB), "\(r.limitedByCeiling)", r.summary])
    }

    // GIF palette: deterministic images.
    func rgba(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<h { for x in 0..<w { let c = f(x, y); out += [c.0, c.1, c.2, 255] } }
        return out
    }
    let images: [(String, Int, Int, [UInt8])] = [
        ("flat", 4, 2, rgba(4, 2) { x, y in x < 2 ? (255, 0, 0) : y == 0 ? (0, 0, 255) : (12, 200, 99) }),
        ("gradient", 256, 64, rgba(256, 64) { x, y in (UInt8(x), UInt8((y * 4) & 255), UInt8(255 - x)) }),
        ("xor", 64, 64, rgba(64, 64) { x, y in (UInt8(x * 4), UInt8(y * 4), UInt8((x ^ y) * 4)) }),
        ("noise", 97, 53, rgba(97, 53) { x, y in
            let v = UInt32(truncatingIfNeeded: x &* 2_654_435_761 &+ y &* 40_503 &+ x &* y)
            return (UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)) }),
        ("sky", 120, 80, rgba(120, 80) { x, y in (UInt8(40 + y), UInt8(90 + y * 2 / 3), UInt8(200 - x / 3)) }),
    ]
    for (name, w, h, px) in images {
        let f = px.withUnsafeBytes { GIFPalette.quantize($0, width: w, height: h, bytesPerRow: w * 4) }
        line("gif.\(name)", ["\(f.colors.count)", fnv(f.indices), fnv(f.colors.flatMap { [$0.0, $0.1, $0.2] })])
    }
    let bgra: [UInt8] = [10, 20, 30, 255, 200, 100, 50, 255]
    let fb = bgra.withUnsafeBytes { GIFPalette.quantize($0, width: 2, height: 1, bytesPerRow: 8, rOffset: 2, gOffset: 1, bOffset: 0) }
    line("gif.bgra", [fnv(fb.indices), fnv(fb.colors.flatMap { [$0.0, $0.1, $0.2] })])

    // Still pixels: oetf and all formats of a pattern.
    line("oetf", [0, 0.001, 0.018, 0.018053968510807, 0.02, 0.1, 0.18, 0.5, 0.9, 1, 2, -1].map { "\(FrameStillPixels.oetf(Float($0)).bitPattern)" })
    var halves: [UInt16] = []
    for i in 0..<(7 * 5) {
        let r = UInt16(0x2000 + i * 211 % 0x1C00), g = UInt16(0x3000 + i * 97 % 0x0F00), b = UInt16((i * 331) % 0x3C00)
        let a = UInt16(i % 3 == 0 ? 0 : 0x3800 + i * 13 % 0x0600)
        halves += [r, g, b, a]
    }
    for fmt in FrameStillFormat.allCases {
        let img = halves.withUnsafeBytes { FrameStillPixels.image(halfRGBA: $0, width: 7, height: 5, bytesPerRow: 56, format: fmt) }!
        line("still.\(fmt.rawValue)", [fnv(img.bytes), "\(img.bitsPerChannel)", "\(img.isFloat)", "\(img.hasAlpha)"])
    }
    line("half", [0x0001, 0x03FF, 0x0400, 0x3C00, 0x7BFF, 0x7C00, 0xFC00, 0x8001].map { "\(FrameStillPixels.float(halfBits: UInt16($0)).bitPattern)" })

    // HDR delivery bytes.
    for d in [HDRDelivery(), HDRDelivery(transfer: .hlg, peakNits: 600, frameAverageNits: 180, minNits: 0.01), HDRDelivery(peakNits: 99_999, frameAverageNits: 50_000)] {
        line("hdr", ["\(d.peakNits)", "\(d.frameAverageNits)", d.masteringDisplayData.map { String($0, radix: 16) }.joined(separator: ","),
                    d.contentLightLevelData.map { String($0, radix: 16) }.joined(separator: ",")])
    }

    // Progress tracker.
    var t = ExportProgressTracker()
    var out: [String] = []
    for (i, p) in [0.0, 0.005, 0.02, 0.05, 0.05, 0.2, 0.21, 0.6, 1.0].enumerated() {
        t.record(progress: p, at: Double(i) * 1.5)
        out.append("\(t.progress)/\(t.rate.map(hex) ?? "-")/\(t.remaining.map(hex) ?? "-")")
    }
    line("progress", out)
    line("progress.format", [0, 59.4, 61, 3725, 86399.9].map { ExportProgressTracker.format(seconds: $0) } + [ExportProgressTracker.remainingText(nil), ExportProgressTracker.remainingText(75), ExportProgressTracker.remainingText(0.2)])

    // GIF timing and naming.
    for (name, fd, n) in [("24", Time(1, 24), 240), ("2398", Time(1001, 24000), 240), ("2997", Time(1001, 30000), 300), ("25", Time(1, 25), 50), ("15", Time(1, 15), 31)] {
        let d = GIFTiming.delaysCentiseconds(frameDuration: fd, frameCount: n)
        line("gifdelay.\(name)", [fnv(d.flatMap { [UInt8($0)] }), "\(d.reduce(0, +))", "\(d.prefix(8))"])
    }
    line("naming", [ImageSequenceNaming.fileName(stem: "a/b:c", number: 7, digits: 4, ext: "png"),
                    "\(ImageSequenceNaming.digits(startNumber: 99_990, count: 20))",
                    ImageSequenceNaming.fileNames(stem: " .Shot ", startNumber: 8, count: 3, ext: "tiff").joined(separator: ",")])
    line("sanitize", ["a/b:c", "  .hidden ", "   ", "tab\there", "ok name", "x\u{1}y"].map { ExportQueue.sanitize($0) })
}

try await run()
