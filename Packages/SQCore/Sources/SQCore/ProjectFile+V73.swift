import Foundation

// v73: the Notch audio effect kind. A v72 build does not know it and would play and export the clip with the unwanted
// tone still in (hum, whistle); at v73 it refuses the file with `ProjectFileError.newerVersion` instead. Projects
// without a Notch keep the lowest version that holds their content.

extension ClipEffect {
    /// Effect kinds a v72 build does not know. Raw strings, so the gate does not depend on where the kind constants live.
    static let v73Kinds: Set<String> = ["audio.notch"]

    var needsV73: Bool { Self.v73Kinds.contains(kind) }
}

extension Project {
    /// A clip or graphics layer uses Notch (enabled or not): the file must be v73.
    public var containsV73Content: Bool {
        allClips().contains { c in
            c.effects.contains(where: \.needsV73)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV73) } ?? false)
        }
    }
}
