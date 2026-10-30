import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SQCore

/// What a Canon clip says about its log curve and gamut. MP4/MOV: the maker notes Canon embeds in the movie header
/// (`moov` / `uuid` 85c0b687-820f-11e0-8111-f4ce462b6a48 / `CMT3`, a TIFF structure; tag 0x4026 holds the log
/// settings). MXF (XF-AVC): the clip's XML sidecar. Layout of the maker notes as documented by ExifTool (Canon LogInfo).
public struct CanonMetadata: Sendable, Hashable {
    public enum Curve: Int, Sendable, Hashable { case log = 1, log2 = 2, log3 = 3 }
    public enum Gamut: Int, Sendable, Hashable { case bt709 = 0, bt2020 = 1, cinemaGamut = 2 }

    public var curve: Curve?
    public var gamut: Gamut?

    public init(curve: Curve?, gamut: Gamut?) { self.curve = curve; self.gamut = gamut }

    /// The input color space to preselect. nil unless the clip names both a log curve and a gamut: a clip recorded
    /// without Canon Log, or metadata that leaves one of the two open, stays on the tagged / default space.
    public var colorSpace: ColorSpaceID? {
        guard let curve, let gamut else { return nil }
        switch (curve, gamut) {
        case (.log, .cinemaGamut): return .canonLogCinemaGamut
        case (.log, .bt2020): return .canonLogBT2020
        case (.log, .bt709): return .canonLogBT709
        case (.log2, .cinemaGamut): return .canonLog2CinemaGamut
        case (.log2, .bt2020): return .canonLog2BT2020
        case (.log2, .bt709): return .canonLog2BT709
        case (.log3, .cinemaGamut): return .canonLog3CinemaGamut
        case (.log3, .bt2020): return .canonLog3BT2020
        case (.log3, .bt709): return .canonLog3BT709
        }
    }

    static let boxUUID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]

    // MARK: maker notes (MP4)

    private static let logInfoTag = 0x4026
    private static let gamutIndex = 9, curveIndex = 11      // 32-bit entries of the log settings block

    /// Reads the log settings from the `CMT3` payload (TIFF header, one directory of maker note tags).
    /// nil when it is not a TIFF structure or has no log settings.
    public init?(makerNotes tiff: Data) {
        let b = [UInt8](tiff)
        guard b.count >= 8 else { return nil }
        let little: Bool
        if b[0] == 0x49, b[1] == 0x49 { little = true } else if b[0] == 0x4D, b[1] == 0x4D { little = false } else { return nil }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= b.count else { return nil }
            return little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            let v = (0..<4).map { UInt32(b[o + $0]) }
            return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
        }
        guard u16(2) == 42, let dir = u32(4).map(Int.init), let count = u16(dir) else { return nil }
        for i in 0..<count {
            let e = dir + 2 + i * 12
            guard let tag = u16(e) else { return nil }
            guard tag == Self.logInfoTag else { continue }
            // 32-bit values (signed or unsigned long), stored at an offset; the block must reach the curve entry.
            guard let type = u16(e + 2), type == 9 || type == 4, let n = u32(e + 4), n > Self.curveIndex, n < 4096,
                  let at = u32(e + 8).map(Int.init), at <= b.count,
                  let g = u32(at + Self.gamutIndex * 4), let c = u32(at + Self.curveIndex * 4) else { return nil }
            self.init(curve: Curve(rawValue: Int(Int32(bitPattern: c))), gamut: Gamut(rawValue: Int(Int32(bitPattern: g))))
            return
        }
        return nil
    }

    // MARK: sidecar (XF-AVC MXF)

    private static let curveNames: [String: Curve] = ["canonlog": .log, "clog": .log, "canonlog2": .log2, "clog2": .log2,
                                                      "canonlog3": .log3, "clog3": .log3]
    private static let gamutNames: [String: Gamut] = ["cinemagamut": .cinemaGamut, "cgamut": .cinemaGamut,
                                                      "bt2020": .bt2020, "rec2020": .bt2020, "bt709": .bt709, "rec709": .bt709]

    /// Reads a Canon clip XML. Canon's schema is not public, so no exact element names are assumed: a whole element
    /// text or attribute value has to be a curve name (Canon Log, Canon Log 2, Canon Log 3) or a gamut name, and it has
    /// to sit in or under an element that is Canon's (element name or a namespace declared on it contains "canon").
    /// The word Canon somewhere in another vendor's XML does not count. Two different curves or gamuts give nothing.
    public init?(xml: Data) {
        guard xml.count <= CameraMetadata.maxSidecarBytes,
              String(decoding: xml, as: UTF8.self).lowercased().contains("canon") else { return nil }
        let delegate = Scanner()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        var curves = Set<Curve>(), gamuts = Set<Gamut>()
        for value in delegate.values {
            let key = String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if let c = Self.curveNames[key] { curves.insert(c) }
            if let g = Self.gamutNames[key] { gamuts.insert(g) }
        }
        guard curves.count == 1 else { return nil }
        self.init(curve: curves.first, gamut: gamuts.count == 1 ? gamuts.first : nil)
    }

    private final class Scanner: NSObject, XMLParserDelegate {
        var values: [String] = []
        private var text = ""
        /// One entry per open element: it or an ancestor is Canon's.
        private var scope: [Bool] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            text = ""
            let namespaces = a.filter { $0.key == "xmlns" || $0.key.hasPrefix("xmlns:") }
            let own = name.lowercased().contains("canon") || namespaces.values.contains { $0.lowercased().contains("canon") }
            scope.append(own || scope.last == true)
            if scope.last == true { values.append(contentsOf: a.filter { namespaces[$0.key] == nil }.values) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 256 { text += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if scope.popLast() == true, !text.isEmpty { values.append(text) }
            text = ""
        }
    }
}

/// Camera metadata that decides the detected color space, read once per import.
enum CameraMetadata {
    /// Sony sidecar first, then one walk over the MP4 boxes for Sony's embedded XML or Canon's maker notes, then (MXF,
    /// `boxes` false) a Canon XML sidecar named like the clip. Best-effort: any error reads as "no metadata".
    static let maxSidecarBytes = 1_048_576

    /// A sidecar's bytes, nil when it is larger than `maxSidecarBytes` or unreadable. Never loads more than the limit
    /// plus one byte: a huge file that only happens to be named like the clip's sidecar costs nothing.
    static func sidecarData(_ url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxSidecarBytes + 1), data.count <= maxSidecarBytes else { return nil }
        return data
    }

    static func read(forClip url: URL, boxes: Bool = true) -> (sony: SonyMetadata?, canon: CanonMetadata?) {
        if let sidecar = SonyMetadata.sidecarURL(for: url) {
            return (sidecarData(sidecar).flatMap { try? SonyMetadata(xml: $0) }, nil)
        }
        if boxes {
            guard let found = try? SonyMetadata.embeddedBoxes(in: url) else { return (nil, nil) }
            return (found.xml.flatMap { try? SonyMetadata(xml: $0) }, found.canonMakerNotes.flatMap(CanonMetadata.init(makerNotes:)))
        }
        let dir = url.deletingLastPathComponent()
        let wanted = (url.deletingPathExtension().lastPathComponent + ".xml").lowercased()
        guard let name = SonyMetadata.listing(of: dir)[wanted],
              let data = sidecarData(dir.appendingPathComponent(name)) else { return (nil, nil) }
        return (nil, CanonMetadata(xml: data))
    }
}
