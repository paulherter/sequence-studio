import Foundation

// Dumps LinearCanvas.swift results (polygon masks, blur, shift, compositing) as float bit patterns: `case<TAB>index<TAB>hex`.
func emit(_ name: String, _ values: [Float]) {
    for (i, v) in values.enumerated() { print("\(name)\t\(i)\t\(String(v.bitPattern, radix: 16))") }
}
let w = 24, h = 20
func maskA() -> [Float] {
    var m = PolygonMask(width: w, height: h)
    m.addPositive([SIMD2(2, 2), SIMD2(20, 4), SIMD2(8, 16)])
    m.addPositive(PolygonMask.roundedRect(x: 10, y: 8, width: 12, height: 9, radius: 3))
    m.stroke([[SIMD2(3, 3), SIMD2(18, 3), SIMD2(18, 14)]], halfWidth: 1.5)
    return m.mask()
}
let a = maskA()
emit("mask", a)
let blurred = MaskOps.blur(a, width: w, height: h, sigma: 1.7)
emit("blur", blurred)
let shifted = MaskOps.shift(a, width: w, height: h, dx: 1.3, dy: -0.6)
emit("shift", shifted)
emit("union", MaskOps.union(a, shifted))
var below = LinearCanvas(width: w, height: h)
below.fill(blurred, color: LinearCanvas.linear(RGBAColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)))
var top = LinearCanvas(width: w, height: h)
top.fill(a, color: LinearCanvas.linear(RGBAColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 0.9)))
top.fill(shifted) { x, y in SIMD4<Float>(Float(x) / 24, Float(y) / 20, 0.5, 1) * 0.5 }
emit("alpha", top.alpha)
top.place(over: below)
emit("canvas", top.pixels)
