import Foundation
import SQCore

/// A saved title template in the Library (TEMPLATE-ECOSYSTEM T3): the SQCore `TitleTemplate` (layers, slots, animation
/// zones) plus a small PNG thumbnail, stored as the payload of a `.titleTemplate` preset. Own payload version; the
/// template itself carries its own `formatVersion`. Applying copies the template into the project (`Project.applyTitleTemplate`),
/// so nothing of the library entry goes into a project file.
public struct TitleTemplatePreset: Sendable, Equatable {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for `.titleTemplate` presets).
    public static let payloadVersion = 1

    public enum PayloadError: Error, Equatable {
        case newerVersion(found: Int, supported: Int)
        case damaged
    }

    public var template: TitleTemplate
    /// PNG bytes of the Library thumbnail (nil: the row shows an icon).
    public var thumbnail: Data?

    public init(template: TitleTemplate, thumbnail: Data? = nil) {
        self.template = template
        self.thumbnail = thumbnail
    }

    private struct Payload: Codable {
        var template: TitleTemplate
        var thumbnail: Data?
    }

    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion) }
        do {
            let p = try JSONDecoder().decode(Payload.self, from: payload)
            guard !p.template.content.tracks.isEmpty else { throw PayloadError.damaged }
            self.init(template: p.template, thumbnail: p.thumbnail)
        } catch let TitleTemplateError.newerFormat(found, supported) {
            throw PayloadError.newerVersion(found: found, supported: supported)
        } catch let e as PayloadError {
            throw e
        } catch {
            throw PayloadError.damaged
        }
    }

    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(Payload(template: template, thumbnail: thumbnail))
    }

    /// The preset to store; `name` also becomes the template's own name.
    public func presetItem(name: String) throws -> PresetItem {
        var copy = self
        copy.template.name = name
        return PresetItem(kind: .titleTemplate, name: name, payload: try copy.payload(), payloadVersion: Self.payloadVersion)
    }

    /// The names title templates already use in `items` (presets of other kinds may share a name with a template).
    public static func names(in items: [PresetItem]) -> Set<String> {
        Set(items.lazy.filter { $0.kind == .titleTemplate }.map(\.name))
    }

    public init(preset: PresetItem) throws {
        guard preset.kind == .titleTemplate else { throw PayloadError.damaged }
        try self.init(payload: preset.payload, version: preset.payloadVersion)
    }
}
