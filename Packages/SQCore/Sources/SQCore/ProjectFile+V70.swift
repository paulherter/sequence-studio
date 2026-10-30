import Foundation

// v70: audio channel routing (AudioChannelMap.swift): `AudioTrackInfo.channelMap`, written only when a media item does
// not play its file's own layout. A v69 build would play such an item with the file's layout and drop the key on the
// next save; at v70 it refuses the file with `ProjectFileError.newerVersion` instead. Projects without a chosen map
// store no key and keep the lowest version that holds their content. Files before v70 have no key: every item plays its
// file's layout, sample for sample as before.

//
// Also v70: the Pitch Shift and Disguise Voice audio effect kinds (F7.8). A v69 build does not know them and would play
// and export the clip without the effect, that is the voice undisguised (a privacy problem); at v70 it refuses the file.

extension ClipEffect {
    /// Effect kinds a v69 build does not know. Raw strings, so the gate does not depend on where the kind constants live.
    static let v70Kinds: Set<String> = ["audio.pitchShift", "audio.disguiseVoice"]

    var needsV70: Bool { Self.v70Kinds.contains(kind) }
}

extension Project {
    /// Any media item carries a chosen audio channel map, or a clip / graphics layer uses Pitch Shift or Disguise Voice
    /// (enabled or not): the file must be v70.
    public var containsV70Content: Bool {
        media.contains { $0.info?.audio?.channelMap != nil }
            || allClips().contains { c in
                c.effects.contains(where: \.needsV70)
                    || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV70) } ?? false)
            }
    }
}
