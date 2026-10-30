import Foundation

/// A preset drag is handled like an effect drag inside the timeline (same clip-target highlight), under an id with a
/// prefix no effect kind uses; `performDragOperation` hands it to `onDropPreset` instead of `onDropEffect`.
public enum PresetDrop {
    static let prefix = "preset:"

    public static func effectID(for id: UUID) -> String { prefix + id.uuidString }

    public static func presetID(fromEffectID s: String) -> UUID? {
        s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil
    }
}
