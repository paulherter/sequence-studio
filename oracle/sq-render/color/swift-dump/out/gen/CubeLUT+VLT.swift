import Foundation
#if canImport(simd)
import simd
#endif

extension CubeLUT {
    /// Panasonic VariCam `.vlt`: comment lines (the first reads `# panasonic vlt file version 1`), a `LUT_3D_SIZE N`
    /// line, then N^3 rows `R G B` with integers 0...4095, red changing fastest. Same table as a `.cube` (domain 0...1).
    /// The layout is taken from a summary of the public manual, not from the PDF: the 4095 scale and the red-fastest
    /// order are the points to re-check against a real camera file if a look comes out wrong.
    public static func parseVLT(_ text: String) throws -> CubeLUT {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var size: Int?
        var rows: [SIMD3<Float>] = []
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts[0] == "LUT_3D_SIZE" {
                guard parts.count == 2, let s = Int(parts[1]) else { throw CubeLUTError.malformedLine(line: i + 1) }
                guard (2...256).contains(s) else { throw CubeLUTError.sizeOutOfRange(line: i + 1, size: s) }
                size = s
                continue
            }
            guard parts.count == 3 else { throw CubeLUTError.malformedLine(line: i + 1) }
            var v = SIMD3<Float>.zero
            for k in 0..<3 {
                guard let f = Float(parts[k]), f.isFinite else {
                    throw CubeLUTError.badNumber(line: i + 1, token: String(parts[k]))
                }
                v[k] = f / 4095
            }
            rows.append(v)
        }
        guard let size else { throw CubeLUTError.missingSize }
        guard rows.count == size * size * size else {
            throw CubeLUTError.wrongEntryCount(expected: size * size * size, found: rows.count)
        }
        return CubeLUT(kind: .lut3D, size: size, table: rows)
    }
}
