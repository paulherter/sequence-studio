// Throwaway Swift dumper for parity checks; not part of any package. Same output format as src/bin/dump.rs.
// build.sh compiles it with PRZip.swift, PRFastXML.swift, the PRGzip/PRNode part of PRContainer.swift and SQCore's
// RawInflate.swift taken by path from Packages/ (never copied into the repo).
import Foundation
#if SQ_APPLE_INFLATE
import Compression
#endif

func fnv(_ b: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for c in b { h = (h ^ UInt64(c)) &* 0x100_0000_01b3 }
    return h
}
func hex16(_ v: UInt64) -> String { let s = String(v, radix: 16); return String(repeating: "0", count: 16 - s.count) + s }

func esc(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        if u.value >= 0x20 && u.value <= 0x7E && u != "\\" && u != "\"" { o.unicodeScalars.append(u) }
        else { o += "\\u{" + String(u.value, radix: 16) + "}" }
    }
    return o + "\""
}
func bytesLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

var out = ""
func line(_ s: String) { out += s; out += "\n" }

func dumpNode(_ root: PRNode) {
    var stack: [(PRNode, Int)] = [(root, 0)]
    while let (n, d) = stack.popLast() {
        let attrs = n.attributes.keys.sorted(by: bytesLess).map { "\(esc($0))=\(esc(n.attributes[$0]!))" }.joined(separator: ",")
        line("NODE \(d) \(esc(n.name)) text=\(esc(n.text)) attrs=\(attrs)")
        for c in n.children.reversed() { stack.append((c, d + 1)) }
    }
}

func dumpXML(_ bytes: Data) {
    guard let fast = PRFastXML.parse(bytes) else { line("XML nil"); return }
    guard fast.root.name == "PremiereData" else { line("XML error notPremiereProject"); return }
    var index = [String: Int]()
    for (i, c) in fast.root.children.enumerated() { if let id = c.objectID { index[id] = i } }
    line("XML ok objects=\(index.count) binaries=\(fast.binaries.count)")
    for k in fast.binaries.keys.sorted(by: bytesLess) {
        let v = fast.binaries[k]!
        line("BINARY \(esc(k)) \(v.utf8.count) \(hex16(fnv(Array(v.utf8))))")
    }
    dumpNode(fast.root)
}

func dump(_ data: Data, limit: Int) {
    line("SIZE \(data.count)")
    if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
        line("CONTAINER zip")
        guard let z = try? PRZip(data) else { line("ERROR corruptArchive"); return }
        line("ENTRIES \(z.entries.count)")
        for (i, e) in z.entries.enumerated() {
            line("ENTRY \(i) name=\(esc(e.name)) method=\(e.method) csize=\(e.compressedSize) usize=\(e.uncompressedSize) local=\(e.localOffset) enc=\(e.encrypted ? 1 : 0)")
            if let d = try? z.data(e) { line("DATA \(i) ok \(d.count) \(hex16(fnv([UInt8](d))))") }
            else { line("DATA \(i) error corruptArchive") }
        }
        if let e = z.entry("project.prgraphic") { line("LOOKUP \"project.prgraphic\" found \(z.entries.firstIndex(of: e)!)") }
        else { line("LOOKUP \"project.prgraphic\" none") }
        return
    }
    let b = [UInt8](data)
    line(b.count >= 18 && b[0] == 0x1f && b[1] == 0x8b ? "CONTAINER gzip" : "CONTAINER plain")
    guard let x = try? PRGzip.inflate(data, limit: limit) else { line("INFLATE error corruptArchive"); return }
    line("INFLATE ok \(x.count) \(hex16(fnv([UInt8](x))))")
    dumpXML(x)
}

var args = Array(CommandLine.arguments.dropFirst())
var limit = PRGzip.maxProjectSize
if args.count >= 2, args[0] == "--limit" { limit = Int(args[1])!; args.removeFirst(2) }
guard let path = args.first, let data = FileManager.default.contents(atPath: path) else {
    FileHandle.standardError.write(Data("usage: dump-swift [--limit N] <file>\n".utf8)); exit(2)
}
dump(data, limit: limit)
FileHandle.standardOutput.write(Data(out.utf8))
