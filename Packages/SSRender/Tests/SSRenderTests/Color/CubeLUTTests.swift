import Testing
import simd
@testable import SSRender

struct LCG {
    var s: UInt64
    mutating func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float(s >> 40) / Float(1 << 24)
    }
    mutating func rgb() -> SIMD3<Float> { SIMD3(next(), next(), next()) }
}

func identityCube3D(_ n: Int, extra: String = "") -> String {
    var s = "TITLE \"id\"\n\(extra)LUT_3D_SIZE \(n)\n"
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        let d = Float(n - 1)
        s += "\(Float(r) / d) \(Float(g) / d) \(Float(b) / d)\n"
    } } }
    return s
}

@Suite struct CubeLUTTests {
    @Test(arguments: [2, 17, 33]) func identity3D(n: Int) throws {
        let lut = try CubeLUT.parse(identityCube3D(n))
        var rng = LCG(s: UInt64(n))
        for _ in 0..<500 {
            let p = rng.rgb()
            #expect(simd_length(lut.lookup(p) - p) < 1e-5)
        }
    }

    @Test func identity1D() throws {
        let text = "LUT_1D_SIZE 5\n0 0 0\n0.25 0.25 0.25\n0.5 0.5 0.5\n0.75 0.75 0.75\n1 1 1\n"
        let lut = try CubeLUT.parse(text)
        var rng = LCG(s: 7)
        for _ in 0..<200 {
            let p = rng.rgb()
            #expect(simd_length(lut.lookup(p) - p) < 1e-6)
        }
    }

    @Test func oneDimensionalLinearPerChannel() throws {
        let lut = try CubeLUT.parse("LUT_1D_SIZE 3\n0 0 1\n1 0.5 0\n0 1 1\n")
        let o = lut.lookup(SIMD3(0.25, 0.5, 0.75))
        #expect(abs(o.x - 0.5) < 1e-6 && abs(o.y - 0.5) < 1e-6 && abs(o.z - 0.5) < 1e-6)
    }

    @Test func handComputedTetrahedral() throws {
        // N = 2, lattice value = (r*g, g*b, b*r). Point (0.5, 0.25, 0.75): b >= r >= g ->
        // c000 + b(c001-c000) + r(c101-c001) + g(c111-c101) = (0.25, 0.25, 0.5)
        var text = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r * g) \(g * b) \(b * r)\n" } } }
        let lut = try CubeLUT.parse(text)
        let o = lut.lookup(SIMD3(0.5, 0.25, 0.75))
        #expect(simd_length(o - SIMD3(0.25, 0.25, 0.5)) < 1e-6)
    }

    @Test func exactAtLatticePoints() throws {
        var rng = LCG(s: 99)
        let n = 4
        var text = "LUT_3D_SIZE \(n)\n"
        var table: [SIMD3<Float>] = []
        for _ in 0..<(n * n * n) { let v = rng.rgb(); table.append(v); text += "\(v.x) \(v.y) \(v.z)\n" }
        let lut = try CubeLUT.parse(text)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let p = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
            #expect(simd_length(lut.lookup(p) - table[r + n * g + n * n * b]) < 1e-6)
        } } }
    }

    @Test func domainClampAndScaling() throws {
        let lut = try CubeLUT.parse(identityCube3D(2, extra: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"))
        // identity table over domain 0..2: input 1.0 -> normalized 0.5 -> output 0.5
        #expect(simd_length(lut.lookup(SIMD3(1, 1, 1)) - SIMD3(0.5, 0.5, 0.5)) < 1e-6)
        #expect(simd_length(lut.lookup(SIMD3(5, -3, 2)) - SIMD3(1, 0, 1)) < 1e-6)
    }

    @Test func commentsTitleBlankLinesCRLF() throws {
        let text = "# hi\r\n\r\nTITLE \"My LUT\"\r\n  # indented comment\r\nLUT_3D_SIZE 2\r\n" +
            (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)\r\n" }.joined()
        let lut = try CubeLUT.parse(text)
        #expect(lut.title == "My LUT")
        #expect(lut.size == 2)
        #expect(lut.kind == .lut3D)
    }

    @Test func errors() {
        func err(_ t: String) -> CubeLUTError? {
            do { _ = try CubeLUT.parse(t); return nil } catch let e as CubeLUTError { return e } catch { return nil }
        }
        #expect(err("0 0 0\n") == .missingSize)
        #expect(err("LUT_3D_SIZE 1\n") == .sizeOutOfRange(line: 1, size: 1))
        #expect(err("\nLUT_3D_SIZE 257\n") == .sizeOutOfRange(line: 2, size: 257))
        #expect(err("LUT_3D_SIZE 2\n0 0 0\n") == .wrongEntryCount(expected: 8, found: 1))
        #expect(err("LUT_1D_SIZE 2\n0 0 0\nx 1 1\n") == .badNumber(line: 3, token: "x"))
        #expect(err("LUT_1D_SIZE 2\n0 0\n1 1 1\n") == .malformedLine(line: 2))
        #expect(err("LUT_1D_SIZE 2\nFOO 1\n") == .unknownKeyword(line: 2, keyword: "FOO"))
        #expect(err("LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n") == .conflictingSizes(line: 2))
        #expect(err("LUT_3D_SIZE abc\n") == .badNumber(line: 1, token: "abc"))
        #expect(err("LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n") == .invalidDomain(line: 3))
        #expect(err("LUT_3D_SIZE 2\nDOMAIN_MAX 0 0 0\nDOMAIN_MIN 1 1 1\n") == .invalidDomain(line: 3))
    }

    @Test func domainMaxBeforeMin() throws {
        let lut = try CubeLUT.parse("DOMAIN_MAX 0.4 0.4 0.4\nDOMAIN_MIN -1 -1 -1\n" + identityCube3D(2))
        #expect(lut.domainMin == SIMD3(repeating: -1) && lut.domainMax == SIMD3(repeating: 0.4))
    }

    @Test func trailingCommentsAreStripped() throws {
        let text = "TITLE \"a # b\" # trailing\nLUT_3D_SIZE 2 # c\n" + identityCube3D(2).split(separator: "\n").dropFirst(2)
            .enumerated().map { $0.offset == 0 ? "\($0.element) # note" : String($0.element) }.joined(separator: "\n")
        let lut = try CubeLUT.parse(text)
        #expect(lut.size == 2 && lut.table.count == 8 && lut.title == "a # b")
        let l1 = try CubeLUT.parse("LUT_1D_SIZE 2\n0.1 0.2 0.3 # note\n1 1 1#x\n")
        #expect(l1.table[0] == SIMD3(0.1, 0.2, 0.3) && l1.table[1] == SIMD3(1, 1, 1))
    }

    @Test func videoRangeIsApplied() throws {
        let id = identityCube3D(17).split(separator: "\n", omittingEmptySubsequences: false)
        func make(_ flags: String) throws -> CubeLUT {
            try CubeLUT.parse(flags + id.joined(separator: "\n"))
        }
        let both = try make("LUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n")
        for p in [SIMD3<Float>(0, 0, 0), [1, 1, 1], [0.3, 0.6, 0.9], [0.5, 0.25, 0.75]] {
            #expect(simd_length(both.lookup(p) - p) < 1e-5)
        }
        let inOnly = try make("LUT_IN_VIDEO_RANGE\n")
        #expect(simd_length(inOnly.lookup(SIMD3<Float>.zero) - SIMD3(repeating: 64.0 / 1023)) < 1e-6)
        #expect(simd_length(inOnly.lookup(SIMD3<Float>.one) - SIMD3(repeating: 940.0 / 1023)) < 1e-6)
        let outOnly = try make("LUT_OUT_VIDEO_RANGE\n")
        #expect(simd_length(outOnly.lookup(SIMD3(repeating: 64.0 / 1023)) - SIMD3<Float>.zero) < 1e-6)
        #expect(simd_length(outOnly.lookup(SIMD3(repeating: 940.0 / 1023)) - SIMD3<Float>.one) < 1e-5)
    }

    @Test func inputRangeAndVideoRangeHeaders() throws {
        let lut = try CubeLUT.parse("\u{FEFF}LUT_3D_INPUT_RANGE -0.5 2\nLUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n" + identityCube3D(2))
        #expect(lut.domainMin == SIMD3(repeating: -0.5) && lut.domainMax == SIMD3(repeating: 2))
        #expect(lut.inVideoRange && lut.outVideoRange)
        let l1 = try CubeLUT.parse("LUT_1D_INPUT_RANGE 0 4\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        #expect(l1.domainMax == SIMD3(repeating: 4) && !l1.inVideoRange && !l1.outVideoRange)
        #expect(throws: CubeLUTError.self) { try CubeLUT.parse("LUT_3D_INPUT_RANGE 1\nLUT_3D_SIZE 2\n") }
    }
}
