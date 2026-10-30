import Foundation
import SQCore

/// G1 Keystones in the user library: the built-ins plus the user's `.keystone` presets. A user preset with a built-in's id
/// is that built-in edited (its own curve, say) and replaces it in place; deleting the preset restores the built-in.
public enum KeystoneLibrary {
    /// Built-ins (in their order, overridden where saved) then the user's own, by name. Unreadable payloads are skipped.
    public static func keystones(from presets: [PresetItem]) -> [Keystone] {
        var saved: [UUID: Keystone] = [:]
        var own: [Keystone] = []
        for item in presets where item.kind == .keystone {
            guard var k = try? Keystone(payload: item.payload, version: item.payloadVersion) else { continue }
            k.id = item.id
            k.name = item.name
            if k.isBuiltIn { saved[k.id] = k } else { own.append(k) }
        }
        own.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // A hidden built-in (HiddenCatalog) is not listed, unless the user edited it: then it is theirs.
        return Keystone.builtIns.filter { saved[$0.id] != nil || !HiddenCatalog.isHidden(keystone: $0.id) }.map { saved[$0.id] ?? $0 } + own
    }

    /// One keystone by id: the user's own, a built-in with its saved changes, or the plain built-in, hidden or not. Never
    /// nil for a built-in id, so a reference that outlives the list entry (deleted changes of a hidden built-in) still resolves.
    public static func keystone(id: UUID, from presets: [PresetItem]) -> Keystone? {
        if let k = keystones(from: presets).first(where: { $0.id == id }) { return k }
        return Keystone.builtIns.first { $0.id == id }
    }

    /// A built-in that has a saved override.
    public static func isCustomised(_ id: UUID, in presets: [PresetItem]) -> Bool {
        presets.contains { $0.kind == .keystone && $0.id == id }
    }

    /// The preset that stores `keystone` (same id, so saving again updates it).
    public static func presetItem(for keystone: Keystone) throws -> PresetItem {
        PresetItem(id: keystone.id, kind: .keystone, name: keystone.name,
                   payload: try keystone.payload(), payloadVersion: keystone.writtenPayloadVersion)
    }
}
