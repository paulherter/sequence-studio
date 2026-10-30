import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@Suite("ProjectItemTint")
@MainActor
struct ProjectItemTintTests {
    private func media(_ name: String, video: Bool, audio: Bool) -> MediaRef {
        let v = video ? VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                       nominalFrameDuration: Time(1001, 30000), isVariableFrameRate: false) : nil
        let a = audio ? AudioTrackInfo(sampleRate: 48000, channels: 2, codec: "aac") : nil
        return MediaRef(name: name, path: "/x/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                        info: MediaInfo(duration: Time(10, 1), video: v, audio: a))
    }
    private func clip(_ m: MediaRef, _ kind: TrackKind) -> Clip {
        Clip(name: m.name, media: m.id, kind: kind, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
    }

    /// Real-shaped project: one item of every kind.
    private struct Fixture {
        var project: Project
        let video, both, audio, photo: MediaRef
        let inner, outer: Timeline
        let bin: Bin
        let nestedClip: Clip
        @MainActor var model: ProjectPanelModel { ProjectPanelModel(project: project, onEdit: { _, _ in }) }
    }
    private func fixture() -> Fixture {
        let video = media("v.mov", video: true, audio: false), both = media("b.mp4", video: true, audio: true)
        let audio = media("a.wav", video: false, audio: true)
        let photo = MediaRef(name: "p.jpg", path: "/x/p.jpg", fingerprint: MediaFingerprint(size: 1))
        let inner = Timeline(name: "Inner", frameDuration: Time(1, 30))
        let nested = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                          start: .zero, sequence: inner.id)
        let outer = Timeline(name: "Outer", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [nested])])
        let bin = Bin(name: "Folder")
        let project = Project(name: "P", media: [video, both, audio, photo], timelines: [inner, outer], rootBin: Bin(name: "Root", children: [.bin(bin)]))
        return Fixture(project: project, video: video, both: both, audio: audio, photo: photo, inner: inner, outer: outer, bin: bin, nestedClip: nested)
    }

    @Test func kindOfRealItems() {
        let f = fixture(), m = f.model
        #expect(m.itemKind(of: .media(f.video.id)) == .video)
        #expect(m.itemKind(of: .media(f.both.id)) == .videoAudio)
        #expect(m.itemKind(of: .media(f.audio.id)) == .audio)
        #expect(m.itemKind(of: .media(f.photo.id)) == .image)
        #expect(m.itemKind(of: .bin(f.bin.id)) == .bin)
        #expect(m.itemKind(of: .sequence(f.outer.id)) == .sequence)
        #expect(m.itemKind(of: .sequence(f.inner.id)) == .nestedSequence)
    }

    /// Panel color == the fill the timeline draws the item's clip in (ClipStyle.label(labelResolver.label(for:))).
    @Test func panelColoursEqualTimelineColours() {
        let f = fixture(), m = f.model, r = f.project.labelResolver
        func timelineFill(_ c: Clip) -> NSColor { ClipStyle.label(r.label(for: c)).fill }
        #expect(m.tints(of: .media(f.video.id)).map(\.fill) == [timelineFill(clip(f.video, .video))])
        #expect(m.tints(of: .media(f.audio.id)).map(\.fill) == [timelineFill(clip(f.audio, .audio))])
        #expect(m.tints(of: .media(f.both.id)).map(\.fill) == [timelineFill(clip(f.both, .video)), timelineFill(clip(f.both, .audio))])
        #expect(m.tints(of: .media(f.photo.id)).map(\.fill) == [timelineFill(clip(f.photo, .video))])
        #expect(m.tints(of: .sequence(f.inner.id)).map(\.fill) == [timelineFill(f.nestedClip)])
        // The tokens the timeline's type styles use are the same values.
        #expect(LabelColor.videoDefault.fill == Theme.Colors.clipVideo && LabelColor.audioDefault.fill == Theme.Colors.clipAudio)
        #expect(LabelColor.nestedDefault.fill == Theme.Colors.clipNest && LabelColor.textDefault.fill == Theme.Colors.clipTitle)
        #expect(LabelColor.binDefault.fill == Theme.Colors.clipFolder)
        #expect(m.tints(of: .media(f.video.id)) != m.tints(of: .media(f.photo.id)))
    }

    @Test func eachKindHasItsOwnSymbolAndColour() {
        let kinds: [ProjectItemKind] = [.video, .audio, .videoAudio, .image, .bin, .sequence, .nestedSequence, .text, .generator]
        #expect(Set(kinds.map { ProjectItemIcon.icon(for: $0) }).count == kinds.count)
        #expect(ProjectItemIcon.icon(for: .video).symbol == "film" && ProjectItemIcon.icon(for: .video).badge == nil)
        #expect(ProjectItemIcon.icon(for: .videoAudio).symbol == "film" && ProjectItemIcon.icon(for: .videoAudio).badge != nil)
        #expect(ProjectItemIcon.icon(for: .audio).symbol != "film")
        let colours: [ProjectItemKind] = [.video, .audio, .image, .bin, .nestedSequence, .text]
        #expect(Set(colours.map(\.defaultLabels)).count == colours.count)
    }

    /// The composed video+audio icon must actually show the picture glyph (top-left) and the sound badge (bottom-right).
    @Test func videoAudioIconDrawsFilmAndBadge() throws {
        let img = try #require(IconImages.image(.icon(for: .videoAudio), tints: ProjectItemKind.videoAudio.defaultLabels))
        let video = try #require(IconImages.image(.icon(for: .video), tints: ProjectItemKind.video.defaultLabels))
        #expect(img.size.width >= video.size.width && img.size.height >= video.size.height)
        let w = Int(img.size.width * 4), h = Int(img.size.height * 4)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        func opaque(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var n = 0
            for y in y0..<y1 { for x in x0..<x1 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { n += 1 } }
            return n
        }
        // Bitmap rep rows run top to bottom.
        #expect(opaque(0, 0, w / 2, h / 2) > 20, "film glyph visible top-left")
        #expect(opaque(w / 2, h / 2, w, h) > 10, "speaker badge visible bottom-right")
    }
}
