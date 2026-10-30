import Foundation
import SQCore

/// A saved title block: the generator clips of a selection (text, shapes, adjustment layers) with their element
/// transitions and relative offsets and lanes, stored as the payload of a `.titleBlock` preset. Own payload version;
/// nothing of it goes into the project file (placing it copies the clips into the sequence).
public struct TitleBlock: Sendable, Equatable {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for `.titleBlock` presets).
    public static let payloadVersion = 1

    public enum PayloadError: Error, Equatable {
        case newerVersion(found: Int, supported: Int)
        case damaged
    }

    public var block: TimelineClipboard

    /// nil when the block is empty or holds anything with media.
    public init?(block: TimelineClipboard) {
        guard !block.isEmpty, block.entries.allSatisfy({ $0.clip.generator != nil && $0.clip.sequence == nil && $0.clip.kind == .video }) else {
            return nil
        }
        self.block = block
    }

    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion) }
        guard let decoded = try? JSONDecoder().decode(TimelineClipboard.self, from: payload), let ok = Self(block: decoded) else {
            throw PayloadError.damaged
        }
        self = ok
    }

    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(block)
    }

    public func presetItem(name: String) throws -> PresetItem {
        PresetItem(kind: .titleBlock, name: name, payload: try payload(), payloadVersion: Self.payloadVersion)
    }

    public init(preset: PresetItem) throws {
        guard preset.kind == .titleBlock else { throw PayloadError.damaged }
        try self.init(payload: preset.payload, version: preset.payloadVersion)
    }

    /// Number of clips (for a subtitle in the Library).
    public var clipCount: Int { block.entries.count }
}
