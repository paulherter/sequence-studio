import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ProjectHoverScrubTests {
    /// An icon grid with one 10 s video item whose frames come from `posterAt` in slot 1, the poster in slot 0.
    func grid(defaults: UserDefaults? = nil) async throws -> (ProjectListView, MediaRef.ID, ShellHost, UserDefaults) {
        let (v, m, h, d) = ProjectPanelChromeTests().view(defaults: defaults)
        await m.importFiles([try ShellImportTests().file("scrub.mp4")])
        var p = m.project
        p.media[0].duration = Time(10, 1)
        p.media[0].info = MediaInfo(duration: Time(10, 1), video: VideoTrackInfo(
            width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false))
        m.setProject(p)
        let id = p.media[0].id
        v.poster = { _ in ProjectPoster(slot: 0, u0: 0, v0: 0, u1: 1, v1: 1, pixelSize: CGSize(width: 160, height: 100)) }
        v.posterAt = { _, _ in ProjectPoster(slot: 1, u0: 0, v0: 0, u1: 1, v1: 1, pixelSize: CGSize(width: 160, height: 100)) }
        v.setViewMode(.icons)
        return (v, id, h, d)
    }

    func imageSlots(_ v: ProjectListView) -> [UInt32] {
        var c = Canvas(width: 420, height: 400, atlas: GlyphAtlas(), scale: 1)
        v.draw(&c, theme: DrawTheme())
        return c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }.map { UInt32($0.pad) }
    }

    @Test func movingOverAVideoTilePicksTheFrameUnderThePointerAndDrawsIt() async throws {
        let (v, id, _, _) = try await grid()
        let i = try #require(v.gridItems().firstIndex(of: .media(id)))
        let r = v.thumbRect(i)
        _ = v.handle(.mouseMoved(x: Float(r.minX + r.width / 2), y: Float(r.midY)), scale: 1)
        let s = try #require(v.scrub)
        #expect(s.media == id)
        #expect(s.time == HoverScrub.time(fraction: 0.5, duration: Time(10, 1), frameDuration: Time(1, 25)))
        #expect(imageSlots(v) == [1])
        // Off the thumbnail: back to the poster.
        _ = v.handle(.mouseMoved(x: Float(r.minX + r.width / 2), y: Float(r.maxY + 2)), scale: 1)
        #expect(v.scrub == nil)
        #expect(imageSlots(v) == [0])
    }

    @Test func toggleSwitchesItOffKeepsTheSettingAndChecksTheMenu() async throws {
        let (v, id, h, d) = try await grid()
        #expect(v.hoverScrubOn)
        #expect(h.viewChecks().contains(.toggleHoverScrub))
        var line: String?
        h.onStatus = { line = $0 }
        #expect(h.performViewCommand(.toggleHoverScrub, defaults: d))
        #expect(!v.hoverScrubOn && line == "Hover Scrub off")
        #expect(AppSettings.load(from: d).hoverScrub == false)
        #expect(!h.viewChecks().contains(.toggleHoverScrub))
        let i = try #require(v.gridItems().firstIndex(of: .media(id)))
        let r = v.thumbRect(i)
        _ = v.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(v.scrub == nil)
        let (again, _, _, _) = try await grid(defaults: d)
        #expect(!again.hoverScrubOn)
    }

    @Test func holdingShiftScrubsWhileHoverScrubIsOff() async throws {
        let (v, id, _, _) = try await grid()
        v.setHoverScrub(false)
        var held: InputModifiers = []
        v.liveModifiers = { held }
        let i = try #require(v.gridItems().firstIndex(of: .media(id)))
        let r = v.thumbRect(i)
        _ = v.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(v.scrub == nil)
        held = .shift
        _ = v.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(v.scrub?.media == id)
        #expect(imageSlots(v) == [1])
        held = []
        _ = v.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(v.scrub == nil)
    }

    @Test func mediaRowsOfferTheirFilePathAsTip() async throws {
        let (v, id, h, _) = try await grid()
        v.setViewMode(.list)
        let path = try #require(h.projectModel?.project.media(id)?.path)
        let row = try #require(v.rows().firstIndex { $0.ref == .media(id) })
        #expect(v.itemTip(at: CGPoint(x: v.rowRect(row).midX, y: v.rowRect(row).midY)) == path)
        #expect(v.itemTip(at: CGPoint(x: v.rowRect(0).midX, y: v.rowRect(0).midY)) == nil)   // the sequence row
    }
}
