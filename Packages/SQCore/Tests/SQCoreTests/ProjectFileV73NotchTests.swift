import Foundation
import Testing
@testable import SQCore

// Notch gates the file at v73: an older build would play and export the clip with the tone still in.

@Suite struct ProjectFileV73NotchTests {
    private static func timeline(_ clips: [Clip], kind: TrackKind = .audio) throws -> Timeline {
        var t = Track(kind: kind)
        for c in clips { try t.overwrite(c) }
        return Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])
    }

    private static func audioClip(withNotch: Bool) throws -> Clip {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        if withNotch { try #require(c.addEffect(kind: ClipEffect.audioNotchKind) != nil) }
        return c
    }

    @Test func currentVersionIsAtLeast73() { #expect(ProjectFile.currentVersion >= 73) }

    @Test func clipWritesV73() throws {
        let p = Project(name: "P", timelines: [try Self.timeline([try Self.audioClip(withNotch: true)])])
        #expect(p.containsV73Content)
        #expect(ProjectFile.writtenVersion(for: p) == 73)
    }

    @Test func clipInANonActiveSequenceWritesV73() throws {
        let p = Project(name: "P", timelines: [try Self.timeline([]), try Self.timeline([try Self.audioClip(withNotch: true)])])
        #expect(ProjectFile.writtenVersion(for: p) == 73)
    }

    @Test func graphicsLayerWritesV73() throws {
        var layer = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
        layer.effects = [try #require(ClipEffect.make(kind: ClipEffect.audioNotchKind))]
        var g = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        g.graphics = GraphicsDocument(layers: [layer])
        let p = Project(name: "P", timelines: [try Self.timeline([g], kind: .video)])
        #expect(ProjectFile.writtenVersion(for: p) == 73)
    }

    @Test func fileWithoutNotchKeepsItsOldVersion() throws {
        let p = Project(name: "P", timelines: [try Self.timeline([try Self.audioClip(withNotch: false)])])
        #expect(!p.containsV73Content)
        #expect(ProjectFile.writtenVersion(for: p) < 73)
    }
}
