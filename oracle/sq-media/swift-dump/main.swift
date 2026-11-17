import Foundation

// Differential dump for the Vorbis decoder: a synthetic stream (setup built here, packets from a fixed generator) is decoded by the
// real VorbisDecoder.swift; the Rust test replays the same bytes and compares the floats.

struct BitWriter {
    var bytes: [UInt8] = []
    var nbits = 0
    mutating func put(_ v: Int, _ n: Int) {
        for i in 0..<n {
            if nbits % 8 == 0 { bytes.append(0) }
            if (v >> i) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(1 << (nbits % 8)) }
            nbits += 1
        }
    }
}

/// value = mantissa * 2^(exp - 788) with exp = 768, so mantissa = value * 2^20.
func pack32(_ v: Double) -> Int {
    (v < 0 ? 0x8000_0000 : 0) | (768 << 21) | Int((abs(v) * Double(1 << 20)).rounded())
}

func codebook(_ w: inout BitWriter, dims: Int, lengths: [Int], lookup: (min: Double, delta: Double, bits: Int, values: [Int])? = nil) {
    w.put(0x564342, 24); w.put(dims, 16); w.put(lengths.count, 24)
    w.put(0, 1)      // unordered
    w.put(0, 1)      // not sparse
    for l in lengths { w.put(l - 1, 5) }
    if let lk = lookup {
        w.put(1, 4); w.put(pack32(lk.min), 32); w.put(pack32(lk.delta), 32); w.put(lk.bits - 1, 4); w.put(0, 1)
        for v in lk.values { w.put(v, lk.bits) }
    } else { w.put(0, 4) }
}

var w = BitWriter()
w.put(2, 8)                                                       // three codebooks
codebook(&w, dims: 2, lengths: [2, 2, 2, 2])                      // 0: residue classbook (2 classes, 2 per word)
codebook(&w, dims: 1, lengths: [1, 2, 3, 4, 5, 6, 7, 7])          // 1: floor y values
codebook(&w, dims: 2, lengths: [2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 6, 6],
         lookup: (min: -1.5, delta: 1.0, bits: 3, values: [0, 1, 2, 3]))   // 2: residue vectors (lookup type 1)
w.put(0, 6); w.put(0, 16)                                         // one time placeholder
w.put(0, 6); w.put(1, 16)                                         // one floor, type 1
w.put(1, 5); w.put(0, 4)                                          // 1 partition of class 0
w.put(1, 3); w.put(0, 2)                                          // class 0: dimension 2, subclasses 0
w.put(2, 8)                                                       // subclass book 1 (stored +1)
w.put(1, 2); w.put(7, 4)                                          // multiplier 2, rangeBits 7
w.put(40, 7); w.put(90, 7)                                        // two x values
w.put(2, 6)                                                       // three residues: types 0, 1, 2
for type in [0, 1, 2] {
    w.put(type, 16); w.put(0, 24); w.put(96, 24); w.put(3, 24)    // begin 0, end 96, partition size 4
    w.put(1, 6)                                                   // 2 classifications
    w.put(0, 8)                                                   // classbook 0
    w.put(0, 3); w.put(0, 1)                                      // class 0: no books
    w.put(1, 3); w.put(0, 1)                                      // class 1: pass 0 book
    w.put(2, 8)                                                   // book 2
}
w.put(2, 6)                                                       // three mappings
func mapping(coupling: Bool, residue: Int) {
    w.put(0, 16); w.put(0, 1)                                     // type 0, one submap
    if coupling { w.put(1, 1); w.put(0, 8); w.put(0, 1); w.put(1, 1) } else { w.put(0, 1) }
    w.put(0, 2); w.put(0, 8); w.put(0, 8); w.put(residue, 8)      // reserved, unused, floor 0, residue
}
mapping(coupling: false, residue: 0)
mapping(coupling: true, residue: 1)
mapping(coupling: false, residue: 2)
w.put(3, 6)                                                       // four modes
for (flag, map) in [(0, 0), (1, 1), (0, 2), (1, 2)] { w.put(flag, 1); w.put(0, 16); w.put(0, 16); w.put(map, 8) }
w.put(1, 1)                                                       // framing
var setup: [UInt8] = [5] + Array("vorbis".utf8) + w.bytes

var ident: [UInt8] = [1] + Array("vorbis".utf8) + [0, 0, 0, 0, 2, 0x44, 0xAC, 0, 0] + [UInt8](repeating: 0, count: 12) + [0xA8, 1]
let comment: [UInt8] = [3] + Array("vorbis".utf8) + [0, 0, 0, 0, 0, 0, 0, 0, 1]
var priv: [UInt8] = [2, UInt8(ident.count), UInt8(comment.count)] + ident + comment + setup

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
print("setup\t\(hex(priv))")
let dec = try VorbisDecoder(codecPrivate: Data(priv))
print("info\t\(dec.channels)\t\(dec.sampleRate)")

var x: UInt64 = 20261105
func next() -> UInt8 { x = x &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: x >> 33) }
for i in 0..<28 {
    let mode = [0, 1, 2, 3, 3, 1, 0, 2][i % 8]
    var p = (0..<(i % 5 == 4 ? 20 : 170)).map { _ in next() }
    p[0] = (p[0] & 0xF8) | UInt8(mode << 1)
    print("packet\t\(hex(p))")
    print("blocksize\t\(dec.blockSize(of: Data(p)).map(String.init) ?? "nil")")
    let out = dec.decode(Data(p))
    for (c, ch) in out.enumerated() {
        let vals = stride(from: 0, to: ch.count, by: 5).map { String(format: "%.9g", ch[$0]) }
        print("out\t\(c)\t\(ch.count)\t\(vals.joined(separator: " "))")
    }
}
