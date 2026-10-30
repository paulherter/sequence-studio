import Foundation
import SQCore

/// A saved choice of stems to export (which audio roles, M&E mix included), by `StemPlan.Stem.id`. Stored by the host
/// in a JSON file in Application Support (`StemPresetStore`); not part of a project.
public struct StemPreset: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Stem ids (`dialogue`, `music`, `sfx`, `other`, `me`).
    public var stemIDs: [String]
    public var format: AudioFileFormat

    public init(id: UUID = UUID(), name: String, stemIDs: [String], format: AudioFileFormat = .wav) {
        self.id = id; self.name = name; self.stemIDs = stemIDs; self.format = format
    }

    /// The stems of `plan` this preset names, in plan order; ids the sequence lacks are skipped.
    public func select(from plan: [StemPlan.Stem]) -> [StemPlan.Stem] {
        plan.filter { stemIDs.contains($0.id) }
    }

    /// Built-in choices, never stored: every stem, the role stems without the M&E mix, and the M&E mix alone.
    public static func builtIn(for plan: [StemPlan.Stem]) -> [StemPreset] {
        let roles = plan.map(\.id).filter { $0 != "me" }
        var out = [StemPreset(id: Self.allID, name: "All roles", stemIDs: plan.map(\.id))]
        if plan.contains(where: { $0.id == "me" }) {
            out.append(StemPreset(id: Self.rolesID, name: "Roles only", stemIDs: roles))
            out.append(StemPreset(id: Self.meID, name: "Music and Effects only", stemIDs: ["me"]))
        }
        return out
    }
    static let allID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let rolesID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let meID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    /// A name for a selection: the stem titles joined, e.g. "Dialogue + Music".
    public static func autoName(ids: [String], plan: [StemPlan.Stem]) -> String {
        let titles = plan.filter { ids.contains($0.id) }.map(\.title)
        return titles.isEmpty ? "Stems" : titles.joined(separator: " + ")
    }

    /// Estimated total bytes of `count` stem files of `duration` in `format` with `audio` settings.
    public static func estimatedBytes(count: Int, duration: Time, format: AudioFileFormat, audio: AudioSettings) -> Int64 {
        var s = ExportSettings()
        s.audio = audio; s.audio.enabled = true; s.audio.codec = format.codec; s.audio.loudness = nil
        s.audioOnly = format
        return s.estimatedFileSize(duration: duration) * Int64(max(count, 0))
    }
}

/// The user's saved stem presets as a JSON file. A missing or damaged file reads as empty.
public struct StemPresetStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [StemPreset] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StemPreset].self, from: d)) ?? []
    }

    /// Adds the preset, or replaces the one with the same name (case-insensitive), then writes the file.
    @discardableResult
    public func save(_ preset: StemPreset) throws -> [StemPreset] {
        var all = load()
        if let i = all.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) {
            var p = preset; p.id = all[i].id; all[i] = p
        } else { all.append(preset) }
        try write(all)
        return all
    }

    @discardableResult
    public func delete(id: UUID) throws -> [StemPreset] {
        let all = load().filter { $0.id != id }
        try write(all)
        return all
    }

    private func write(_ all: [StemPreset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}
