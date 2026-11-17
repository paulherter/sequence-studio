// Throwaway Swift dumper for oracle/sq-core-time. Compiled by ../run.sh with plain swiftc together with the REAL sources
// Packages/SQCore/Sources/SQCore/{Time,FrameRate,CMXTimecode,EasingSpring,EaseNames,KeyframesEasing,KeyframesSpatial,
// KeyframesModel,WordSegmentation,StepStatus}.swift (KeyframesModel is needed by the easing files: Vec2, Keyframe, Interpolation,
// KeyframeMath). Two files are NOT compiled whole because they extend `Timeline` (a 5k-line model dependency):
//   TextSearch.swift      -> only `enum TextSearch` is cut out by run.sh (awk) into gen/TextSearch.swift; real code, unchanged.
//   SequenceTimecode.swift-> `Timeline.timecodeStart` setter body is COPIED below as `timecodeStartClamp` (one expression).
// stubs.swift stands in for HoldAheadSeen / foldLegacyHoldHelpers (ProjectFile+V77), unused by the dump.
//
// Usage: dump ops <seed> <count>   writes ops.tsv to stdout
//        dump text                 writes text-tables.tsv to stdout
// For text the process is started with `-AppleLocale en_US -AppleLanguages (en)` (run.sh) so Locale.current is en_US.
import Foundation

// MARK: - LCG (documented in ops.tsv header, Rust uses the same)
// state: UInt64, seeded with the seed as given. step: state = state &* 6364136223846793005 &+ 1442695040888963407.
// next32 = UInt32(state >> 32) taken after the step. next64 = (next32() << 32) | next32() (two steps, high word first).
// below(n) = next64() % n (n > 0). range(lo, hi) = lo + below(hi - lo + 1) (Int64, inclusive, hi - lo + 1 fits UInt64 here).
// unit() = Double(next64() >> 11) / 9007199254740992.0 (2^53), in [0, 1).
struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next32() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 32)
    }
    mutating func next64() -> UInt64 { let hi = UInt64(next32()); return (hi << 32) | UInt64(next32()) }
    mutating func below(_ n: UInt64) -> UInt64 { next64() % n }
    mutating func range(_ lo: Int64, _ hi: Int64) -> Int64 { lo &+ Int64(truncatingIfNeeded: below(UInt64(hi &- lo) &+ 1)) }
    mutating func int(_ n: Int) -> Int { Int(below(UInt64(n))) }
    mutating func unit() -> Double { Double(next64() >> 11) / 9007199254740992.0 }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

// MARK: - Formatting
func q(_ s: String) -> String {   // quoted, every scalar outside 0x20-0x7E plus \ and " as \u{hex}
    var o = "\""
    for u in s.unicodeScalars {
        if u.value >= 0x20, u.value <= 0x7E, u != "\\", u != "\"" { o.unicodeScalars.append(u) }
        else { o += "\\u{" + String(u.value, radix: 16, uppercase: false) + "}" }
    }
    return o + "\""
}
func hx(_ d: Double) -> String { let s = String(d.bitPattern, radix: 16); return String(repeating: "0", count: 16 - s.count) + s }
func dec(_ d: Double) -> String { String(format: "%.17g", d) }
func fo(_ d: Double) -> String { hx(d) + "\t" + dec(d) }   // output double: bits, decimal
func ft(_ t: Time) -> String { "\(t.value)/\(t.timescale)" }
func fr(_ r: Range<Int>) -> String { "\(r.lowerBound)..\(r.upperBound)" }
func fcmp(_ r: ComparisonResult) -> Int { r == .orderedAscending ? -1 : (r == .orderedSame ? 0 : 1) }

var out = ""
func emit(_ f: [String]) { out += f.joined(separator: "\t"); out += "\n" }

// MARK: - copied from SequenceTimecode.swift (Timeline.timecodeStart setter): never negative, kept on a whole frame
func timecodeStartClamp(_ newValue: Time, _ frameDuration: Time) -> Time {
    newValue < .zero ? Time.zero : newValue.snapped(to: frameDuration)
}

// CMXTimecode.string traps on frame counts near Int64.max (9 * dropped * tens); only counts below 10^12 are dumped.
func tcText(_ t: Time, _ fd: Time) -> String {
    let n = t.frameIndex(frameDuration: fd)
    return n < 1_000_000_000_000 ? q(CMXTimecode(frameDuration: fd).string(frames: n)) : "skip"
}

let fds: [Time] = FrameRate.standardFrameDurations + [Time(1, 120), Time(1001, 120000), Time(1, 48), Time(1, 100), Time(1, 15), Time(1001, 48000)]
let pi = Int64.max, ni = Int64.min

func genValue(_ g: inout LCG) -> Int64 {
    switch g.int(14) {
    case 0: return g.range(-1000, 1000)
    case 1: return 0
    case 2: return ni
    case 3: return pi
    case 4: return ni + 1
    case 5: return g.pick([1, -1, 2, -2])
    case 6: return Int64(Int32(truncatingIfNeeded: g.next32()))
    case 7: return Int64(bitPattern: g.next64())
    case 8: return pi - g.range(0, 1000)
    case 9: return ni + g.range(0, 1000)
    case 10: return g.range(0, 1_000_000) * 1001
    case 11: return g.range(-5_000_000_000, 5_000_000_000)
    case 12: return g.range(-100_000, 100_000) * g.pick([1, 1001, 24, 25, 30])
    default: return g.range(0, 100_000_000)
    }
}
func genScale(_ g: inout LCG) -> Int64 {
    switch g.int(14) {
    case 0: return 1
    case 1: return 2147483648
    case 2: return g.pick([24000, 30000, 60000, 1000, 90000, 600, 44100, 48000, 25, 30, 24, 50, 60, 12800, 15360])
    case 3, 4: return g.range(1, 2147483648)
    case 5: return Int64(1) << g.range(0, 31)
    case 6: return g.range(1, 100)
    case 7: return g.range(1, 5000) * 1001
    case 8: return g.pick([pi, pi - 1, Int64(1) << 62, (Int64(1) << 62) + 1, 4611686018427387903])
    case 9: return g.range(1, 1_000_000_000)
    case 10: return 254016000000
    default: return g.range(1, 100000)
    }
}
func genTime(_ g: inout LCG) -> Time { Time(genValue(&g), genScale(&g)) }
func genFrameAligned(_ g: inout LCG, _ fd: Time) -> Time { fd * g.range(-100000, 1_000_000) }
func genI128(_ g: inout LCG) -> Int128 {
    switch g.int(6) {
    case 0: return Int128(genValue(&g))
    case 1: return Int128(genValue(&g)) &* Int128(genValue(&g))
    case 2: return Int128(genValue(&g)) &* Int128(genScale(&g)) &* Int128(g.range(1, 1000))   // wrapping i128 mul
    case 3: return (Int128(Int64(bitPattern: g.next64())) << 64) | Int128(g.next64())
    case 4: return Int128(genValue(&g)) * Int128(genScale(&g))
    default: return Int128(g.range(-1_000_000, 1_000_000))
    }
}
func genNonZeroI128(_ g: inout LCG) -> Int128 { var d = genI128(&g); if d == 0 { d = 1 }; return d }

func line(_ f: [String]) { emit(f) }

func runOps(seed: UInt64, count: Int) {
    var g = LCG(seed)
    emit(["# sq-core-time oracle: ops.tsv, recorded from the frozen Swift tree (SQCore Time/FrameRate/CMXTimecode/EasingSpring/EaseNames/KeyframesEasing/KeyframesSpatial/KeyframesModel/WordSegmentation/TextSearch/StepStatus + copied SequenceTimecode setter)"])
    emit(["# seed=\(seed) count=\(count). One record per line, fields separated by TAB. Field 1 = op name, then the inputs, then the literal field `->`, then the outputs."])
    emit(["# LCG: state:u64 = seed; step: state = state &* 6364136223846793005 &+ 1442695040888963407 (wrapping); next32 = (state >> 32) as u32 taken after the step;"])
    emit(["#      next64 = (next32 << 32) | next32 (two steps, high word first); below(n) = next64 % n; range(lo,hi) = lo + below(hi-lo+1) wrapping i64, inclusive; unit = (next64 >> 11) / 2^53."])
    emit(["# Time = `value/timescale` (reduced). i128 = decimal. f64 inputs = 16 hex digits of the IEEE bit pattern; f64 outputs = bits TAB `%.17g` decimal (looser, for humans). Strings = quoted, scalars outside 0x20-0x7E, `\\` and `\"` as \\u{hex}."])
    emit(["# cmp = -1/0/1. bool = 0/1. `nil` = Swift nil. Libm (exp, log, cos, sin) results may differ in the last bit between platforms: Rust compares the bits column first and falls back to a few ulp for the spring ops."])
    emit(["# Ops: init reducing add sub neg mul scaled_t scaled_i halved cmp eq frame_index snapped ceiled frames_x ts_start range seq_fd cmx_init cmx_str cmx_parse cmx_rt ease_names ease_preview spring spring_preview spring_bake bezier track spatial step words words_join tight search"])

    // fixed text lists (also used by text ops below)
    let wordTexts: [String] = [
        "", "Hello world", "  leading   and trailing  ", "tab\tseparated\nnew line", "Hello, world! (really)", "O-Ton und Café",
        "日本語のテキスト、これは。", "（こんにちは）世界", "「引用」です", "한국어 텍스트 입니다", "ＡＢＣ　ＤＥＦ", "emoji 👍🏽 ok 😀",
        "👨‍👩‍👧‍👦 family 🇩🇪🇯🇵 flags", "e\u{301}le\u{301}ve cafe\u{301}", "a\u{200B}b c", "nbsp\u{00A0}here", "line\u{2028}sep", "(open [brackets] {x})",
        "price 5% off.", "ひらがなカタカナ", "中文 English 混合 text", "ーァィ", "ゝゞ々", "，。", "x。y", "（", "a（b）c", "العربية نص", "שלום עולם", "end...", "?!", "\u{20000}\u{20001}ext", "a\r\nb",
    ]
    let tightPairs: [(String, String)] = [("hello", "world"), ("日本", "語"), ("日本", "abc"), ("abc", "日本"), ("", "x"), ("x", ""), ("a、", "b"), ("ＡＢ", "ＣＤ"), ("한", "국"), ("a", "b")]
    let searchTexts: [String] = ["O-Ton und Café au lait", "cafe CAFÉ Café café", "Straße STRASSE strasse", "日本語 日本 語", "aaaa", "e\u{301}e é É", "İstanbul istanbul ISTANBUL", "", "The the THE tHe", "👍 thumbs 👍🏽 up", "a b  c   d"]
    let searchFinds: [String] = ["cafe", "Café", "o-ton", "the", "aa", "é", "ss", "日本", "语", " ", "b c", "", "istanbul", "👍"]

    for _ in 0..<count {
        let k = g.int(100)
        switch k {
        case 0..<6: // init
            let v = genValue(&g), s = genScale(&g); let t = Time(v, s)
            line(["init", "\(v)", "\(s)", "->", ft(t), "\(t.value)", "\(t.timescale)", t.isNegative ? "1" : "0"])
        case 6..<12: // reducing (i128)
            let n = genI128(&g), d = genNonZeroI128(&g); let t = Time(reducing: n, d)
            line(["reducing", "\(n)", "\(d)", "->", ft(t)])
        case 12..<24:
            let a = genTime(&g), b = genTime(&g)
            line(["add", ft(a), ft(b), "->", ft(a + b)])
        case 24..<32:
            let a = genTime(&g), b = genTime(&g)
            line(["sub", ft(a), ft(b), "->", ft(a - b)])
        case 32..<35:
            let a = genTime(&g); line(["neg", ft(a), "->", ft(-a)])
        case 35..<42:
            let a = genTime(&g), n = genValue(&g); line(["mul", ft(a), "\(n)", "->", ft(a * n)])
        case 42..<46:
            let a = genTime(&g), n = genTime(&g), d = genTime(&g)
            if d.value == 0 { line(["scaled_t", ft(a), ft(n), "0/1", "->", "skip"]); break }
            line(["scaled_t", ft(a), ft(n), ft(d), "->", ft(Time.scaled(a, by: n, over: d))])
        case 46..<50:
            let a = genTime(&g), n = genValue(&g); var d = genValue(&g); if d == 0 { d = 7 }
            // scaled(by:over:) takes any non-zero d; a negative d flips the sign inside Time(reducing:)
            line(["scaled_i", ft(a), "\(n)", "\(d)", "->", ft(Time.scaled(a, by: n, over: d))])
        case 50..<52:
            let a = genTime(&g); line(["halved", ft(a), "->", ft(a.halved)])
        case 52..<58:
            let a = genTime(&g); let b = g.int(3) == 0 ? a : genTime(&g)
            line(["cmp", ft(a), ft(b), "->", "\(a < b ? -1 : (a == b ? 0 : 1))", a < b ? "1" : "0", a <= b ? "1" : "0", a > b ? "1" : "0", a >= b ? "1" : "0", a == b ? "1" : "0"])
        case 58..<60: // equality of differently written but equal times, and hash-equal reduced form
            let a = genTime(&g); let m = g.range(1, 1000)
            let big = a.value.multipliedReportingOverflow(by: m).overflow || a.timescale.multipliedReportingOverflow(by: m).overflow
            if big { line(["eq", ft(a), "\(m)", "->", "skip"]); break }
            let b = Time(a.value * m, a.timescale * m)
            line(["eq", ft(a), "\(m)", "->", ft(b), a == b ? "1" : "0"])
        case 60..<70: // frame_index / snapped / ceiled
            let fd = g.pick(fds); let t = g.int(3) == 0 ? genFrameAligned(&g, fd) : (g.int(2) == 0 ? genTime(&g) : Time(g.range(-10_000_000, 100_000_000), g.pick([24000, 30000, 60000, 90000, 1000, 48000])))
            line(["frame_index", ft(t), ft(fd), "->", "\(t.frameIndex(frameDuration: fd))", ft(t.snapped(to: fd)), ft(t.ceiled(to: fd))])
        case 70..<73: // random frame duration, including zero and edge values
            let t = genTime(&g); let fd = g.int(5) == 0 ? Time(0, genScale(&g)) : genTime(&g)
            line(["frame_index_any", ft(t), ft(fd), "->", "\(t.frameIndex(frameDuration: fd))", ft(t.snapped(to: fd)), ft(t.ceiled(to: fd))])
        case 73..<76: // frames(n, frameDuration)
            let fd = g.pick(fds); let n = g.range(-2_000_000, 2_000_000)
            line(["frames_x", "\(n)", ft(fd), "->", ft(Time.frames(n, frameDuration: fd))])
        case 76..<78: // Timeline.timecodeStart setter logic
            let fd = g.pick(fds); let t = g.int(2) == 0 ? genTime(&g) : Time(g.range(-1000, 400_000), g.pick([24, 30, 24000, 90000]))
            let r = timecodeStartClamp(t, fd)
            line(["ts_start", ft(t), ft(fd), "->", ft(r), tcText(r, fd)])
        case 78..<80: // TimeRange
            let s = genTime(&g); var d = genTime(&g); if d.isNegative { d = -d }
            let s2 = g.int(2) == 0 ? s + d.halved : genTime(&g); var d2 = genTime(&g); if d2.isNegative { d2 = -d2 }
            let a = TimeRange(start: s, duration: d), b = TimeRange(start: s2, duration: d2)
            let probe = g.int(2) == 0 ? s + d.halved : genTime(&g)
            let inter = a.intersection(b).map { ft($0.start) + "+" + ft($0.duration) } ?? "nil"
            line(["range", ft(s), ft(d), ft(s2), ft(d2), ft(probe), "->", ft(a.end), a.isEmpty ? "1" : "0", a.contains(probe) ? "1" : "0", a.overlaps(b) ? "1" : "0", inter])
        case 80..<82: // FrameRate.sequenceFrameDuration
            let n = Int(g.range(-2, 2_000_000)); let dur = g.int(8) == 0 ? Time(g.range(-5, 5), 1) : Time(g.range(1, 100_000_000), g.pick([1, 24, 30, 600, 1000, 24000, 30000, 60000, 90000, 48000]))
            line(["seq_fd", "\(n)", ft(dur), "->", ft(FrameRate.sequenceFrameDuration(frameCount: n, duration: dur))])
        case 82..<84: // CMXTimecode.init(frameDuration:)
            let fd = g.int(3) == 0 ? Time(g.range(1, 100), g.range(1, 2147483648)) : g.pick(fds)
            let p = g.int(4) != 0; let c = CMXTimecode(frameDuration: fd, preferDrop: p)
            line(["cmx_init", ft(fd), p ? "1" : "0", "->", "\(c.nominalRate)", c.dropFrame ? "1" : "0"])
        case 84..<89: // CMX string + parse round trip
            let rates: [(Int, Bool)] = [(24, false), (24, true), (25, false), (30, false), (30, true), (60, false), (60, true), (50, false), (12, true), (1, false), (0, false), (-3, true), (120, true), (15, false), (23, false)]
            let (r, dfl) = g.pick(rates); let c = CMXTimecode(nominalRate: r, dropFrame: dfl)
            let n: Int64 = g.int(4) == 0 ? g.range(-100, 5000) : (g.int(2) == 0 ? g.range(0, 50_000_000) : g.range(0, 2_000_000_000))
            let s = c.string(frames: n); let back = c.frames(s)
            line(["cmx_str", "\(r)", dfl ? "1" : "0", "\(n)", "->", "\(c.nominalRate)", c.dropFrame ? "1" : "0", q(s), back.map(String.init) ?? "nil", back == max(n, 0) ? "1" : "0"])
        case 89..<92: // CMX parse arbitrary text
            let r = g.pick([24, 25, 30, 60]); let c = CMXTimecode(nominalRate: r, dropFrame: g.int(2) == 0)
            let cands = ["01:00:00:00", "00:00:00;00", "00:01:00;02", "00:09:59;29", "00:10:00;00", "10:00:00.00", "1:2:3:4", "00:00:00", "00:00:00:00:00", "ab:cd:ef:gh", "-1:00:00:00", "00:00:-5:00", "99:59:59:29", "", "::::", "01;02;03;04", "00:00:00:99", " 00:00:00:00", "00:00:00:0x", "00:00:00:+5", "٠١:٠٠:٠٠:٠٠", "123456789:00:00:00"]
            let text = g.int(3) == 0 ? String(format: "%02d:%02d:%02d%@%02d", g.range(0, 99), g.range(0, 99), g.range(0, 99), g.int(2) == 0 ? ":" : ";", g.range(0, 99)) : g.pick(cands)
            line(["cmx_parse", "\(c.nominalRate)", c.dropFrame ? "1" : "0", q(text), "->", c.frames(text).map(String.init) ?? "nil"])
        case 92: // ease names (tables)
            let curves = EasingCurve.builtIns
            let i = g.int(curves.count + 2)
            if i < curves.count {
                let c = curves[i]
                line(["ease_names", "\(i)", "->", c.id.uuidString, q(c.name), q(c.displayName), c.interpolation.rawValue, hx(c.outHandle.dx), hx(c.outHandle.dy), hx(c.inHandle.dx), hx(c.inHandle.dy)])
            } else {
                let name = i == curves.count ? "My curve" : ""
                let c = EasingCurve(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: name, interpolation: .hold, outHandle: .linear, inHandle: .linear)
                line(["ease_names", "user:\(i)", "->", c.id.uuidString, q(c.name), q(c.displayName), c.interpolation.rawValue])
            }
        case 93: // fixed names
            let names = [EaseName.steady, EaseName.smooth, EaseName.smoothIn, EaseName.smoothOut, EaseName.hold, EaseName.holdAhead, EaseName.fastStart, EaseName.fastEnd, EaseName.gentle, EaseName.smoothIn100, EaseName.smoothOut100, EaseName.softLanding, EaseName.custom, EaseName.customMenu]
            line(["ease_names", "constants", "->", names.map(q).joined(separator: ","), EaseName.keyframeMenu.map(q).joined(separator: ","), EasingLibrary.springPresets.map { q($0.name) + "=" + hx($0.spring.bounce) }.joined(separator: ",")])
        case 94: // ease preview
            let curves = EasingCurve.builtIns; let i = g.int(curves.count); let n = g.int(10)
            line(["ease_preview", "\(i)", "\(n)", "->", curves[i].previewSamples(count: n).map(hx).joined(separator: ",")])
        case 95: // bezier progress
            let t = g.pick([0, 1, -0.2, 1.3, 0.5, g.unit(), g.unit(), g.unit()])
            let o = EaseHandle(dx: g.pick([0, 1, 0.167, 1.0 / 3, g.unit() * 1.4 - 0.2, g.unit()]), dy: g.pick([0, 1, 0.6, g.unit() * 3 - 1, g.unit()]))
            let i = EaseHandle(dx: g.pick([0, 1, 0.167, 1.0 / 3, g.unit() * 1.4 - 0.2, g.unit()]), dy: g.pick([0, 1, 0.6, g.unit() * 3 - 1, g.unit()]))
            line(["bezier", hx(t), hx(o.dx), hx(o.dy), hx(i.dx), hx(i.dy), "->", fo(KeyframeMath.bezierProgress(t, out: o, in: i))])
        case 96: // spring progress + preview + bake
            let b = g.pick([0, 0.4, 0.7, 1, -0.5, 2, g.unit(), g.unit()])
            let sp = SpringEasing(bounce: b)
            switch g.int(3) {
            case 0:
                let t = g.pick([0, 1, -1, 2, 0.5, g.unit(), g.unit(), g.unit(), 1e-9, 0.999999])
                line(["spring", hx(b), hx(t), "->", hx(sp.bounce), fo(sp.progress(t))])
            case 1:
                let n = g.range(0, 12)
                line(["spring_preview", hx(b), "\(n)", "->", sp.previewSamples(count: Int(n)).map(hx).joined(separator: ",")])
            default:
                let start = Time(g.range(-1000, 100_000), g.pick([1, 24, 30, 600, 24000, 90000])), len = Time(g.range(-3, 90), g.pick([30, 24, 1, 7, 1001]))
                let end = start + len; let sps = Int(g.range(-1, 40))
                let a = g.unit() * 200 - 100, bb = g.unit() * 200 - 100
                let keys = sp.bakedKeys(from: a, to: bb, start: start, end: end, samplesPerSecond: sps)
                line(["spring_bake", hx(b), hx(a), hx(bb), ft(start), ft(end), "\(sps)", "->", "\(keys.count)", keys.map { ft($0.time) + "=" + hx($0.value) }.joined(separator: ",")])
            }
        case 97: // interpolatedTime (extreme starts/ends/timescales)
            // interpolatedTime traps (Int128 overflow) for values/timescales near 2^63 (v * ts * n); real callers pass spans of
            // seconds, so the dump stays within |value| <= 2^40 and timescale <= 2^31. Known limit, noted in README.
            func small() -> Time { Time(g.range(-(Int64(1) << 40), Int64(1) << 40), g.range(1, 2147483648)) }
            let s = small(), e = small(); let n = Int(g.range(1, 700)); let i = Int(g.range(0, Int64(n)))
            line(["interp_time", ft(s), ft(e), "\(i)", "\(n)", "->", ft(SpringEasing.interpolatedTime(start: s, end: e, i: i, n: n))])
        case 98: // keyframe track value(at:) and spatial path
            if g.int(2) == 0 {
                let nk = Int(g.range(0, 6)); var times = Set<Int64>(); while times.count < nk { times.insert(g.range(0, 300)) }
                let kinds: [Interpolation] = [.linear, .hold, .bezier, .holdAhead]
                var keys: [Keyframe<Double>] = []; var desc: [String] = []
                for t in times.sorted() {
                    let tm = Time(t, 30); let val = g.unit() * 100 - 50; let ip = g.pick(kinds)
                    let ih = g.int(2) == 0 ? EaseHandle.linear : EaseHandle(dx: g.unit(), dy: g.unit() * 2 - 0.5)
                    let oh = g.int(2) == 0 ? EaseHandle.linear : EaseHandle(dx: g.unit(), dy: g.unit() * 2 - 0.5)
                    keys.append(Keyframe(time: tm, value: val, interpolation: ip, inHandle: ih, outHandle: oh))
                    desc.append("\(ft(tm))|\(hx(val))|\(ip.rawValue)|\(hx(ih.dx))|\(hx(ih.dy))|\(hx(oh.dx))|\(hx(oh.dy))")
                }
                let tr = KeyframeTrack(keys: keys)
                var probes: [Time] = [Time(-5, 30), Time(g.range(0, 310), 30), Time(g.range(0, 9300), 900), Time(g.range(0, 3100), 300)]
                if let f = keys.first { probes.append(f.time) }
                if let l = keys.last { probes.append(l.time + Time(1, 30)) }
                let vals = probes.map { tr.value(at: $0).map(hx) ?? "nil" }
                line(["track", desc.joined(separator: ";"), probes.map(ft).joined(separator: ","), "->", vals.joined(separator: ",")])
            } else {
                func pt() -> Vec2 { Vec2(g.unit() * 2000 - 1000, g.unit() * 2000 - 1000) }
                let p0 = pt(), p1 = pt(), p2 = pt(), p3 = pt(); let res = g.pick([128, 128, 16, 2, 300])
                let path = SpatialPath(p0: p0, p1: p1, p2: p2, p3: p3, resolution: res)
                let f = g.pick([0, 1, 0.5, -0.5, 1.5, g.unit(), g.unit()]); let s = g.unit()
                let a = path.point(atArcFraction: f), b = path.point(atParameter: s)
                line(["spatial", res.description, hx(p0.x), hx(p0.y), hx(p1.x), hx(p1.y), hx(p2.x), hx(p2.y), hx(p3.x), hx(p3.y), hx(f), hx(s), "->", fo(path.length), hx(a.x), hx(a.y), hx(b.x), hx(b.y)])
            }
        case 99: // step status + words + search
            switch g.int(5) {
            case 0:
                let verb = g.pick(["Trim", "Slip", "Slide", "Nudge", ""]); let fr = Int(g.range(-12, 12))
                line(["step", q(verb), "\(fr)", "->", q(StepStatus.line(verb, frames: fr))])
            case 1:
                let t = g.pick(wordTexts)
                line(["words", q(t), "->", "\(WordSegmentation.wordCount(t))", WordSegmentation.spans(of: t).map(fr).joined(separator: ","), WordSegmentation.words(t).map(q).joined(separator: ",")])
            case 2:
                let ws = (0..<Int(g.range(0, 4))).map { _ in g.pick(wordTexts.filter { !$0.isEmpty }) }
                line(["words_join", ws.map(q).joined(separator: ","), "->", q(WordSegmentation.join(ws))])
            case 3:
                let (a, b) = g.pick(tightPairs)
                line(["tight", q(a), q(b), "->", WordSegmentation.isTight(a, b) ? "1" : "0"])
            default:
                let t = g.pick(searchTexts), f = g.pick(searchFinds); let cs = g.int(2) == 0, ds = g.int(2) == 0
                let m = TextSearch.matches(in: t, find: f, caseSensitive: cs, diacriticSensitive: ds)
                line(["search", q(t), q(f), cs ? "1" : "0", ds ? "1" : "0", "->", "\(m.count)", m.map { "\($0.location)+\($0.length)" }.joined(separator: ",")])
            }
        default: break
        }
    }
    // Fixed (non-random) tables appended so every word text and every search combination is covered at least once.
    emit(["# fixed tables"])
    for t in wordTexts { emit(["words", q(t), "->", "\(WordSegmentation.wordCount(t))", WordSegmentation.spans(of: t).map(fr).joined(separator: ","), WordSegmentation.words(t).map(q).joined(separator: ",")]) }
    for (a, b) in tightPairs { emit(["tight", q(a), q(b), "->", WordSegmentation.isTight(a, b) ? "1" : "0"]) }
    for t in searchTexts { for f in searchFinds { for cs in [false, true] { for ds in [false, true] {
        let m = TextSearch.matches(in: t, find: f, caseSensitive: cs, diacriticSensitive: ds)
        emit(["search", q(t), q(f), cs ? "1" : "0", ds ? "1" : "0", "->", "\(m.count)", m.map { "\($0.location)+\($0.length)" }.joined(separator: ",")])
    } } } }
    // Hand-picked edge cases of Time that must never go missing.
    emit(["# edge cases"])
    let edgeV: [Int64] = [ni, ni + 1, -1, 0, 1, pi - 1, pi]
    let edgeS: [Int64] = [1, 2, 3, 24000, 2147483648, Int64(1) << 62, pi]
    for v in edgeV { for s in edgeS { let t = Time(v, s); emit(["init", "\(v)", "\(s)", "->", ft(t), "\(t.value)", "\(t.timescale)", t.isNegative ? "1" : "0"]); emit(["neg", ft(t), "->", ft(-t)]) } }
    for v in edgeV { for s in [Int64(1), 3, pi] { let a = Time(v, s); for w in edgeV { for s2 in [Int64(1), 7, pi - 1] { let b = Time(w, s2)
        emit(["add", ft(a), ft(b), "->", ft(a + b)]); emit(["sub", ft(a), ft(b), "->", ft(a - b)]); emit(["cmp", ft(a), ft(b), "->", "\(a < b ? -1 : (a == b ? 0 : 1))", a < b ? "1" : "0", a <= b ? "1" : "0", a > b ? "1" : "0", a >= b ? "1" : "0", a == b ? "1" : "0"])
    } } } }
    let i128: [Int128] = [Int128.min + 1, Int128.max, -Int128(pi) * Int128(pi), Int128(pi) * Int128(pi), Int128(ni), Int128(pi) + 1, Int128(pi) * 3, 1, -1, 0, Int128(ni) * 2, Int128(1) << 100, -(Int128(1) << 100) + 12345]
    let i128d: [Int128] = [1, -1, 3, 7, Int128(pi), Int128(pi) - 1, Int128(pi) + 1, Int128(1) << 64, Int128(1001) * 24000, Int128(pi) * Int128(pi), -Int128(pi) * 5, Int128.max]
    for n in i128 { for d in i128d { let t = Time(reducing: n, d); emit(["reducing", "\(n)", "\(d)", "->", ft(t)]) } }
}

func runText() {
    let en = Locale(identifier: "en_US")
    emit(["# sq-core-time oracle: text-tables.tsv. Columns are TAB separated. `# ` lines are comments. Strings = quoted, scalars outside 0x20-0x7E, `\\` and `\"` as \\u{hex}."])
    emit(["# Recorded with Locale.current = \(Locale.current.identifier) (process started with -AppleLocale en_US -AppleLanguages (en))."])
    emit(["# LCG for the sampled pairs: see ops.tsv header. seed = 20261105, pool order as in swift-dump/main.swift."])
    emit(["# standard_compare <a> <b> -> A B  : A = `a.localizedStandardCompare(b)` (Finder-style, what Bin/MediaGrouping use), B = `a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive, .forcedOrdering], range: nil, locale: Locale(identifier: \"en_US\"))` (cross-check); values -1/0/1."])
    emit(["# ci_contains <haystack> <needle> -> A B : A = `haystack.localizedCaseInsensitiveContains(needle)`, B = `haystack.range(of: needle, options: [.caseInsensitive], range: nil, locale: Locale(identifier: \"en_US\")) != nil`; 0/1."])
    emit(["# graphemes <string> -> C S U16 U8 : C = `s.count` (Characters/extended grapheme clusters), S = `s.unicodeScalars.count`, U16 = `s.utf16.count`, U8 = `s.utf8.count`."])
    var g = LCG(20261105)
    let pool: [String] = [
        "file1", "file2", "file10", "File10", "file 10", "file01", "file001", "file1.txt", "file10.txt", "File2.TXT", "Äpfel", "Apfel", "apfel", "Zebra", "zebra", "résumé", "resume", "Resume", "résume",
        "10", "9", "2", "02", "002", "0", "00", "a", "B", "ä", "z", "ß", "ss", "Straße", "Strasse", "日本", "にほん", "ニホン", "IMG_0001.mov", "IMG_0010.mov", "IMG_1.mov", "IMG_01.mov",
        "clip 2 take 10", "clip 2 take 9", "clip 10 take 1", "Ünïcödé", "Unicode", "", " ", "  leading", "trailing ", "a-b", "a_b", "a b", "a.b", "1.5", "1.10", "1.9", "v1.2.3", "v1.10.0", "v1.9.9",
        "Track 1", "track 1", "Track 12", "emoji😀", "emoji", "emoji😀2", "e\u{301}", "é", "E", "e", "Ａ", "A", "ａ", "123abc", "abc123", "abc", "ABC", "Abc", "x2y10", "x2y9", "x10y1",
        "12345678901234567890", "12345678901234567891", "-5", "-10", "+5", "5", "(1)", "[1]", "_a", "~a", "#1", "ñ", "n", "o", "ö", "oe", "Ö", "O", "ǆ", "Ǆ", "ǅ", "ﬁ", "fi", "ı", "i", "I", "İ",
        "٣", "3", "三", "Ⅲ", "²", "2", "tab\there", "new\nline", "A_B", "a_b", "a-b-c", "comma,x", "dot.x", "Z", "z1", "z01", "Z001",
    ]
    for _ in 0..<300 {
        let a = g.pick(pool), b = g.int(8) == 0 ? a : g.pick(pool)
        let r1 = fcmp(a.localizedStandardCompare(b))
        let r2 = fcmp(a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive, .forcedOrdering], range: nil, locale: en))
        emit(["standard_compare", q(a), q(b), "->", "\(r1)", "\(r2)"])
    }
    let hay: [String] = ["Interview Café 01.mov", "IMG_0001.MOV", "O-Ton Teil 2", "resume résumé RESUME", "Straße der Pariser Kommune", "STRASSE", "日本語のクリップ", "ひらがな カタカナ", "Ünïcödé Test", "İstanbul", "ISTANBUL", "ǅ", "e\u{301}cole", "école", "ECOLE", "Ｆｕｌｌｗｉｄｔｈ", "fullwidth", "emoji 😀 clip", "👍🏽", "fi ligature ﬁ", "ﬁlm", "film", "", "a", "aaa", "x_y-z", "A B C", "tab\tx", "Zoë", "zoe", "Åland", "aland", "Ångström", "angstrom", "naïve", "NAIVE", "Œuvre", "oeuvre", "Ølen", "olen", "Łódź", "lodz"]
    let ndl: [String] = ["café", "CAFE", "cafe", "img", "mov", ".mov", "o-ton", "RESUME", "resume", "résumé", "strasse", "STRASSE", "straße", "ss", "ß", "日本", "カタカナ", "かたかな", "unicode", "ÜNÏ", "istanbul", "i̇", "İ", "ecole", "école", "e\u{301}", "ecole ", "fullwidth", "ＦＵＬＬ", "😀", "👍", "fi", "ﬁ", "", " ", "a", "aa", "aaaa", "_", "-", "zoe", "ZOË", "aland", "ANGSTROM", "naive", "oeuvre", "olen", "lodz", "łódź"]
    for _ in 0..<200 {
        let h = g.pick(hay), n = g.pick(ndl)
        let r1 = h.localizedCaseInsensitiveContains(n)
        let r2 = h.range(of: n, options: [.caseInsensitive], range: nil, locale: en) != nil
        emit(["ci_contains", q(h), q(n), "->", r1 ? "1" : "0", r2 ? "1" : "0"])
    }
    var gs: [String] = pool.prefix(40).map { $0 } + [
        "👨‍👩‍👧‍👦", "👍🏽", "🇩🇪", "🇩🇪🇯🇵", "🇩🇪🇯🇵🇫", "e\u{301}\u{302}", "a\u{200D}b", "\r\n", "\n\r", "\u{1100}\u{1161}\u{11A8}", "각", "ก็", "नि", "क्षि", "🏳️‍🌈", "❤️", "❤", "1️⃣", "\u{0}", "\u{7F}", "\u{200B}", "\u{FEFF}x", "ab\u{0308}c", "\u{1F468}\u{200D}\u{1F4BB}", "𝒳", "\u{20000}", "ä", "a\u{308}",
    ]
    let alphabet: [String] = ["a", "e", "Z", "1", " ", "\u{301}", "\u{308}", "\u{200D}", "\u{200B}", "😀", "👍", "\u{1F3FD}", "\u{1F1E9}", "\u{1F1EA}", "\u{1F1EF}", "日", "あ", "\u{3099}", "\u{1100}", "\u{1161}", "\u{11A8}", "\r", "\n", "\u{FE0F}", "é", "ß", "\u{0915}", "\u{094D}", "\u{0937}", "\u{0E01}", "\u{0E47}"]
    while gs.count < 140 { var s = ""; for _ in 0..<g.int(9) { s += g.pick(alphabet) }; gs.append(s) }
    for s in gs { emit(["graphemes", q(s), "->", "\(s.count)", "\(s.unicodeScalars.count)", "\(s.utf16.count)", "\(s.utf8.count)"]) }
}

let args = CommandLine.arguments.filter { !$0.hasPrefix("-Apple") && $0 != "(en)" }
switch args.count > 1 ? args[1] : "" {
case "ops":
    runOps(seed: UInt64(args.count > 2 ? args[2] : "20261105") ?? 20261105, count: Int(args.count > 3 ? args[3] : "10000") ?? 10000)
case "text":
    runText()
default:
    FileHandle.standardError.write(Data("usage: dump ops <seed> <count> | dump text\n".utf8)); exit(2)
}
FileHandle.standardOutput.write(Data(out.utf8))
