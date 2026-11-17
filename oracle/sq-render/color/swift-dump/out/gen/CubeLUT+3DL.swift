import Foundation
#if canImport(simd)
import simd
#endif

extension CubeLUT {
    /// Autodesk / Lustre `.3dl`: an optional first line with the input mesh points (N integers, N = cube size), then
    /// N^3 rows of three integers, the red index outermost and blue changing fastest. The output depth (10, 12 or 16 bit)
    /// is taken from the largest value; fractional files already in 0...1 stay as they are. Header lines that start with
    /// a word (`3DMESH`, `Mesh 4 12`, `LUT8`, ...) are skipped. The result is the same 3D table a `.cube` gives
    /// (red fastest, domain 0...1).
    public static func parse3DL(_ text: String) throws -> CubeLUT {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var meshSize: Int?
        var rows: [SIMD3<Float>] = []
        var fractional = false
        var nonInteger = false
        var firstIsMeshCandidate = false
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            if let first = parts.first, first.first.map({ $0.isLetter }) == true { continue }
            var values: [Float] = []
            for p in parts {
                guard let f = Float(p), f.isFinite else { throw CubeLUTError.badNumber(line: i + 1, token: String(p)) }
                if p.contains(".") { fractional = true }
                if f != f.rounded() { nonInteger = true }
                values.append(f)
            }
            if values.count == 3 {
                if rows.isEmpty, meshSize == nil {
                    // A size-3 cube's mesh line has three values too: ascending integers, decided once the rows are counted.
                    firstIsMeshCandidate = !line.contains(".") && values[0] < values[1] && values[1] < values[2]
                }
                rows.append(SIMD3(values[0], values[1], values[2]))
            } else if rows.isEmpty, meshSize == nil, values.count >= 2 {
                meshSize = values.count          // the input mesh line
            } else {
                throw CubeLUTError.malformedLine(line: i + 1)
            }
        }
        if meshSize == nil, firstIsMeshCandidate, rows.count == 28 {
            rows.removeFirst()
            meshSize = 3
        }
        let size = meshSize ?? Int(pow(Double(rows.count), 1.0 / 3.0).rounded())
        guard size >= 2, size <= 256 else { throw CubeLUTError.sizeOutOfRange(line: 0, size: size) }
        let expected = size * size * size
        guard rows.count == expected else { throw CubeLUTError.wrongEntryCount(expected: expected, found: rows.count) }
        let peak = rows.reduce(Float(0)) { max($0, $1.max()) }
        let depth: Float = nonInteger || (fractional && peak <= 1.0) ? 1 : peak <= 1023 ? 1023 : peak <= 4095 ? 4095 : 65535
        var table = [SIMD3<Float>](repeating: .zero, count: expected)
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    table[r + size * (g + size * b)] = rows[(r * size + g) * size + b] / depth
                }
            }
        }
        return CubeLUT(kind: .lut3D, size: size, table: table)
    }
}
