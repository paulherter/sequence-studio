import Foundation

// Dumps FontVariations (SfntVariations.swift) of the bundled Inter: `case<TAB>index<TAB>Double bit pattern in hex`.
func emit(_ name: String, _ values: [Double]) {
    for (i, v) in values.enumerated() { print("\(name)\t\(i)\t\(String(v.bitPattern, radix: 16))") }
}
let path = CommandLine.arguments[1]
let bytes = FontBytes(b: [UInt8](try! Data(contentsOf: URL(fileURLWithPath: path))))
let v = FontVariations(bytes, tables: bytes.tables())!
emit("axes", v.axes.flatMap { [$0.minimum, $0.defaultValue, $0.maximum] })
print("axis_tags\t0\t" + v.axes.map(\.tag).joined(separator: ","))
emit("instances", v.instances.flatMap { $0 })
let users: [[Double]] = [[14, 700], [32, 100], [20, 900], [14, 400], [20, 350]]
for (n, u) in users.enumerated() { emit("normalized\(n)", v.normalized(u)) }
let coords = v.normalized([20, 700])
let glyphs = [36, 41, 68, 100, 400]
emit("advance", glyphs.map { v.advanceDelta(glyph: $0, coords: coords) ?? -1 })
let original = (0..<40).map { GlyphRasterFont.Point(x: Double($0 * 7 % 53), y: Double($0 * 11 % 37), onCurve: true) }
for g in glyphs {
    let d = v.deltas(glyph: g, pointCount: 40, original: original, ends: [19, 39], coords: coords)
    emit("deltas\(g)", d?.flatMap { [$0.x, $0.y] } ?? [])
}
