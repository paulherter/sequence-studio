import Foundation
import Testing
@testable import SQCore

// Pitch Shift and Disguise Voice gate the file at v70: an older build would play and export the voice undisguised.

@Suite struct ProjectFileV70VoiceTests {
    private static let kinds = [ClipEffect.audioPitchShiftKind, ClipEffect.audioDisguiseVoiceKind]

    private static func audioClip(_ kind: String) throws -> Clip {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        let id = c.addEffect(kind: kind)
        try #require(id != nil)
        return c
    }

    private static func timeline(_ clips: [Clip], kind: TrackKind = .audio) throws -> Timeline {
        var t = Track(kind: kind)
        for c in clips { try t.overwrite(c) }
        return Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])
    }

    @Test func clipWritesV70() throws {
        for kind in Self.kinds {
            let p = Project(name: "P", timelines: [try Self.timeline([try Self.audioClip(kind)])])
            #expect(p.containsV70Content)
            #expect(ProjectFile.writtenVersion(for: p) == 70)
        }
    }

    @Test func clipInANonActiveSequenceWritesV70() throws {
        for kind in Self.kinds {
            let plain = try Self.timeline([])
            let other = try Self.timeline([try Self.audioClip(kind)])
            let p = Project(name: "P", timelines: [plain, other])
            #expect(ProjectFile.writtenVersion(for: p) == 70)
        }
    }

    @Test func graphicsLayerWritesV70() throws {
        for kind in Self.kinds {
            var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
            layer.effects = [try #require(ClipEffect.make(kind: kind))]
            var g = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
            g.graphics = GraphicsDocument(layers: [layer])
            let p = Project(name: "P", timelines: [try Self.timeline([g], kind: .video)])
            #expect(p.containsV70Content)
            #expect(ProjectFile.writtenVersion(for: p) == 70)
        }
    }

    @Test func plainAudioClipStaysBelowV70() throws {
        let c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        let p = Project(name: "P", timelines: [try Self.timeline([c])])
        #expect(ProjectFile.writtenVersion(for: p) < 70)
    }
}
