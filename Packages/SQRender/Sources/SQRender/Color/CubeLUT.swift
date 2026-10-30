import Foundation
#if canImport(simd)
import simd
#endif

public enum CubeLUTError: Error, Equatable, Sendable {
    case missingSize
    case sizeOutOfRange(line: Int, size: Int)
    case wrongEntryCount(expected: Int, found: Int)
    case badNumber(line: Int, token: String)
    case malformedLine(line: Int)
    case unknownKeyword(line: Int, keyword: String)
    case conflictingSizes(line: Int)
    case invalidDomain(line: Int)
}

/// Adobe `.cube` LUT, 1D or 3D. Red varies fastest in `table`.
public struct CubeLUT: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case lut1D, lut3D }

    public let title: String
    public let kind: Kind
    public let size: Int
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    public let table: [SIMD3<Float>]
    /// `LUT_IN_VIDEO_RANGE` / `LUT_OUT_VIDEO_RANGE` header flags (applied in `lookup`).
    public let inVideoRange: Bool
    public let outVideoRange: Bool
    /// How a 3D table is read between its points. Tetrahedral is the default (less banding); trilinear is the option
    /// for matching other tools. 1D tables are always linear. Not part of the file: the user picks it.
    public var interpolation: Interpolation = .tetrahedral

    public enum Interpolation: String, Sendable, Equatable, Codable, CaseIterable { case tetrahedral, trilinear }

    /// A copy read with the given interpolation.
    public func with(interpolation: Interpolation) -> CubeLUT {
        var c = self
        c.interpolation = interpolation
        return c
    }

    public init(title: String = "", kind: Kind, size: Int, domainMin: SIMD3<Float> = .zero,
                domainMax: SIMD3<Float> = .one, table: [SIMD3<Float>],
                inVideoRange: Bool = false, outVideoRange: Bool = false) {
        // Programr error, not user data (`parse` reports typed errors for files): lookups index `table` unchecked.
        precondition(size >= 2, "CubeLUT size must be >= 2")
        precondition(table.count == (kind == .lut3D ? size * size * size : size),
                     "CubeLUT table has \(table.count) entries, expected \(kind == .lut3D ? size * size * size : size)")
        self.inVideoRange = inVideoRange; self.outVideoRange = outVideoRange
        self.title = title; self.kind = kind; self.size = size
        self.domainMin = domainMin; self.domainMax = domainMax; self.table = table
    }

    // MARK: Parser

    /// `.cube` text; text without a `LUT_1D_SIZE` / `LUT_3D_SIZE` keyword is tried as Autodesk `.3dl` first.
    public static func parse(_ text: String) throws -> CubeLUT {
        if text.prefix(200).lowercased().contains("panasonic vlt"), let l = try? parseVLT(text) { return l }
        if !text.contains("LUT_3D_SIZE") && !text.contains("LUT_1D_SIZE"), let l = try? parse3DL(text) { return l }
        var title = ""
        var size1D: Int?, size3D: Int?
        var dmin = SIMD3<Float>.zero, dmax = SIMD3<Float>.one
        var table: [SIMD3<Float>] = []
        var inVideo = false, outVideo = false
        var domainLine = 0

        func number(_ t: Substring, _ line: Int) throws -> Float {
            guard let f = Float(t), f.isFinite else { throw CubeLUTError.badNumber(line: line, token: String(t)) }
            return f
        }
        func triple(_ parts: [Substring], _ line: Int) throws -> SIMD3<Float> {
            guard parts.count == 3 else { throw CubeLUTError.malformedLine(line: line) }
            return SIMD3(try number(parts[0], line), try number(parts[1], line), try number(parts[2], line))
        }

        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (i, raw) in lines.enumerated() {
            let n = i + 1
            let line = Self.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let key = String(parts[0])
            switch key {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if title.count >= 2, title.hasPrefix("\""), title.hasSuffix("\"") { title = String(title.dropFirst().dropLast()) }
            case "LUT_3D_SIZE", "LUT_1D_SIZE":
                guard parts.count == 2 else { throw CubeLUTError.malformedLine(line: n) }
                guard let s = Int(parts[1]) else { throw CubeLUTError.badNumber(line: n, token: String(parts[1])) }
                let is3D = key == "LUT_3D_SIZE"
                if (is3D && size1D != nil) || (!is3D && size3D != nil) || (is3D ? size3D : size1D) != nil {
                    throw CubeLUTError.conflictingSizes(line: n)
                }
                guard is3D ? (2...256).contains(s) : (2...65536).contains(s) else {
                    throw CubeLUTError.sizeOutOfRange(line: n, size: s)
                }
                if is3D { size3D = s } else { size1D = s }
            case "DOMAIN_MIN":
                dmin = try triple(Array(parts.dropFirst()), n)
                domainLine = n
            case "DOMAIN_MAX":
                dmax = try triple(Array(parts.dropFirst()), n)
                domainLine = n
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                guard parts.count == 3 else { throw CubeLUTError.malformedLine(line: n) }
                let lo = try number(parts[1], n), hi = try number(parts[2], n)
                dmin = SIMD3(repeating: lo); dmax = SIMD3(repeating: hi)
                domainLine = n
            case "LUT_IN_VIDEO_RANGE": inVideo = true
            case "LUT_OUT_VIDEO_RANGE": outVideo = true
            default:
                let isKeyword = key.first.map { $0.isUppercase } == true
                    && key.allSatisfy { ($0.isASCII && $0.isUppercase) || $0 == "_" || $0.isNumber }
                if !isKeyword {
                    table.append(try triple(parts, n))
                } else {
                    throw CubeLUTError.unknownKeyword(line: n, keyword: key)
                }
            }
        }
        if !(dmax.x > dmin.x && dmax.y > dmin.y && dmax.z > dmin.z) { throw CubeLUTError.invalidDomain(line: domainLine) }
        let kind: Kind, size: Int
        if let s = size3D { kind = .lut3D; size = s } else if let s = size1D { kind = .lut1D; size = s } else {
            throw CubeLUTError.missingSize
        }
        let expected = kind == .lut3D ? size * size * size : size
        guard table.count == expected else { throw CubeLUTError.wrongEntryCount(expected: expected, found: table.count) }
        return CubeLUT(title: title, kind: kind, size: size, domainMin: dmin, domainMax: dmax, table: table,
                       inVideoRange: inVideo, outVideoRange: outVideo)
    }

    /// Removes `#…` to the end of the line; a `#` inside a double-quoted string (TITLE) is kept.
    static func stripComment(_ line: Substring) -> Substring {
        var inQuote = false
        for i in line.indices {
            let ch = line[i]
            if ch == "\"" { inQuote.toggle() } else if ch == "#" && !inQuote { return line[..<i] }
        }
        return line
    }

    // MARK: Lookup

    /// Input clamped to the domain; 3D tetrahedral, 1D linear per channel.
    /// `LUT_IN_VIDEO_RANGE` / `LUT_OUT_VIDEO_RANGE` use the 10-bit convention (black 64, white 940, of 1023):
    /// in: `x = x·876/1023 + 64/1023` before the domain mapping; out: `y = (y − 64/1023)·1023/876`.
    public func lookup(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var x = rgb
        if inVideoRange { x = x * 876 / 1023 + SIMD3<Float>(repeating: 64 / 1023) }
        let t = simd_clamp((x - domainMin) / (domainMax - domainMin), SIMD3<Float>.zero, SIMD3<Float>.one)
        let scale = Float(size - 1)
        var out: SIMD3<Float>
        if kind == .lut1D { out = linear1D(t * scale) } else if interpolation == .trilinear {
            out = trilinear(t * scale)
        } else { out = tetrahedral(t * scale) }
        if outVideoRange { out = (out - SIMD3<Float>(repeating: 64 / 1023)) * 1023 / 876 }
        return out
    }

    @inline(__always) private func linear1D(_ p: SIMD3<Float>) -> SIMD3<Float> {
        var out = SIMD3<Float>.zero
        for ch in 0..<3 {
            let i0 = min(Int(p[ch]), size - 2)
            let f = p[ch] - Float(i0)
            out[ch] = table[i0][ch] + (table[i0 + 1][ch] - table[i0][ch]) * f
        }
        return out
    }

    @inline(__always) private func trilinear(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let n = size
        let ir = min(Int(p.x), n - 2), ig = min(Int(p.y), n - 2), ib = min(Int(p.z), n - 2)
        let fr = p.x - Float(ir), fg = p.y - Float(ig), fb = p.z - Float(ib)
        let base = ir + n * (ig + n * ib)
        @inline(__always) func c(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { table[base + r + g * n + b * n * n] }
        let x00 = c(0, 0, 0) + (c(1, 0, 0) - c(0, 0, 0)) * fr
        let x10 = c(0, 1, 0) + (c(1, 1, 0) - c(0, 1, 0)) * fr
        let x01 = c(0, 0, 1) + (c(1, 0, 1) - c(0, 0, 1)) * fr
        let x11 = c(0, 1, 1) + (c(1, 1, 1) - c(0, 1, 1)) * fr
        let y0 = x00 + (x10 - x00) * fg, y1 = x01 + (x11 - x01) * fg
        return y0 + (y1 - y0) * fb
    }

    @inline(__always) private func tetrahedral(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let n = size
        let ir = min(Int(p.x), n - 2), ig = min(Int(p.y), n - 2), ib = min(Int(p.z), n - 2)
        let fr = p.x - Float(ir), fg = p.y - Float(ig), fb = p.z - Float(ib)
        let base = ir + n * (ig + n * ib)
        let dg = n, db = n * n
        @inline(__always) func c(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { table[base + r + g * dg + b * db] }
        let c000 = c(0, 0, 0), c111 = c(1, 1, 1)
        if fr >= fg {
            if fg >= fb {
                return c000 + fr * (c(1, 0, 0) - c000) + fg * (c(1, 1, 0) - c(1, 0, 0)) + fb * (c111 - c(1, 1, 0))
            } else if fr >= fb {
                return c000 + fr * (c(1, 0, 0) - c000) + fb * (c(1, 0, 1) - c(1, 0, 0)) + fg * (c111 - c(1, 0, 1))
            } else {
                return c000 + fb * (c(0, 0, 1) - c000) + fr * (c(1, 0, 1) - c(0, 0, 1)) + fg * (c111 - c(1, 0, 1))
            }
        } else {
            if fb >= fg {
                return c000 + fb * (c(0, 0, 1) - c000) + fg * (c(0, 1, 1) - c(0, 0, 1)) + fr * (c111 - c(0, 1, 1))
            } else if fb >= fr {
                return c000 + fg * (c(0, 1, 0) - c000) + fb * (c(0, 1, 1) - c(0, 1, 0)) + fr * (c111 - c(0, 1, 1))
            } else {
                return c000 + fg * (c(0, 1, 0) - c000) + fr * (c(1, 1, 0) - c(0, 1, 0)) + fb * (c111 - c(1, 1, 0))
            }
        }
    }
}
