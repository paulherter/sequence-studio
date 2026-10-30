import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import SQCore
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

// F7.3 review: a changed pixel aspect reaches the engines (they hold the shape with the opened media) and the
// thumbnails (poster, stills) of the Project panel.

private func video(tag: PixelAspect = .square) -> VideoTrackInfo {
    VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                   isVariableFrameRate: false, pixelAspect: tag)
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-par-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor @Suite struct PixelAspectSessionTests {
    @Test func changingThePixelAspectReopensTheMediaInTheEngine() {
        var p = EditorSession.makeUntitled()
        let a = MediaRef(name: "A.mov", path: "/nowhere/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                         info: MediaInfo(duration: Time(2, 1), video: video()))
        let b = MediaRef(name: "B.mov", path: "/nowhere/B.mov", fingerprint: MediaFingerprint(size: 2), duration: Time(2, 1),
                         info: MediaInfo(duration: Time(2, 1), video: video()))
        p.add(a); p.add(b)
        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine, autosaveStore: AutosaveStore(base: tempDir()))
        #expect(engine.changedMedia.isEmpty)

        session.perform("Set Pixel Aspect") { $0.setPixelAspect(PixelAspect(2, 1)!, for: a.id) }
        #expect(engine.changedMedia == [[a.id]])
        #expect(session.media.info(of: a.id)?.video?.displayWidth == 3840)       // what the engine reads on reopening
        _ = session.undo()
        #expect(engine.changedMedia == [[a.id], [a.id]])
        #expect(session.media.info(of: a.id)?.video?.displayWidth == 1920)
        // An edit that leaves the shape alone reopens nothing.
        session.perform("Rename") { $0.media[0].name = "C.mov" }
        #expect(engine.changedMedia.count == 2)
    }

    @Test func panelModelSetsThePixelAspectAsOneEdit() {
        var p = Project(name: "P")
        let a = MediaRef(name: "A.mov", path: "/nowhere/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                         info: MediaInfo(duration: Time(2, 1), video: video()))
        p.add(a)
        var names: [String] = []
        let m = ProjectPanelModel(project: p, probe: { _ in throw CocoaError(.fileReadUnknown) }, onEdit: { _, n in names.append(n) })
        #expect(m.setPixelAspect(PixelAspect(4, 3)!, for: [.media(a.id)]))
        #expect(m.project.media(a.id)?.info?.video?.displayWidth == 2560)
        #expect(names == ["Set Pixel Aspect"])
        #expect(!m.setPixelAspect(PixelAspect(4, 3)!, for: [.media(a.id)]))
        #expect(names.count == 1)
    }
}

@MainActor @Suite struct DeinterlaceSessionTests {
    private func media(_ name: String, _ order: FieldOrder?) -> MediaRef {
        var v = video(); v.fieldOrder = order
        return MediaRef(name: name, path: "/nowhere/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                        info: MediaInfo(duration: Time(2, 1), video: v))
    }

    @Test func changingDeinterlaceReopensTheMediaInTheEngine() {
        var p = EditorSession.makeUntitled()
        let a = media("A.mxf", .topFirst), b = media("B.mov", nil)
        p.add(a); p.add(b)
        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine, autosaveStore: AutosaveStore(base: tempDir()))
        session.perform("Set Deinterlace") { $0.setDeinterlace(false, for: a.id) }
        #expect(engine.changedMedia == [[a.id]])
        #expect(session.media.info(of: a.id)?.video?.deinterlaceFieldOrder == nil)   // what the engine reads on reopening
        _ = session.undo()
        #expect(engine.changedMedia == [[a.id], [a.id]])
        #expect(session.media.info(of: a.id)?.video?.deinterlaceFieldOrder == .topFirst)
    }

    @Test func panelOffersDeinterlaceForInterlacedMediaAsOneEdit() {
        var p = Project(name: "P")
        let a = media("A.mxf", .topFirst), b = media("B.mov", nil)
        p.add(a); p.add(b)
        var names: [String] = []
        let m = ProjectPanelModel(project: p, probe: { _ in throw CocoaError(.fileReadUnknown) }, onEdit: { _, n in names.append(n) })
        #expect(m.deinterlaceState([a.id]) == true)
        #expect(m.deinterlaceState([b.id]) == nil, "progressive media has no row")
        #expect(m.deinterlaceState([a.id, b.id]) == nil)
        #expect(m.setDeinterlace(false, for: [.media(a.id), .media(b.id)]))
        #expect(m.deinterlaceState([a.id]) == false)
        #expect(names == ["Set Deinterlace"])
        #expect(!m.setDeinterlace(false, for: [.media(a.id)]))
        #expect(names.count == 1)
    }

    @Test func menuShowsACheckedRowAfterPixelAspect() {
        var c = ProjectPanelMenus.Context(media: [UUID()], targetCount: 1, allMediaOnline: true,
                                          pixelAspect: PixelAspectMenu.State(files: [.square], overrides: [nil]))
        final class Picked { var actions: [ProjectPanelMenus.Action] = [] }
        let picked = Picked()
        func rows() -> [SQMenuItem] { ProjectPanelMenus.items(c, shortcut: { _ in "" }) { picked.actions.append($0) } }
        #expect(!rows().contains { $0.title == "Deinterlace" })
        c.deinterlace = true
        let r = rows()
        let i = try! #require(r.firstIndex { $0.title == "Deinterlace" })
        #expect(r[i - 1].title == "Pixel Aspect" && r[i + 1].title == "Reveal in Finder")
        #expect(r[i].isChecked)
        r[i].action?()
        #expect(picked.actions == [.setDeinterlace(false)])
        c.deinterlace = false
        #expect(rows().first { $0.title == "Deinterlace" }?.isChecked == false)
    }
}

@MainActor @Suite struct PixelAspectThumbnailTests {
    private func writePNG(_ w: Int, _ h: Int) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = tempDir().appendingPathComponent("still.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func poster(_ t: ProjectThumbnails, _ ref: MediaRef) async throws -> NSImage {
        for _ in 0..<400 {
            if let img = t.poster(for: ref) { return img }
            t.requestPoster(ref, height: 60) {}
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    @Test func stillPosterIsRemadeInTheChosenShape() async throws {
        let url = try writePNG(160, 120)
        var ref = MediaRef(name: "still.png", path: url.path, fingerprint: MediaFingerprint(size: 1), duration: Time(5, 1),
                           info: MediaInfo(duration: Time(5, 1), video: video(), isStill: true))
        let t = ProjectThumbnails(pressure: nil)
        let plain = try await poster(t, ref)
        #expect(plain.size.width * 3 == plain.size.height * 4)                  // 4:3 as stored
        ref.info?.video?.pixelAspectOverride = PixelAspect(2, 1)
        #expect(t.poster(for: ref) == nil)                                      // the square one is not shown any more
        let wide = try await poster(t, ref)
        #expect(wide.size.height == plain.size.height)
        #expect(wide.size.width == plain.size.width * 2)
        ref.info?.video?.pixelAspectOverride = nil
        #expect(t.poster(for: ref) == nil)
        #expect(try await poster(t, ref).size.width == plain.size.width)
    }

    @Test func clipFramesOfAnotherShapeAreNotReused() {
        let t = ProjectThumbnails(pressure: nil)
        var ref = MediaRef(name: "A.mov", path: "/nowhere/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                           info: MediaInfo(duration: Time(2, 1), video: video()))
        let img = NSImage(size: NSSize(width: 4, height: 4))
        t.storeFrameForTesting(ref.id, at: .zero, height: 10, img)
        t.storePosterForTesting(ref.id, img)
        #expect(t.cachedFrame(ref.id, at: .zero, height: 10) != nil)
        ref.info?.video?.pixelAspectOverride = PixelAspect(3, 2)
        t.requestFrame(ref, at: .zero, height: 10) {}
        #expect(t.cachedFrame(ref.id, at: .zero, height: 10) == nil)
        #expect(t.cachedPoster(ref.id) == nil)
    }
}
