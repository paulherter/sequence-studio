import Testing
#if canImport(simd)
import simd
#endif
@testable import SQRender

/// Autodesk `.3dl` Step LUTs (red index outermost, blue fastest; 10 / 12 bit integers).
@Suite struct CubeLUT3DLTests {
    /// A 2-point cube whose output marks each corner: value = (r, g, b) * 1023.
    static let tiny = """
    0 1023
    0 0 0
    0 0 1023
    0 1023 0
    0 1023 1023
    1023 0 0
    1023 0 1023
    1023 1023 0
    1023 1023 1023
    """

    @Test func parsesMeshLineAndReordersToRedFastest() throws {
        let lut = try CubeLUT.parse(Self.tiny)   // no LUT_3D_SIZE: detected as 3dl
        #expect(lut.kind == .lut3D && lut.size == 2 && lut.table.count == 8)
        // Identity: the table of a .cube identity has red fastest.
        for r in 0..<2 { for g in 0..<2 { for b in 0..<2 {
            #expect(lut.table[r + 2 * (g + 2 * b)] == SIMD3(Float(r), Float(g), Float(b)))
        } } }
        #expect(lut.lookup(SIMD3(1, 0, 0)) == SIMD3(1, 0, 0))
    }

    @Test func detectsTwelveBitAndMissingMeshLine() throws {
        var t = ""
        for r in 0..<2 { for g in 0..<2 { for b in 0..<2 { t += "\(r * 4095) \(g * 4095) \(b * 4095)\n" } } }
        let lut = try CubeLUT.parse3DL("# 12 bit, no mesh line\n" + t)
        #expect(lut.size == 2)
        #expect(lut.table[1] == SIMD3(1, 0, 0))     // r = 1 is the fastest index
    }

    @Test func rejectsWrongCountAndKeepsTheCubeErrors() {
        #expect(throws: CubeLUTError.self) { try CubeLUT.parse3DL("0 1023\n0 0 0\n1023 1023 1023\n") }
        #expect(throws: CubeLUTError.missingSize) { try CubeLUT.parse("0 0 0\n") }
    }

    @Test func fractionalValuesAboveOneStayFloat() throws {
        var t = ""
        for r in 0..<2 { for g in 0..<2 { for b in 0..<2 { t += "\(Float(r) * 1.02) \(Float(g) * 0.5) \(Float(b))\n" } } }
        let lut = try CubeLUT.parse3DL(t)
        #expect(abs(lut.table[1].x - 1.02) < 1e-5)
    }

    @Test func sizeThreeCubeWithMeshLine() throws {
        var t = "0 511 1022\n"
        for r in 0..<3 { for g in 0..<3 { for b in 0..<3 { t += "\(r * 511) \(g * 511) \(b * 511)\n" } } }
        let lut = try CubeLUT.parse3DL(t)
        #expect(lut.size == 3 && lut.table.count == 27)
        #expect(abs(lut.table[1].x - 511.0 / 1023) < 1e-5)   // r = 1 fastest
        let noMesh = try CubeLUT.parse3DL(String(t.dropFirst("0 511 1022\n".count)))
        #expect(noMesh.size == 3 && noMesh.table == lut.table)
    }
}
