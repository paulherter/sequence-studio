import Foundation
import Testing
@testable import SQCore

/// Consolidation step 8: the built-in effect-stack presets (motion, keying, film looks, Voice) must apply exactly the
/// effects they applied before they shared one type. The fingerprints below were taken from the pre-merge apply paths
/// (`Clip.applyPreset(BuiltInMotionPreset.preset)` and `Clip.addPreset(FilmPreset)`) on a 3 s clip.
@Suite struct EffectStackPresetTests {
    static func clip(_ kind: TrackKind) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
    }

    /// The applied effect list as sorted JSON with every UUID blanked, hashed (FNV-1a 64).
    static func fingerprint(_ effects: [ClipEffect]) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var s = String(decoding: try e.encode(effects), as: UTF8.self)
        s = s.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                   with: "ID", options: .regularExpression)
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// Applies built-in `id` to a fresh clip of its track kind through the one apply path.
    static func applied(_ id: String) throws -> [ClipEffect] {
        let p = try #require(EffectStackPresets.preset(id: id))
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: p.trackKind, clips: [clip(p.trackKind)])])
        let c = t.tracks[0].clips[0].id
        try t.applyPreset(p.preset, to: [c])
        return t.tracks[0].clips[0].effects
    }

    static let ids: [String] = [
        "moveFromLeft", "moveFromRight", "moveFromTop", "moveFromBottom", "moveToLeft", "moveToRight", "moveToTop", "moveToBottom",
        "popIn", "slideIn", "whipIn", "bounceIn", "spinIn", "elasticIn", "drift", "captionPop", "pop50", "slideInOvershoot",
        "zoomInOut", "zoomOutIn", "punchIn", "cameraShake", "rgbSplitHit", "pop0120100", "whipBlurIn", "whipBlurOut",
        "rgbGlitch", "ghostFrame", "greenScreen", "blueScreen", "preset.filmLook", "preset.vhs", "preset.badTV",
        "audio.preset.voice",
    ]

    static let expected: [String: String] = [
        "moveFromLeft": "74b66b0306ea111f",
        "moveFromRight": "8be51bfe7efb23e6",
        "moveFromTop": "b7b60c67f8aabe9c",
        "moveFromBottom": "4e407a031306d7cd",
        "moveToLeft": "e7e54d831bd6d29b",
        "moveToRight": "a1c35117f29d92a4",
        "moveToTop": "6a1cb76406d21c9c",
        "moveToBottom": "a724ff212e35cd",
        "popIn": "d94f6df8862149c2",
        "slideIn": "c6d5a7a9b284e1f2",
        "whipIn": "b21beae0de828d18",
        "bounceIn": "6d67de311191ac2c",
        "spinIn": "96190144a96b4a7c",
        "elasticIn": "69bf8168cf0670ad",
        "drift": "41dd7943844ed9bc",
        "captionPop": "b7bccdb88901d691",
        "pop50": "4df7d1bfd8002de4",
        "slideInOvershoot": "11a88cc692baec6c",
        "zoomInOut": "2ef7c53832c0d717",
        "zoomOutIn": "42f31a7e0148a6b7",
        "punchIn": "9df4870ae413b760",
        "cameraShake": "9fae4ad8cc8bc9fd",
        "rgbSplitHit": "e6262478a4cc9d9b",
        "pop0120100": "a54e0b8a5c4c61f4",
        "whipBlurIn": "6d19aafd3825a6d7",
        "whipBlurOut": "ce78f7320648f4cb",
        "rgbGlitch": "64b07ad22246d446",
        "ghostFrame": "d5f3b246bc115f7e",
        "greenScreen": "e549ae107b87b905",
        "blueScreen": "ab4120918aab56c4",
        "preset.filmLook": "429fe594265b7762",
        "preset.vhs": "9775e595a6f9fe7f",
        "preset.badTV": "9e875e1215982105",
        "audio.preset.voice": "8556d0017beffbc3",
    ]

    @Test func everyBuiltInAppliesTheSameEffectsAsBefore() throws {
        var got: [String: String] = [:]
        for id in Self.ids { got[id] = try Self.fingerprint(Self.applied(id)) }
        let table = Self.ids.map { "\"\($0)\": \"\(got[$0]!)\"," }.joined(separator: "\n")
        #expect(got == Self.expected, "fingerprints:\n\(table)")
    }

    @Test func applyingTwiceGivesFreshIDs() throws {
        let a = try Self.applied("preset.vhs"), b = try Self.applied("preset.vhs")
        #expect(Set(a.map(\.id)).isDisjoint(with: b.map(\.id)))
    }
}
