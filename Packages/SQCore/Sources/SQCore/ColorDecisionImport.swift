import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One ASC color decision: out = (in * slope + offset)^power, then saturation (Rec.709 luma weights).
public struct ColorDecision: Sendable, Hashable {
    /// The `ColorCorrection` id, the EDL clip name, or the EDL event number.
    public var id: String
    public var slope = ColorTriple(all: 1)
    public var offset = ColorTriple(all: 0)
    public var power = ColorTriple(all: 1)
    public var saturation: Float = 1
    public init(id: String) { self.id = id }

    /// The decision as Step primaries (lift 0, contrast 1: the same maths), clamped to the Step ranges: a negative
    /// slope becomes 0, a power of 0 or below the smallest exponent, huge values the range ends.
    public var primaries: StepPrimaries {
        func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        func clamp(_ t: ColorTriple, _ r: ClosedRange<Float>) -> ColorTriple { ColorTriple(clamp(t.r, r), clamp(t.g, r), clamp(t.b, r)) }
        var p = StepPrimaries()
        p.gain = clamp(slope, StepPrimaries.gainRange)
        p.offset = clamp(offset, StepPrimaries.offsetRange)
        p.gamma = clamp(power, StepPrimaries.gammaRange)
        p.saturation = clamp(saturation, StepPrimaries.saturationRange)
        return p
    }
}

/// Reads ASC CDL files: `.cdl` (ColorDecisionList), `.cc` (one ColorCorrection), `.ccc` (ColorCorrectionCollection) and
/// the `*ASC_SOP` / `*ASC_SAT` comments of a CMX `.edl`.
public enum ColorDecisionImport {
    public enum ImportError: Error, Equatable {
        /// The file holds no color decision.
        case noDecisions
        /// A Slope / Offset / Power / Saturation value is not a number (or not three numbers).
        case badValue(String)
    }

    public static let fileExtensions: Set<String> = ["cdl", "cc", "ccc", "edl"]

    public static func parse(_ data: Data, fileExtension ext: String) throws -> [ColorDecision] {
        let out = ext.lowercased() == "edl" ? try parseEDL(String(decoding: data, as: UTF8.self)) : try parseXML(data)
        guard !out.isEmpty else { throw ImportError.noDecisions }
        return out
    }

    // MARK: XML (.cdl / .cc / .ccc)

    private final class Reader: NSObject, XMLParserDelegate {
        var out: [ColorDecision] = []
        var error: ImportError?
        private var current: ColorDecision?
        private var text = ""
        private var count = 0

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if local(name) == "ColorCorrection" {
                count += 1
                current = ColorDecision(id: attributes["id"] ?? "\(count)")
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard current != nil else { return }
            do {
                switch local(name) {
                case "Slope": current?.slope = try triple(text, name)
                case "Offset": current?.offset = try triple(text, name)
                case "Power": current?.power = try triple(text, name)
                case "Saturation": current?.saturation = try number(text, name)
                case "ColorCorrection": if let c = current { out.append(c) }; current = nil
                default: break
                }
            } catch let e as ImportError {
                if error == nil { error = e }
                p.abortParsing()
            } catch {}
            text = ""
        }

        private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }
    }

    private static func parseXML(_ data: Data) throws -> [ColorDecision] {
        let p = XMLParser(data: data)
        let r = Reader()
        p.delegate = r
        _ = p.parse()
        if let e = r.error { throw e }
        return r.out
    }

    // MARK: EDL comments

    private static func parseEDL(_ s: String) throws -> [ColorDecision] {
        var out: [ColorDecision] = []
        var event: ColorDecision?
        var hasCDL = false
        func close() { if let e = event, hasCDL { out.append(e) }; event = nil; hasCDL = false }
        for raw in s.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let first = line.split(separator: " ").first, first.allSatisfy(\.isNumber) {
                close()
                event = ColorDecision(id: String(first))
            } else if event != nil, line.hasPrefix("*") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if body.uppercased().hasPrefix("FROM CLIP NAME:") {
                    let name = body.dropFirst("FROM CLIP NAME:".count).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { event?.id = name }
                } else if body.hasPrefix("ASC_SOP") {
                    let groups = body.dropFirst(7).split(separator: "(").map { $0.replacingOccurrences(of: ")", with: "") }
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    guard groups.count == 3 else { throw ImportError.badValue("ASC_SOP") }
                    event?.slope = try triple(groups[0], "ASC_SOP")
                    event?.offset = try triple(groups[1], "ASC_SOP")
                    event?.power = try triple(groups[2], "ASC_SOP")
                    hasCDL = true
                } else if body.hasPrefix("ASC_SAT") {
                    event?.saturation = try number(String(body.dropFirst(7)), "ASC_SAT")
                    hasCDL = true
                }
            }
        }
        close()
        return out
    }

    // MARK: Numbers

    static func number(_ s: String, _ what: String) throws -> Float {
        guard let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite else { throw ImportError.badValue(what) }
        return v
    }

    static func triple(_ s: String, _ what: String) throws -> ColorTriple {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
        guard parts.count == 3 else { throw ImportError.badValue(what) }
        let v = try parts.map { try number(String($0), what) }
        return ColorTriple(v[0], v[1], v[2])
    }
}
