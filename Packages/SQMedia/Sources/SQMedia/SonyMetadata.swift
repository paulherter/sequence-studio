import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Synchronization

/// Sony NonRealTimeMeta (sidecar `<clip>M01.XML` or the `xml ` box embedded in the MP4).
public struct SonyMetadata: Sendable, Hashable {
    public var captureGamma: String?
    public var captureColorPrimaries: String?
    public var codingEquations: String?
    public var modelName: String?
    public var relatedLUTFile: String?

    public var isSLog3SGamut3Cine: Bool {
        (captureGamma?.lowercased().hasPrefix("s-log3") ?? false)
            && captureColorPrimaries?.lowercased() == "s-gamut3-cine"
    }

    public init(xml: Data) throws {
        let delegate = Parser()
        var xml = xml
        while xml.last == 0 { xml.removeLast() }  // Sony pads the embedded box with a NUL
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        // swift-corelibs-foundation (Windows) recovers from mismatched tags instead of failing: check nesting here.
        guard delegate.wellNested, delegate.open.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self = delegate.result
    }

    private init() {}

    /// Sidecar first, then the XML embedded in the MP4. nil if neither exists.
    public static func read(forClip url: URL) throws -> SonyMetadata? {
        if let sidecar = sidecarURL(for: url) {
            // Bounded: a huge file named like the sidecar is not loaded.
            return try CameraMetadata.sidecarData(sidecar).map { try SonyMetadata(xml: $0) }
        }
        guard let xml = try embeddedBoxes(in: url).xml else { return nil }
        return try SonyMetadata(xml: xml)
    }

    static func sidecarURL(for clip: URL) -> URL? {
        let dir = clip.deletingLastPathComponent()
        let wanted = (clip.deletingPathExtension().lastPathComponent + "M01.xml").lowercased()
        return listing(of: dir)[wanted].map { dir.appendingPathComponent($0) }
    }

    /// Lowercased name -> name of the files in `dir`. An import of a folder of N clips used to list the folder N times
    /// (O(N^2) names; 300 clips: a quarter of the probe time). Cached per folder and checked against the folder's
    /// modification date, so a sidecar copied in later is seen.
    private struct Listing { var modified: Date?; var names: [String: String] }
    private static let listings = Mutex<[String: Listing]>([:])
    private static let listingCount = Atomic<Int>(0)
    /// Number of folder listings read so far (tests).
    static var directoryListings: Int { listingCount.load(ordering: .relaxed) }

    static func listing(of dir: URL) -> [String: String] {
        let path = dir.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = listings.withLock({ $0[path] }), hit.modified == modified, modified != nil { return hit.names }
        listingCount.add(1, ordering: .relaxed)
        var names: [String: String] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where names[n.lowercased()] == nil {
            names[n.lowercased()] = n
        }
        listings.withLock { l in
            if l.count >= 32 { l.removeAll() }
            l[path] = Listing(modified: modified, names: names)
        }
        return names
    }

    // MARK: Box walking

    private static let maxPayloadBytes: UInt64 = 1_048_576

    /// What one walk over the MP4 boxes (top level, `moov`, `meta`) finds: Sony's `xml ` box, or Canon's maker notes
    /// (`CMT3` inside Canon's `uuid` box in `moov`). The walk ends at the first of the two.
    struct EmbeddedBoxes { var xml: Data?; var canonMakerNotes: Data? }

    static func embeddedBoxes(in url: URL) throws -> EmbeddedBoxes {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        var found = EmbeddedBoxes()
        _ = try find(fh, from: 0, to: end, depth: 0, into: &found)
        return found
    }

    private struct Box { var type: String; var body: UInt64; var end: UInt64 }

    private static func box(_ fh: FileHandle, at pos: UInt64, limit end: UInt64) throws -> Box? {
        try fh.seek(toOffset: pos)
        guard let h = try fh.read(upToCount: 8), h.count == 8 else { return nil }
        let b = [UInt8](h)
        var size = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
        var header: UInt64 = 8
        if size == 1 {
            guard let l = try fh.read(upToCount: 8), l.count == 8 else { return nil }
            size = [UInt8](l).reduce(0) { $0 << 8 | UInt64($1) }
            header = 16
        } else if size == 0 {
            size = end - pos
        }
        guard size >= header, size <= end - pos else { return nil }
        return Box(type: String(decoding: b[4..<8], as: UTF8.self), body: pos + header, end: pos + size)
    }

    /// true = the walk is over (found, or the one box that could hold it is unusable).
    private static func find(_ fh: FileHandle, from start: UInt64, to end: UInt64, depth: Int,
                             into found: inout EmbeddedBoxes) throws -> Bool {
        var pos = start
        while pos + 8 <= end {
            guard let b = try box(fh, at: pos, limit: end) else { return false }
            if b.type == "meta", depth < 2 {
                // FullBox: skip 4 bytes version/flags.
                if try find(fh, from: b.body + 4, to: b.end, depth: depth + 1, into: &found) { return true }
            } else if b.type == "moov", depth == 0 {
                if try find(fh, from: b.body, to: b.end, depth: depth + 1, into: &found) { return true }
            } else if b.type == "xml ", depth > 0 {
                guard b.end > b.body + 4, b.end - b.body - 4 <= maxPayloadBytes else { return true }
                try fh.seek(toOffset: b.body + 4)
                found.xml = try fh.read(upToCount: Int(b.end - b.body - 4))
                return true
            } else if b.type == "uuid", depth == 1, b.end >= b.body + 16 {
                try fh.seek(toOffset: b.body)
                if let id = try fh.read(upToCount: 16), [UInt8](id) == CanonMetadata.boxUUID {
                    var p = b.body + 16
                    while p + 8 <= b.end, let c = try box(fh, at: p, limit: b.end) {
                        if c.type == "CMT3" {
                            guard c.end > c.body, c.end - c.body <= maxPayloadBytes else { return true }
                            try fh.seek(toOffset: c.body)
                            found.canonMakerNotes = try fh.read(upToCount: Int(c.end - c.body))
                            return true
                        }
                        p = c.end
                    }
                    return true     // Canon's box without maker notes: nothing more to find in this file
                }
            }
            pos = b.end
        }
        return false
    }

    // MARK: XML

    private final class Parser: NSObject, XMLParserDelegate {
        var result = SonyMetadata()
        var open: [String] = []
        var wellNested = true

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if open.last == name { open.removeLast() } else { wellNested = false }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            open.append(name)
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "Item":
                let v = a["value"]
                switch a["name"] {
                case "CaptureGammaEquation": result.captureGamma = v
                case "CaptureColorPrimaries": result.captureColorPrimaries = v
                case "CodingEquations": result.codingEquations = v
                default: break
                }
            case "Device":
                if let m = a["modelName"] { result.modelName = m }
            case "RelatedTo":
                if a["rel"] == "LUT", result.relatedLUTFile == nil { result.relatedLUTFile = a["file"] }
            default: break
            }
        }
    }
}
