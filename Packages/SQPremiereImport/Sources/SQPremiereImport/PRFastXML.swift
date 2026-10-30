import Foundation

/// Byte-level UTF-8 XML reader that builds the `PRNode` tree in one pass (docs/PLAYBACK-PERF.md "Import speed").
/// Produces exactly what the `XMLParser` tree builder produced: element names as written, attribute values with XML
/// attribute-value normalization (literal tab / newline -> space), text = all direct character data of the element
/// (CDATA included: XMLParser reports it as characters) trimmed like `trimmingCharacters(in: .whitespacesAndNewlines)`.
/// Returns nil for anything it does not handle (non-UTF-8 encoding, DTD, malformed input): the caller then falls back to
/// `XMLParser`, which also produces the error message.
enum PRFastXML {
    struct Result {
        var root: PRNode
        var binaries: [String: String]
    }

    private struct Fail: Error {}

    static func parse(_ data: Data) -> Result? {
        data.withUnsafeBytes { raw -> Result? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var p = Parser(buf: UnsafeBufferPointer(start: base, count: raw.count))
            return try? p.run()
        }
    }

    private struct Parser {
        let buf: UnsafeBufferPointer<UInt8>
        var i = 0
        var stack: [PRNode] = []
        /// Raw character data of each open element (bytes, before entity decoding of the whole run).
        var texts: [[UInt8]] = []
        var binaries: [String: String] = [:]
        /// Element and attribute names repeat thousands of times: one String each.
        var names: [UInt64: [(bytes: [UInt8], string: String)]] = [:]

        init(buf: UnsafeBufferPointer<UInt8>) { self.buf = buf }

        @inline(__always) func at(_ k: Int) -> UInt8 { k < buf.count ? buf[k] : 0 }

        @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        @inline(__always) static func isNameEnd(_ c: UInt8) -> Bool {
            isSpace(c) || c == UInt8(ascii: ">") || c == UInt8(ascii: "/") || c == UInt8(ascii: "=")
        }

        func starts(_ s: StaticString, at k: Int) -> Bool {
            let n = s.utf8CodeUnitCount
            guard k + n <= buf.count else { return false }
            let p = s.utf8Start
            for j in 0..<n where buf[k + j] != p[j] { return false }
            return true
        }

        func find(_ s: StaticString, from k: Int) throws -> Int {
            let first = s.utf8Start[0]
            var j = k
            while j < buf.count {
                if buf[j] == first, starts(s, at: j) { return j }
                j += 1
            }
            throw Fail()
        }

        mutating func name() throws -> String {
            let s = i
            while i < buf.count, !Self.isNameEnd(buf[i]) { i += 1 }
            guard i > s, i < buf.count, let start = buf.baseAddress?.advanced(by: s) else { throw Fail() }
            let n = i - s
            var h: UInt64 = 0xcbf2_9ce4_8422_2325                 // FNV-1a
            for k in 0..<n { h = (h ^ UInt64(start[k])) &* 0x100_0000_01b3 }
            h ^= UInt64(n) << 56
            if let list = names[h] {
                for e in list where e.bytes.count == n && e.bytes.withUnsafeBufferPointer({ memcmp($0.baseAddress!, start, n) == 0 }) {
                    return e.string
                }
            }
            let bytes = UnsafeBufferPointer(start: start, count: n)
            guard let str = String(validating: bytes, as: UTF8.self) else { throw Fail() }
            names[h, default: []].append((Array(bytes), str))
            return str
        }

        mutating func skipSpace() { while i < buf.count, Self.isSpace(buf[i]) { i += 1 } }

        mutating func run() throws -> Result {
            if starts("\u{FEFF}", at: 0) { i = 3 }
            var root: PRNode?
            while i < buf.count {
                if buf[i] != UInt8(ascii: "<") {
                    let s = i
                    while i < buf.count, buf[i] != UInt8(ascii: "<") { i += 1 }
                    if texts.isEmpty {
                        // Outside the root only whitespace is allowed.
                        for k in s..<i where !Self.isSpace(buf[k]) { throw Fail() }
                    } else {
                        texts[texts.count - 1].append(contentsOf: UnsafeBufferPointer(rebasing: buf[s..<i]))
                    }
                    continue
                }
                let c = at(i + 1)
                if c == UInt8(ascii: "?") {
                    let e = try find("?>", from: i + 2)
                    if starts("<?xml", at: i), !Self.isUTF8Declaration(UnsafeBufferPointer(rebasing: buf[i..<e])) { throw Fail() }
                    i = e + 2
                } else if c == UInt8(ascii: "!") {
                    if starts("<!--", at: i) {
                        i = try find("-->", from: i + 4) + 3
                    } else if starts("<![CDATA[", at: i) {
                        guard !texts.isEmpty else { throw Fail() }
                        // Reported as characters by XMLParser: kept literally (escaped, as the run is decoded at the end).
                        let e = try find("]]>", from: i + 9)
                        for c in UnsafeBufferPointer(rebasing: buf[(i + 9)..<e]) {
                            if c == UInt8(ascii: "&") { texts[texts.count - 1].append(contentsOf: Array("&amp;".utf8)) }
                            else { texts[texts.count - 1].append(c) }
                        }
                        i = e + 3
                    } else {
                        throw Fail()                            // DOCTYPE (entities, defaults): leave to XMLParser
                    }
                } else if c == UInt8(ascii: "/") {
                    i += 2
                    let n = try name()
                    skipSpace()
                    guard at(i) == UInt8(ascii: ">"), let top = stack.last, top.name == n else { throw Fail() }
                    i += 1
                    if let done = try close() { root = done }
                } else {
                    guard root == nil else { throw Fail() }      // a second root element
                    i += 1
                    let n = try name()
                    var attrs: [String: String] = [:]
                    var selfClosing = false
                    while true {
                        skipSpace()
                        let ch = at(i)
                        if ch == UInt8(ascii: ">") { i += 1; break }
                        if ch == UInt8(ascii: "/") {
                            guard at(i + 1) == UInt8(ascii: ">") else { throw Fail() }
                            i += 2; selfClosing = true; break
                        }
                        let s = i
                        let key = try name()
                        guard i > s else { throw Fail() }
                        skipSpace()
                        guard at(i) == UInt8(ascii: "=") else { throw Fail() }
                        i += 1
                        skipSpace()
                        let q = at(i)
                        guard q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") else { throw Fail() }
                        let vs = i + 1
                        var e = vs
                        while e < buf.count, buf[e] != q {
                            if buf[e] == UInt8(ascii: "<") { throw Fail() }
                            e += 1
                        }
                        guard e < buf.count else { throw Fail() }
                        guard attrs[key] == nil else { throw Fail() }
                        attrs[key] = try Self.decode(UnsafeBufferPointer(rebasing: buf[vs..<e]), attribute: true)
                        i = e + 1
                        guard Self.isSpace(at(i)) || at(i) == UInt8(ascii: ">") || at(i) == UInt8(ascii: "/") else { throw Fail() }
                    }
                    stack.append(PRNode(name: n, attributes: attrs, text: "", children: []))
                    texts.append([])
                    if selfClosing, let done = try close() { root = done }
                }
            }
            guard stack.isEmpty, let root else { throw Fail() }
            return Result(root: root, binaries: binaries)
        }

        /// Ends the innermost element; returns it when it was the root.
        mutating func close() throws -> PRNode? {
            guard var node = stack.popLast() else { throw Fail() }
            let raw = texts.removeLast()
            node.text = raw.isEmpty ? "" : try raw.withUnsafeBufferPointer { b in
                // ASCII whitespace off the raw ends first (no String for whitespace-only runs), the exact trim after decoding.
                var a = 0, e = b.count
                while a < e, Self.isSpace(b[a]) { a += 1 }
                while e > a, Self.isSpace(b[e - 1]) { e -= 1 }
                return a == e ? "" : try Self.trimmed(Self.decode(UnsafeBufferPointer(rebasing: b[a..<e]), attribute: false))
            }
            if let h = node.attributes["BinaryHash"], !node.text.isEmpty, binaries[h] == nil { binaries[h] = node.text }
            if stack.isEmpty { return node }
            stack[stack.count - 1].children.append(node)
            return nil
        }

        /// `<?xml version="1.0" encoding="UTF-8"?>`: UTF-8 (or no encoding named) is all this reader handles.
        static func isUTF8Declaration(_ decl: UnsafeBufferPointer<UInt8>) -> Bool {
            let s = String(decoding: decl, as: UTF8.self).lowercased()
            guard let r = s.range(of: "encoding") else { return true }
            let rest = s[r.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" }
            return rest.hasPrefix("utf-8") || rest.hasPrefix("utf8")
        }

        /// Whitespace and newlines trimmed off both ends (`CharacterSet.whitespacesAndNewlines`).
        static func trimmed(_ s: String) -> String {
            guard let f = s.utf8.first, let l = s.utf8.last else { return s }
            if f > 0x20, f < 0x80, l > 0x20, l < 0x80 { return s }      // nothing to trim (the common case)
            // Only ASCII ends can be ASCII whitespace; any non-ASCII end might be Unicode whitespace: Foundation decides.
            if f >= 0x80 || l >= 0x80 { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            let u = Array(s.utf8)
            var a = 0, b = u.count
            while a < b, isSpace(u[a]) || u[a] == 0x0B || u[a] == 0x0C { a += 1 }
            while b > a, isSpace(u[b - 1]) || u[b - 1] == 0x0B || u[b - 1] == 0x0C { b -= 1 }
            if a == 0, b == u.count { return s }
            let t = String(decoding: u[a..<b], as: UTF8.self)
            // A non-ASCII character may now sit at an end (e.g. " \u{00A0}x"): let Foundation finish the trim.
            if let f2 = t.utf8.first, let l2 = t.utf8.last, f2 >= 0x80 || l2 >= 0x80 { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            return t
        }

        /// Character data / attribute value -> String: line ends normalized (CR LF and CR -> LF), entities and character
        /// references resolved, and in attributes literal tab / CR / LF become spaces. Invalid UTF-8 or an unknown entity fails.
        static func decode(_ b: UnsafeBufferPointer<UInt8>, attribute: Bool) throws -> String {
            var plain = true
            for c in b where c == UInt8(ascii: "&") || c == 0x0D || (attribute && (c == 0x09 || c == 0x0A)) { plain = false; break }
            if plain {
                guard let s = String(validating: b, as: UTF8.self) else { throw Fail() }
                return s
            }
            var out = [UInt8]()
            out.reserveCapacity(b.count)
            var k = 0
            while k < b.count {
                let c = b[k]
                if c == 0x0D {
                    out.append(attribute ? 0x20 : 0x0A)
                    k += (k + 1 < b.count && b[k + 1] == 0x0A) ? 2 : 1
                    continue
                }
                if attribute, c == 0x09 || c == 0x0A { out.append(0x20); k += 1; continue }
                guard c == UInt8(ascii: "&") else { out.append(c); k += 1; continue }
                var e = k + 1
                while e < b.count, b[e] != UInt8(ascii: ";"), e - k < 12 { e += 1 }
                guard e < b.count, b[e] == UInt8(ascii: ";") else { throw Fail() }
                let ref = String(decoding: UnsafeBufferPointer(rebasing: b[(k + 1)..<e]), as: UTF8.self)
                switch ref {
                case "amp": out.append(UInt8(ascii: "&"))
                case "lt": out.append(UInt8(ascii: "<"))
                case "gt": out.append(UInt8(ascii: ">"))
                case "quot": out.append(UInt8(ascii: "\""))
                case "apos": out.append(UInt8(ascii: "'"))
                default:
                    guard ref.hasPrefix("#") else { throw Fail() }
                    let hex = ref.hasPrefix("#x")
                    guard let v = UInt32(ref.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let u = Unicode.Scalar(v), v != 0,
                          v == 0x9 || v == 0xA || v == 0xD || v >= 0x20 else { throw Fail() }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                }
                k = e + 1
            }
            guard let s = String(validating: out, as: UTF8.self) else { throw Fail() }
            return s
        }
    }
}
