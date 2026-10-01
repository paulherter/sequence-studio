import Foundation

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
        self = delegate.result
    }

    private init() {}

    /// Sidecar first, then the XML embedded in the MP4. nil if neither exists.
    public static func read(forClip url: URL) throws -> SonyMetadata? {
        if let sidecar = sidecarURL(for: url) {
            return try SonyMetadata(xml: Data(contentsOf: sidecar))
        }
        guard let xml = try embeddedXML(in: url) else { return nil }
        return try SonyMetadata(xml: xml)
    }

    private static func sidecarURL(for clip: URL) -> URL? {
        let dir = clip.deletingLastPathComponent()
        let wanted = (clip.deletingPathExtension().lastPathComponent + "M01.xml").lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.lowercased() == wanted }.map { dir.appendingPathComponent($0) }
    }

    // MARK: Box walking

    private static let maxXMLBytes: UInt64 = 1_048_576

    private static func embeddedXML(in url: URL) throws -> Data? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        return try findXML(fh, from: 0, to: end, depth: 0)
    }

    private static func findXML(_ fh: FileHandle, from start: UInt64, to end: UInt64, depth: Int) throws -> Data? {
        var pos = start
        while pos + 8 <= end {
            try fh.seek(toOffset: pos)
            guard let h = try fh.read(upToCount: 8), h.count == 8 else { return nil }
            let b = [UInt8](h)
            var size = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
            let type = String(decoding: b[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1 {
                guard let l = try fh.read(upToCount: 8), l.count == 8 else { return nil }
                size = [UInt8](l).reduce(0) { $0 << 8 | UInt64($1) }
                header = 16
            } else if size == 0 {
                size = end - pos
            }
            guard size >= header, pos + size <= end else { return nil }
            let body = pos + header
            let boxEnd = pos + size
            if type == "meta", depth < 2 {
                // FullBox: skip 4 bytes version/flags.
                if let x = try findXML(fh, from: body + 4, to: boxEnd, depth: depth + 1) { return x }
            } else if type == "moov", depth == 0 {
                if let x = try findXML(fh, from: body, to: boxEnd, depth: depth + 1) { return x }
            } else if type == "xml ", depth > 0 {
                let len = boxEnd - body - 4
                guard len > 0, len <= maxXMLBytes else { return nil }
                try fh.seek(toOffset: body + 4)
                return try fh.read(upToCount: Int(len))
            }
            pos = boxEnd
        }
        return nil
    }

    // MARK: XML

    private final class Parser: NSObject, XMLParserDelegate {
        var result = SonyMetadata()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
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
