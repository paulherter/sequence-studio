import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import SQCore

/// Premiere time unit: 254 016 000 000 ticks per second.
public enum PRTicks {
    public static let perSecond: Int64 = 254_016_000_000
    /// Ticks per 1/240000 s: every frame rate in use (24, 25, 30, 29.97, 59.94...) and 48 kHz are whole multiples of it,
    /// and Time sums stay far from Int64 overflow (a raw 254016000000 timescale would not).
    static let quantum: Int64 = perSecond / 240_000

    /// Ticks as rational time, rounded to 1/240000 s (exact for every common frame and sample rate).
    public static func time(_ ticks: Int64) -> Time {
        // Ticks of a corrupt file can be anything: clamp so the rounding below and later Time sums never overflow.
        let t = min(max(ticks, -maxTicks), maxTicks)
        let q = t >= 0 ? (t + quantum / 2) / quantum : -((-t + quantum / 2) / quantum)
        return Time(q, 240_000)
    }

    /// Largest tick magnitude read as time (about 200 days); anything beyond is clamped.
    static let maxTicks: Int64 = Int64.max / 2

    /// `a - b` that saturates instead of trapping.
    static func sub(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.subtractingReportingOverflow(b)
        return o ? (a < 0 ? Int64.min + 1 : Int64.max) : r
    }

    /// Exact frame duration (8475667200 ticks = 1001/30000 s).
    public static func frameDuration(ticksPerFrame: Int64) -> Time { Time(ticksPerFrame, perSecond) }
}

/// Finite, range-checked number reads for values a corrupt project file controls.
enum PRSafe {
    /// `d` as Int when it is finite and within +-1e15; nil for NaN, infinity and anything larger.
    static func int(_ d: Double?) -> Int? {
        guard let d, d.isFinite, abs(d) <= 1e15 else { return nil }
        return Int(d)
    }
}

public enum PRImportError: Error, Equatable, Sendable {
    case notPremiereProject
    case corruptArchive
    case xml(String)
}

/// gzip container (RFC 1952) around the project XML.
public enum PRGzip {
    /// Inflates gzip `data`; anything that is not gzip is returned unchanged (an uncompressed XML export).
    /// Largest project XML this reader inflates (real projects stay far below; a crafted file must not fill memory).
    public static let maxProjectSize = 4 << 30

    /// `limit`: throws `corruptArchive` once the output would exceed it.
    public static func inflate(_ data: Data, limit: Int = maxProjectSize) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b else { return data }
        guard b[2] == 8 else { throw PRImportError.corruptArchive }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 { guard p + 2 <= b.count else { throw PRImportError.corruptArchive }; p += 2 + (Int(b[p]) | (Int(b[p + 1]) << 8)) }
        if flags & 0x08 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x10 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x02 != 0 { p += 2 }
        guard p < b.count - 8 else { throw PRImportError.corruptArchive }
        return try rawInflate(Array(b[p..<(b.count - 8)]), limit: limit)
    }

    /// Raw deflate (RFC 1951), also used for ZIP entries (`PRZip`). Throws `corruptArchive` once the output would exceed
    /// `limit` bytes, before the surplus is kept.
#if canImport(Compression)
    static func rawInflate(_ src: [UInt8], limit: Int) throws -> Data {
        guard !src.isEmpty else { return Data() }
        let limit = max(0, limit)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PRImportError.corruptArchive
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var out = Data()
        try src.withUnsafeBufferPointer { s in
            stream.pointee.src_ptr = s.baseAddress!
            stream.pointee.src_size = s.count
            while true {
                // One byte past the limit is enough to know the stream is too long.
                let room = min(chunk, limit - out.count + 1)
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = room
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = room - stream.pointee.dst_size
                guard out.count + produced <= limit else { throw PRImportError.corruptArchive }
                out.append(dst, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw PRImportError.corruptArchive
                }
            }
        }
        return out
    }
#else
    static func rawInflate(_ src: [UInt8], limit: Int) throws -> Data { try PRInflate.inflate(src, limit: max(0, limit)) }
#endif
}

/// One XML element: name, attributes, trimmed text and children.
public struct PRNode: Sendable {
    public var name: String
    public var attributes: [String: String]
    public var text: String
    public var children: [PRNode]

    /// First child by name; `path` may go deeper with "/" ("Clip/InPoint").
    public func child(_ path: String) -> PRNode? {
        // One level (most lookups): String == String, no split.
        guard path.utf8.contains(UInt8(ascii: "/")) else { return children.first { $0.name == path } }
        var n: PRNode? = self
        for part in path.split(separator: "/") { let p = String(part); n = n?.children.first { $0.name == p } }
        return n
    }
    public func children(_ path: String) -> [PRNode] {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return [] }
        var n: PRNode? = self
        for part in parts.dropLast() { n = n?.children.first { $0.name == part } }
        return n?.children.filter { $0.name == last } ?? []
    }
    public func text(_ path: String) -> String? { child(path)?.text }
    public func int(_ path: String) -> Int64? { text(path).flatMap { Int64($0) } }
    /// Depth-first search for the first descendant called `name`.
    public func descendant(_ name: String) -> PRNode? {
        for c in children {
            if c.name == name { return c }
            if let d = c.descendant(name) { return d }
        }
        return nil
    }
    /// The id another object refers to this one by.
    public var objectID: String? { attributes["ObjectID"] ?? attributes["ObjectUID"] }
    /// The id this reference node points at.
    public var reference: String? { attributes["ObjectRef"] ?? attributes["ObjectURef"] }
}

/// The flat top-level object list of a project, by ObjectID / ObjectUID.
public struct PRObjectTable: Sendable {
    public let root: PRNode
    private let index: [String: Int]
    /// Binary values by `BinaryHash`: Premiere writes a repeated blob once and leaves later copies empty.
    public let binaries: [String: String]

    /// `foundation`: always `XMLParser` (the reference the fast reader is tested against).
    public init(xml: Data, foundation: Bool = false) throws {
        let root: PRNode
        if !foundation, let fast = PRFastXML.parse(xml) {
            root = fast.root
            binaries = fast.binaries
        } else {
            // Anything the fast reader does not handle (and every malformed file, for the error message).
            let builder = TreeBuilder()
            let parser = XMLParser(data: xml)
            parser.delegate = builder
            guard parser.parse(), let r = builder.root else {
                throw PRImportError.xml(parser.parserError.map { String(describing: $0) } ?? "no root element")
            }
            root = r
            binaries = builder.binaries
        }
        guard root.name == "PremiereData" else { throw PRImportError.notPremiereProject }
        self.root = root
        var index = [String: Int]()
        for (i, c) in root.children.enumerated() { if let id = c.objectID { index[id] = i } }
        self.index = index
    }

    public subscript(id: String) -> PRNode? { index[id].map { root.children[$0] } }
    /// The object a reference node (`<X ObjectRef="12"/>`) points at.
    public func deref(_ node: PRNode?) -> PRNode? { node?.reference.flatMap { self[$0] } }
    public func all(named name: String) -> [PRNode] { root.children.filter { $0.name == name } }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var stack: [PRNode] = []
    var texts: [String] = []
    var root: PRNode?
    var binaries: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        stack.append(PRNode(name: name, attributes: attributes, text: "", children: []))
        texts.append("")
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard var node = stack.popLast() else { return }
        node.text = texts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if let h = node.attributes["BinaryHash"], !node.text.isEmpty, binaries[h] == nil { binaries[h] = node.text }
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }
}
