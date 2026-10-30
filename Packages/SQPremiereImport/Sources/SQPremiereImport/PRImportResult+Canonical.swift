import Foundation
import SQCore

extension PRImportResult {
    /// The result as sorted-key JSON with every UUID replaced by its first-appearance number (`#0`, `#1`, ...): two maps of
    /// the same document give the same string although each run draws fresh UUIDs. For differential tests (old vs new
    /// mapper) and `EngineBench import-probe`.
    public func canonicalJSON() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let p = (try? e.encode(project)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        let r = (try? e.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return Self.renumberUUIDs(p + "\n" + r)
    }

    /// Stable 64-bit FNV-1a of `canonicalJSON()`, hex.
    public func canonicalDigest() -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in canonicalJSON().utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    static func renumberUUIDs(_ s: String) -> String {
        // 8-4-4-4-12 hex, as JSONEncoder writes UUIDs.
        let re = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        let ns = s as NSString
        var seen: [String: Int] = [:]
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let u = ns.substring(with: m.range).uppercased()
            let n = seen[u] ?? seen.count
            seen[u] = n
            out += "#\(n)"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
