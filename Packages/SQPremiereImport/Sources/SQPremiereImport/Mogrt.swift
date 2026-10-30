import Foundation
import SQCore

// Motion Graphics Templates (.mogrt), docs/ENGINE-NOTES.md "Motion Graphics Templates (.mogrt)". The package is a ZIP:
// definition.json (name, authoring app, exposed controls, frame size, duration, fonts), thumb.png, and the graphic itself:
// project.prgraphic (authored in Premiere: a ZIP around one ordinary gzip project with one sequence) or
// project.aegraphic (authored in After Effects: a ZIP around an .aep composition, which only After Effects can render).
// A Premiere-authored template therefore runs through the same reader and mapper as a project import (`PRReader`,
// `PRMapper`), and the mapped sequence becomes a `TitleTemplate` (`TitleTemplate.capture`), the Library's own format.

public enum MogrtImportError: Error, Equatable, Sendable, LocalizedError {
    /// Not a ZIP, or no definition inside.
    case notATemplate
    /// Authored in After Effects: the layers live in an .aep composition this app cannot render.
    case needsAfterEffects(name: String)
    /// The definition is there, the graphic is not.
    case missingGraphic(name: String)
    /// The package or the project inside is damaged.
    case unreadable(name: String)
    /// Nothing of the template has a counterpart (no text layer); `dropped` counts what was left out.
    case nothingImportable(name: String, dropped: Int)

    public var errorDescription: String? {
        switch self {
        case .notATemplate:
            "This file is not a Motion Graphics Template (.mogrt)."
        case .needsAfterEffects(let name):
            "“\(name)” was made in After Effects. It needs After Effects to render and cannot be imported yet. "
                + "Templates made with a video editor's own text and shape tools can be imported."
        case .missingGraphic(let name):
            "“\(name)” contains no graphic to import."
        case .unreadable(let name):
            "“\(name)” is damaged and could not be read."
        case .nothingImportable(let name, let dropped):
            "“\(name)” has no text layer that can be imported"
                + (dropped > 0 ? " (\(dropped) unsupported \(dropped == 1 ? "item" : "items") left out)." : ".")
        }
    }
}

/// One control the template exposes for editing (`clientControls` of the definition).
public struct MogrtControl: Sendable, Equatable {
    /// Type codes seen in real definitions: 1 checkbox, 2 slider, 3 angle, 4 color, 5 point, 6 text, 9 vector (scale),
    /// 13 menu. Anything else keeps its code.
    public enum Kind: Sendable, Equatable {
        case checkbox, slider, angle, color, point, text, vector, menu
        case other(Int)

        init(code: Int) {
            switch code {
            case 1: self = .checkbox
            case 2: self = .slider
            case 3: self = .angle
            case 4: self = .color
            case 5: self = .point
            case 6: self = .text
            case 9: self = .vector
            case 13: self = .menu
            default: self = .other(code)
            }
        }

        public var label: String {
            switch self {
            case .checkbox: "checkbox"
            case .slider: "slider"
            case .angle: "angle"
            case .color: "color"
            case .point: "point"
            case .text: "text"
            case .vector: "scale"
            case .menu: "menu"
            case .other(let code): "type \(code)"
            }
        }
    }

    public enum Value: Sendable, Equatable {
        case text(String)
        case bool(Bool)
        case number(Double)
        case color(red: Double, green: Double, blue: Double, alpha: Double)
        case point(x: Double, y: Double)
        case vector([Double])
        case menu(index: Int, items: [String])
        case none
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var value: Value
    /// Text controls: the font and size the definition records (empty / 0 in Premiere-authored templates).
    public var fontName: String?
    public var fontSize: Double?
}

/// What definition.json says about the template.
public struct MogrtDefinition: Sendable, Equatable {
    public enum Author: Sendable, Equatable {
        case premiere, afterEffects
        case unknown(String)
    }

    public var name: String
    public var author: Author
    public var width: Int?
    public var height: Int?
    public var duration: Time?
    /// PostScript names of the fonts the template uses.
    public var fonts: [String]
    public var controls: [MogrtControl]

    /// Parses definition.json; nil when it is not a JSON object.
    public static func parse(_ data: Data) -> MogrtDefinition? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let authorApp = root["authorApp"] as? String ?? ""
        let author: Author = switch authorApp { case "ppro": .premiere; case "aefx": .afterEffects; default: .unknown(authorApp) }
        let info = localized(root["sourceInfoLocalized"]) as? [String: Any]
        let size = (info?["framesize"] as? [String: Any])?["size"] as? [String: Any]
        var duration: Time?
        if let d = info?["duration"] as? [String: Any], let v = number(d["value"]), let s = number(d["scale"]),
           v >= 0, s >= 1, v == v.rounded(), s == s.rounded(), v < 1e15, s < 1e15 {
            duration = Time(Int64(v), Int64(s))
        }
        let controls = (root["clientControls"] as? [[String: Any]] ?? []).map(control)
        return MogrtDefinition(name: string(root["capsuleNameLocalized"]) ?? root["capsuleName"] as? String ?? "",
                               author: author, width: int(size?["x"], in: 1...maxFrameSide), height: int(size?["y"], in: 1...maxFrameSide),
                               duration: duration, fonts: localized(root["usedFontsLocalized"]) as? [String] ?? [], controls: controls)
    }

    /// The en_US entry of a per-locale dictionary, else its first by key.
    private static func localized(_ any: Any?) -> Any? {
        guard let d = any as? [String: Any] else { return nil }
        return d["en_US"] ?? d.keys.sorted().first.flatMap { d[$0] }
    }

    /// A localized string table (`{"strDB":[{"localeString":"en_US","str":"..."}]}`): en_US, else the first entry.
    private static func string(_ any: Any?) -> String? {
        guard let db = (any as? [String: Any])?["strDB"] as? [[String: Any]], !db.isEmpty else { return nil }
        return (db.first { $0["localeString"] as? String == "en_US" } ?? db[0])["str"] as? String
    }

    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// Frame sides above this are not a frame size.
    static let maxFrameSide = 65_536

    /// A whole-number reading inside `range`; anything else (1e300, a fraction far out of range) is nil, never a trap.
    private static func int(_ any: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let d = number(any), d >= Double(range.lowerBound), d <= Double(range.upperBound) else { return nil }
        return Int(d)
    }

    private static func control(_ c: [String: Any]) -> MogrtControl {
        let kind = MogrtControl.Kind(code: (c["type"] as? NSNumber)?.intValue ?? -1)
        let raw = c["value"]
        let numbers = (raw as? [Any])?.compactMap(number) ?? []
        let value: MogrtControl.Value
        switch kind {
        case .text: value = string(raw).map { .text($0) } ?? .none
        case .checkbox: value = (raw as? NSNumber).map { .bool($0.boolValue) } ?? .none
        case .slider, .angle: value = number(raw).map { .number($0) } ?? .none
        case .color: value = numbers.count >= 3 ? .color(red: numbers[0], green: numbers[1], blue: numbers[2], alpha: numbers.count > 3 ? numbers[3] : 1) : .none
        case .point:
            let p = raw as? [String: Any]
            if let x = number(p?["x"]), let y = number(p?["y"]) { value = .point(x: x, y: y) } else { value = .none }
        case .vector: value = numbers.isEmpty ? .none : .vector(numbers)
        case .menu:
            let items = (c["menucontent"] as? [Any] ?? []).map { string($0) ?? "" }
            value = int(raw, in: 0...1_000_000).map { .menu(index: $0, items: items) } ?? .none
        case .other: value = .none
        }
        let font = c["fonteditinfo"] as? [String: Any]
        let fontName = (font?["fontEditValue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fontSize = number(font?["fontSizeEditValue"]).flatMap { $0 > 0 ? $0 : nil }
        let id = c["id"] as? String ?? (c["id"] as? NSNumber)?.stringValue ?? ""
        return MogrtControl(id: id, name: string(c["uiName"]) ?? "", kind: kind, value: value, fontName: fontName, fontSize: fontSize)
    }
}

/// A text layer of the template's graphic as it was authored (before mapping).
public struct MogrtTextLayer: Sendable, Equatable {
    public var text: String
    public var fontName: String?
    public var size: Double?
    /// Fill, 0...1 per channel; nil when the layer records none.
    public var color: PRText.RGB?
    /// 0 left, 1 right, 2 center (the text blob's own code); nil when not recorded.
    public var alignment: Int?
    /// Layer position as 0...1 of the frame; nil when not recorded.
    public var position: Vec2?
}

/// The template as the package describes it: definition plus the layers of its graphic.
public struct MogrtDescription: Sendable, Equatable {
    public var definition: MogrtDefinition
    public var textLayers: [MogrtTextLayer]
    /// Shape layers of the graphic. Rectangles, ellipses and straight polygons become Graphics layers; pen paths with
    /// curves are dropped and listed in the report.
    public var shapeLayerCount: Int
}

public struct MogrtImportResult: Sendable {
    /// The template in the Library's own format: text layers as editable slots, named after the template's controls.
    public var template: TitleTemplate
    /// thumb.png of the package (PNG bytes), for the Library row.
    public var thumbnail: Data?
    public var description: MogrtDescription
    /// Mapped / approximated / dropped, per feature (the project mapper's notes plus the template's own).
    public var report: PRImportReport
    /// Everything that was left out, summed.
    public var droppedCount: Int { report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count } }
}

public enum MogrtImporter {
    public static let fileExtension = "mogrt"
    /// Thumbnails above this are not carried into the Library payload.
    static let maxThumbnailSize = 2 << 20

    public static func read(url: URL) throws -> MogrtImportResult {
        try read(data: Data(contentsOf: url, options: .mappedIfSafe), fileName: url.deletingPathExtension().lastPathComponent)
    }

    /// `fileName` names the template when its definition has no name.
    public static func read(data: Data, fileName: String) throws -> MogrtImportResult {
        guard let zip = try? PRZip(data), let defData = try? zip.data("definition.json"),
              var definition = MogrtDefinition.parse(defData) else { throw MogrtImportError.notATemplate }
        if definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { definition.name = fileName }
        let name = definition.name
        if definition.author == .afterEffects || zip.entry("project.aegraphic") != nil {
            throw MogrtImportError.needsAfterEffects(name: name)
        }
        guard zip.entry("project.prgraphic") != nil else { throw MogrtImportError.missingGraphic(name: name) }
        let doc: PRDocument
        let projectFile: Data?
        do {
            guard let graphic = try zip.data("project.prgraphic") else { throw PRImportError.corruptArchive }
            projectFile = try projectData(graphic)
        } catch {
            throw MogrtImportError.unreadable(name: name)
        }
        guard let projectFile else { throw MogrtImportError.missingGraphic(name: name) }
        do {
            doc = try PRReader.read(data: projectFile)
        } catch {
            throw MogrtImportError.unreadable(name: name)
        }

        let items = doc.sequences.flatMap { s in s.videoTracks.flatMap(\.items) }
        let textLayers = items.flatMap { Mapping.textLayers($0) }.map { text, comp in
            MogrtTextLayer(text: text.text, fontName: text.fontName, size: text.size, color: text.fill, alignment: text.alignment,
                           position: PRParamValue.point(comp.param(3)?.staticValue))
        }
        let shapeCount = items.reduce(0) { $0 + $1.components(shapeMatchName).count }
        let description = MogrtDescription(definition: definition, textLayers: textLayers, shapeLayerCount: shapeCount)

        // Shape layers become Graphics layers; the ones the model cannot draw (pen paths) come back as dropped "Shape layer" notes.
        let mapped = PRMapper.map(doc, name: name, shapes: true)
        var report = mapped.report

        let project = mapped.project
        let timeline = project.activeTimeline.flatMap(project.timeline) ?? project.timelines.first
        var layerIDs: [Clip.ID] = []
        for track in timeline?.tracks ?? [] {
            for clip in track.clips {
                if track.kind != .video {
                    report.note("Audio", .dropped, "a template carries picture only")
                } else if clip.generator == nil {
                    report.note("Embedded media", .dropped, "\(clip.name): footage and nested sequences of a template are not imported")
                } else {
                    layerIDs.append(clip.id)
                }
            }
        }
        var dropped: Int { report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count } }
        guard let timeline, !layerIDs.isEmpty,
              var template = try? TitleTemplate.capture(clips: layerIDs, in: timeline.id, of: project, name: name),
              !template.slots.isEmpty else {
            for c in definition.controls { report.note(controlFeature(c), .dropped, "no layer to edit") }
            throw MogrtImportError.nothingImportable(name: name, dropped: dropped)
        }

        // Text slots take the name of the text control with the same default string; every other control has no
        // counterpart and is reported.
        var open = definition.controls
        for i in template.slots.indices {
            guard case let .text(s) = template.slots[i].value,
                  let c = open.firstIndex(where: { $0.kind == .text && $0.value == .text(s) }) else { continue }
            let label = open[c].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { template.slots[i].name = label }
            open.remove(at: c)
        }
        for c in open {
            report.note(controlFeature(c), .dropped, c.kind == .text ? "no text layer with this text" : "no editable counterpart yet")
        }

        let thumb = (try? zip.data("thumb.png")).flatMap { $0 }.flatMap { $0.count <= maxThumbnailSize ? $0 : nil }
        return MogrtImportResult(template: template, thumbnail: thumb, description: description, report: report)
    }

    static let shapeMatchName = "AE.ADBE Shape"

    static func controlFeature(_ c: MogrtControl) -> String { "Control “\(c.name)” (\(c.kind.label))" }

    /// project.prgraphic is a ZIP around one project file; a bare (gzip or plain XML) project is taken as it is.
    /// nil: the archive holds no project (only folders or empty files). Throws for a damaged archive.
    static func projectData(_ graphic: Data) throws -> Data? {
        guard !graphic.isEmpty else { return nil }
        guard graphic.starts(with: [0x50, 0x4b]) else { return graphic }
        let inner = try PRZip(graphic)
        // Folder entries and empty files are no project, whatever they are called.
        let files = inner.entries.filter { !$0.name.hasSuffix("/") && !$0.name.hasSuffix("\\") && $0.uncompressedSize > 0 }
        guard let entry = files.first(where: { $0.name.lowercased().hasSuffix(".prproj") }) ?? files.first else { return nil }
        return try inner.data(entry)
    }
}
