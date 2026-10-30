import Foundation

// v92: Motion's Anti-flicker Filter (`ClipAnimation.antiFlicker`, 0...1). A v91 build would drop it on the next save; at v92 it
// refuses the file with `ProjectFileError.newerVersion` instead. Files without one keep the lowest version that holds their
// content (byte-identical). Identity step: the key is optional on decode.

extension Project {
    /// Any clip has the Anti-flicker Filter above 0 or keyed: the file must be v92.
    public var containsV92Content: Bool { allClips().contains { $0.animation.isAntiFlickerSetOrKeyed } }
}
