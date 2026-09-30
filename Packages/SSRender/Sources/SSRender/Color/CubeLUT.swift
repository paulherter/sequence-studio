import Foundation
import simd

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
    /// `LUT_IN_VIDEO_RANGE` / `LUT_OUT_VIDEO_RANGE` header flags (stored, not yet honoured).
    public let inVideoRange: Bool
    public let outVideoRange: Bool

    public init(title: String = "", kind: Kind, size: Int, domainMin: SIMD3<Float> = .zero,
                domainMax: SIMD3<Float> = .one, table: [SIMD3<Float>],
                inVideoRange: Bool = false, outVideoRange: Bool = false) {
        self.inVideoRange = inVideoRange; self.outVideoRange = outVideoRange
        self.title = title; self.kind = kind; self.size = size
        self.domainMin = domainMin; self.domainMax = domainMax; self.table = table
    }

    // MARK: Parser

    public static func parse(_ text: String) throws -> CubeLUT {
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
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
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

    // MARK: Lookup

    /// Input clamped to the domain; 3D tetrahedral, 1D linear per channel.
    public func lookup(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let t = simd_clamp((rgb - domainMin) / (domainMax - domainMin), SIMD3<Float>.zero, SIMD3<Float>.one)
        let scale = Float(size - 1)
        return kind == .lut3D ? tetrahedral(t * scale) : linear1D(t * scale)
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
