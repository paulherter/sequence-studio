#if !canImport(simd)
// The few Apple `simd` functions and matrix types the portable color and geometry code uses, for systems without the
// simd module (Windows, Linux). Same names and memory layout (column-major, 3-wide columns padded to four lanes), so
// the code and the GPU constant blocks built from these values are the same on every system.

@inline(__always) func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
@inline(__always) func simd_length<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(a, a).squareRoot() }
@inline(__always) func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMin(a, b) }
@inline(__always) func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMax(a, b) }
@inline(__always) func simd_clamp<V: SIMD>(_ x: V, _ lo: V, _ hi: V) -> V where V.Scalar: Comparable {
    pointwiseMin(pointwiseMax(x, lo), hi)
}
@inline(__always) func simd_abs<V: SIMD>(_ a: V) -> V where V.Scalar: FloatingPoint {
    var r = a
    for i in r.indices { r[i] = abs(r[i]) }
    return r
}
@inline(__always) func simd_reduce_max<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { a.max() }
@inline(__always) func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V where V.Scalar: FloatingPoint { a + (b - a) * t }
@inline(__always) func simd_mix<S: BinaryFloatingPoint>(_ a: S, _ b: S, _ t: S) -> S { a + (b - a) * t }

/// A 3x3 matrix of columns (as Apple's `simd_float3x3` / `simd_double3x3`).
public struct PortableMatrix3<S: BinaryFloatingPoint & SIMDScalar & Sendable>: Equatable, @unchecked Sendable {
    public var columns: (SIMD3<S>, SIMD3<S>, SIMD3<S>)
    public init() { columns = (.zero, .zero, .zero) }
    public init(_ c0: SIMD3<S>, _ c1: SIMD3<S>, _ c2: SIMD3<S>) { columns = (c0, c1, c2) }
    public init(columns: (SIMD3<S>, SIMD3<S>, SIMD3<S>)) { self.columns = columns }
    public init(_ c: [SIMD3<S>]) { columns = (c[0], c[1], c[2]) }
    public init(diagonal d: SIMD3<S>) { columns = (SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z)) }
    public init(rows r: [SIMD3<S>]) {
        columns = (SIMD3(r[0].x, r[1].x, r[2].x), SIMD3(r[0].y, r[1].y, r[2].y), SIMD3(r[0].z, r[1].z, r[2].z))
    }

    public subscript(_ i: Int) -> SIMD3<S> {
        get { i == 0 ? columns.0 : i == 1 ? columns.1 : columns.2 }
        set { if i == 0 { columns.0 = newValue } else if i == 1 { columns.1 = newValue } else { columns.2 = newValue } }
    }
    public subscript(_ c: Int, _ r: Int) -> S { self[c][r] }

    public var transpose: Self { Self(rows: [columns.0, columns.1, columns.2]) }

    public var determinant: S {
        let (a, b, c) = columns
        return a.x * (b.y * c.z - c.y * b.z) - b.x * (a.y * c.z - c.y * a.z) + c.x * (a.y * b.z - b.y * a.z)
    }

    /// Inverse by the adjugate (as simd: a singular matrix gives non-finite values).
    public var inverse: Self {
        // Rows of the inverse: the cross products of the other two columns over the determinant.
        func cross(_ u: SIMD3<S>, _ v: SIMD3<S>) -> SIMD3<S> {
            SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        }
        let (a, b, c) = columns
        let d = determinant
        return Self(rows: [cross(b, c) / d, cross(c, a) / d, cross(a, b) / d])
    }

    public static func * (m: Self, v: SIMD3<S>) -> SIMD3<S> { m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z }
    public static func * (m: Self, n: Self) -> Self { Self(columns: (m * n.columns.0, m * n.columns.1, m * n.columns.2)) }
    public static func * (m: Self, s: S) -> Self { Self(columns: (m.columns.0 * s, m.columns.1 * s, m.columns.2 * s)) }
    public static func + (m: Self, n: Self) -> Self {
        Self(columns: (m.columns.0 + n.columns.0, m.columns.1 + n.columns.1, m.columns.2 + n.columns.2))
    }
    public static func - (m: Self, n: Self) -> Self {
        Self(columns: (m.columns.0 - n.columns.0, m.columns.1 - n.columns.1, m.columns.2 - n.columns.2))
    }
    public static func == (m: Self, n: Self) -> Bool {
        m.columns.0 == n.columns.0 && m.columns.1 == n.columns.1 && m.columns.2 == n.columns.2
    }
}

/// A 2x2 matrix of columns (as Apple's `simd_float2x2`).
public struct PortableMatrix2<S: BinaryFloatingPoint & SIMDScalar & Sendable>: Equatable, @unchecked Sendable {
    public var columns: (SIMD2<S>, SIMD2<S>)
    public init(columns: (SIMD2<S>, SIMD2<S>)) { self.columns = columns }
    public var determinant: S { columns.0.x * columns.1.y - columns.1.x * columns.0.y }
    public var inverse: Self {
        let (a, b) = columns
        let d = determinant
        return Self(columns: (SIMD2(b.y, -a.y) / d, SIMD2(-b.x, a.x) / d))
    }
    public static func * (m: Self, v: SIMD2<S>) -> SIMD2<S> { m.columns.0 * v.x + m.columns.1 * v.y }
    public static func == (m: Self, n: Self) -> Bool { m.columns.0 == n.columns.0 && m.columns.1 == n.columns.1 }
}

public typealias simd_float3x3 = PortableMatrix3<Float>
public typealias simd_double3x3 = PortableMatrix3<Double>
public typealias simd_float2x2 = PortableMatrix2<Float>
public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))
#endif
