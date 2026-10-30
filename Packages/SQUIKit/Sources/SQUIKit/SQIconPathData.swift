import Foundation

/// Where SVG path data goes: a `CGMutablePath` on the Mac (SQIcon+Render.swift), the canvas outline of the shared toolkit
/// elsewhere (SQDrawKit `IconOutline`). Curves stay curves here; the sink flattens them if it must.
public protocol SQIconPathSink: AnyObject {
    func sinkMove(_ p: CGPoint)
    func sinkLine(_ p: CGPoint)
    func sinkCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint)
    func sinkQuad(to p: CGPoint, control: CGPoint)
    func sinkClose()
}

/// SVG path data (all commands, relative and absolute, arcs converted to cubic curves).
public enum SQIconPathData {
    public static func numbers(_ s: String) -> [CGFloat] {
        var scanner = Scanner(chars: Array(s.utf8))
        var out: [CGFloat] = []
        while let v = scanner.number() { out.append(v) }
        return out
    }

    struct Scanner {
        let chars: [UInt8]
        var i = 0
        init(chars: [UInt8]) { self.chars = chars }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 9 || chars[i] == 13 { i += 1 }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = i
            var seenDot = false, seenDigit = false
            if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { seenDigit = true; i += 1 }
                else if c == 46 && !seenDot { seenDot = true; i += 1 }
                else if (c == 101 || c == 69) && seenDigit {
                    i += 1
                    if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
                } else { break }
            }
            guard seenDigit, let s = String(bytes: chars[start..<i], encoding: .utf8), let v = Double(s) else { i = start; return nil }
            return CGFloat(v)
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else { return nil }
            defer { i += 1 }
            return chars[i] == 49
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { i += 1; return c }
            return nil
        }

        var atEnd: Bool { mutating get { skipSeparators(); return i >= chars.count } }
    }

    public static func append<P: SQIconPathSink>(_ d: String, to path: P) {
        var sc = Scanner(chars: Array(d.utf8))
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0
        while !sc.atEnd {
            if let c = sc.command() { cmd = c }
            else if cmd == 0 { return }
            else if cmd == 77 { cmd = 76 } else if cmd == 109 { cmd = 108 }
            let rel = cmd >= 97
            let upper = rel ? cmd - 32 : cmd
            let ox = rel ? cur.x : 0, oy = rel ? cur.y : 0
            var newCubic: CGPoint?, newQuad: CGPoint?
            switch upper {
            case 77: // M
                guard let x = sc.number(), let y = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: oy + y); start = cur
                path.sinkMove(cur)
            case 76: // L
                guard let x = sc.number(), let y = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: oy + y); path.sinkLine(cur)
            case 72: // H
                guard let x = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: cur.y); path.sinkLine(cur)
            case 86: // V
                guard let y = sc.number() else { return }
                cur = CGPoint(x: cur.x, y: oy + y); path.sinkLine(cur)
            case 67: // C
                guard let x1 = sc.number(), let y1 = sc.number(), let x2 = sc.number(), let y2 = sc.number(),
                      let x = sc.number(), let y = sc.number() else { return }
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                path.sinkCurve(to: CGPoint(x: ox + x, y: oy + y), control1: CGPoint(x: ox + x1, y: oy + y1), control2: c2)
                cur = CGPoint(x: ox + x, y: oy + y); newCubic = c2
            case 83: // S
                guard let x2 = sc.number(), let y2 = sc.number(), let x = sc.number(), let y = sc.number() else { return }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                path.sinkCurve(to: CGPoint(x: ox + x, y: oy + y), control1: c1, control2: c2)
                cur = CGPoint(x: ox + x, y: oy + y); newCubic = c2
            case 81: // Q
                guard let x1 = sc.number(), let y1 = sc.number(), let x = sc.number(), let y = sc.number() else { return }
                let q = CGPoint(x: ox + x1, y: oy + y1)
                path.sinkQuad(to: CGPoint(x: ox + x, y: oy + y), control: q)
                cur = CGPoint(x: ox + x, y: oy + y); newQuad = q
            case 84: // T
                guard let x = sc.number(), let y = sc.number() else { return }
                let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.sinkQuad(to: CGPoint(x: ox + x, y: oy + y), control: q)
                cur = CGPoint(x: ox + x, y: oy + y); newQuad = q
            case 65: // A
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(), let large = sc.flag(), let sweep = sc.flag(),
                      let x = sc.number(), let y = sc.number() else { return }
                let end = CGPoint(x: ox + x, y: oy + y)
                addArc(path, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = end
            case 90: // Z
                path.sinkClose(); cur = start
            default:
                return
            }
            lastCubic = newCubic; lastQuad = newQuad
        }
    }

    // SVG implementation notes F.6.5: endpoint to center parameterization, then cubic segments of at most 90 degrees.
    static func addArc<P: SQIconPathSink>(_ path: P, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { path.sinkLine(p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var a = theta1
        for _ in 0..<segments {
            let b = a + step
            let cosA = cos(a), sinA = sin(a), cosB = cos(b), sinB = sin(b)
            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(x: cx + cosP * rx * ex - sinP * ry * ey, y: cy + sinP * rx * ex + cosP * ry * ey)
            }
            path.sinkCurve(to: map(cosB, sinB),
                          control1: map(cosA - t * sinA, sinA + t * cosA),
                          control2: map(cosB + t * sinB, sinB - t * cosB))
            a = b
        }
    }
}

extension SQIcon {
    /// The icon's SVG text from Resources/Icons (the shared toolkit draws it through `SQIconSVG`; the Mac renders it in
    /// SQIcon+Render.swift).
    public var svgSource: String? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "svg", subdirectory: "Icons") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The SVG elements of an icon file into a path sink, without XMLParser (FoundationXML is a separate module off the Mac).
/// Same element set and meaning as the Mac parser in SQIcon+Render.swift: path, circle, ellipse, rect (rx/ry), line,
/// polyline, polygon. Returns, per element, whether it is filled and/or stroked.
public enum SQIconSVG {
    public struct Shape: Sendable, Equatable { public var fill: Bool; public var stroke: Bool }

    /// Elements in document order: name and attributes. Only self-contained tags matter for the icon files.
    public static func elements(_ svg: String) -> [(name: String, attributes: [String: String])] {
        var out: [(String, [String: String])] = []
        var rest = Substring(svg)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            guard let first = tag.first, first.isLetter else { continue }
            let name = String(tag.prefix { $0.isLetter || $0 == "-" })
            var attrs: [String: String] = [:]
            var s = tag.dropFirst(name.count)
            while let eq = s.firstIndex(of: "=") {
                let key = s[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
                s = s[s.index(after: eq)...].drop { $0 == " " }
                guard let q = s.first, q == "\"" || q == "'" else { break }
                s = s.dropFirst()
                guard let end = s.firstIndex(of: q) else { break }
                attrs[key] = String(s[..<end])
                s = s[s.index(after: end)...]
            }
            out.append((name, attrs))
        }
        return out
    }

    /// Feeds every drawable element of `svg` into a fresh sink from `make` and reports it with its paint flags.
    public static func shapes<P: SQIconPathSink>(_ svg: String, make: () -> P) -> [(P, Shape)] {
        var out: [(P, Shape)] = []
        for (name, a) in elements(svg) {
            func num(_ k: String) -> CGFloat { CGFloat(Double(a[k] ?? "") ?? 0) }
            let p = make()
            switch name {
            case "path": SQIconPathData.append(a["d"] ?? "", to: p)
            case "circle": ellipse(p, cx: num("cx"), cy: num("cy"), rx: num("r"), ry: num("r"))
            case "ellipse": ellipse(p, cx: num("cx"), cy: num("cy"), rx: num("rx"), ry: num("ry"))
            case "rect":
                var rx = a["rx"].flatMap { Double($0) }.map { CGFloat($0) }
                var ry = a["ry"].flatMap { Double($0) }.map { CGFloat($0) }
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                rect(p, CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height")), rx: rx ?? 0, ry: ry ?? 0)
            case "line":
                p.sinkMove(CGPoint(x: num("x1"), y: num("y1"))); p.sinkLine(CGPoint(x: num("x2"), y: num("y2")))
            case "polyline", "polygon":
                let v = SQIconPathData.numbers(a["points"] ?? "")
                var i = 0
                while i + 1 < v.count {
                    let q = CGPoint(x: v[i], y: v[i + 1])
                    if i == 0 { p.sinkMove(q) } else { p.sinkLine(q) }
                    i += 2
                }
                if name == "polygon" { p.sinkClose() }
            default: continue
            }
            out.append((p, Shape(fill: (a["fill"] ?? "none") != "none", stroke: (a["stroke"] ?? "currentColor") != "none")))
        }
        return out
    }

    /// Four quarter arcs as cubics (what `CGPath.addEllipse` emits).
    static func ellipse<P: SQIconPathSink>(_ p: P, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
        let k: CGFloat = 0.5522847498
        p.sinkMove(CGPoint(x: cx + rx, y: cy))
        p.sinkCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + k * ry), control2: CGPoint(x: cx + k * rx, y: cy + ry))
        p.sinkCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - k * rx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + k * ry))
        p.sinkCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - k * ry), control2: CGPoint(x: cx - k * rx, y: cy - ry))
        p.sinkCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + k * rx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - k * ry))
        p.sinkClose()
    }

    /// A rect with corner radii clamped to half the sides (what `CGPath.addRoundedRect` draws).
    static func rect<P: SQIconPathSink>(_ p: P, _ r: CGRect, rx rxIn: CGFloat, ry ryIn: CGFloat) {
        let rx = min(rxIn, r.width / 2), ry = min(ryIn, r.height / 2)
        guard rx > 0, ry > 0 else {
            p.sinkMove(CGPoint(x: r.minX, y: r.minY)); p.sinkLine(CGPoint(x: r.maxX, y: r.minY))
            p.sinkLine(CGPoint(x: r.maxX, y: r.maxY)); p.sinkLine(CGPoint(x: r.minX, y: r.maxY)); p.sinkClose()
            return
        }
        let k: CGFloat = 0.5522847498
        p.sinkMove(CGPoint(x: r.minX + rx, y: r.minY))
        p.sinkLine(CGPoint(x: r.maxX - rx, y: r.minY))
        p.sinkCurve(to: CGPoint(x: r.maxX, y: r.minY + ry), control1: CGPoint(x: r.maxX - rx + k * rx, y: r.minY),
                    control2: CGPoint(x: r.maxX, y: r.minY + ry - k * ry))
        p.sinkLine(CGPoint(x: r.maxX, y: r.maxY - ry))
        p.sinkCurve(to: CGPoint(x: r.maxX - rx, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - ry + k * ry),
                    control2: CGPoint(x: r.maxX - rx + k * rx, y: r.maxY))
        p.sinkLine(CGPoint(x: r.minX + rx, y: r.maxY))
        p.sinkCurve(to: CGPoint(x: r.minX, y: r.maxY - ry), control1: CGPoint(x: r.minX + rx - k * rx, y: r.maxY),
                    control2: CGPoint(x: r.minX, y: r.maxY - ry + k * ry))
        p.sinkLine(CGPoint(x: r.minX, y: r.minY + ry))
        p.sinkCurve(to: CGPoint(x: r.minX + rx, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + ry - k * ry),
                    control2: CGPoint(x: r.minX + rx - k * rx, y: r.minY))
        p.sinkClose()
    }
}
