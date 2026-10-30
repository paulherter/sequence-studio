import Foundation
@testable import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQDrawMonitor
import SQUIKit
import Testing

/// A segmenter that answers Mask Tint with a set picture and records what was asked.
@MainActor
private final class TintStub: AppMagicMasks {
    var asked: [(masks: [ClipMask.ID], pts: Double)] = []
    var answer = MaskTintPicture()
    var hovers: [(Vec2?, Clip.ID?)] = []
    var hasHover = false
    func hover(_ p: Vec2?, target: Clip.ID?) { hovers.append((p, target)) }
    func click(_ p: Vec2, target: Clip.ID?, subtract: Bool, newMask: Bool) {}
    func refresh(target: Clip.ID?, magicOn: Bool, isPlaying: Bool) {}
    func maskTint(masks: [ClipMask.ID], pts: Double) -> MaskTintPicture { asked.append((masks, pts)); return answer }
}

@MainActor
struct MonitorMaskTintTests {
    /// A clip from source second 1 with one Magic mask and one path mask, selected in Effect Controls.
    private func setup() throws -> (MonitorCardHost, TintStub, ClipMask.ID, () -> DrawList) {
        // The host holds Effect Controls weakly: the frame closure keeps it (and the session) alive.
        var magic = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        magic.source = .magic
        var clip = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: Time(1, 1), duration: Time(2, 1)), start: .zero)
        clip.masks = [magic, ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))]
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])])
        let program = MonitorEngineStub()
        let s = EditorSession(project: p, fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let effects = EffectControlsModel()
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(), effects: effects,
                                   projectList: ProjectListView(host: shell), timelineHost: TimelineHost(), qualityDefaults: nil)
        host.monitor.maskTintDefaults = UserDefaults(suiteName: "sq.test.maskTint.\(UUID())")!
        let stub = TintStub()
        host.monitor.magic = stub
        s.select(clips: [clip.id])
        effects.setClip(s.activeTimeline?.tracks[0].clips.first)
        func frame() -> DrawList {
            withExtendedLifetime((effects, s)) {}
            var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
            host.draw(&c, card: DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1, isPlaying: false, theme: DrawTheme())
            host.draw(&c, card: DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1, isPlaying: false, theme: DrawTheme())
            return c.list
        }
        return (host, stub, magic.id, frame)
    }

    private func tintQuads(_ l: DrawList) -> Int { l.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue && Int($0.pad) == MonitorHost.maskTintSlot }.count }

    /// `updateMaskTint`: only with the Mask tool on (or a mask selected), the Magic masks only, at the source frame.
    @Test func theMaskToolShowsTheMagicMattesAtTheSourceFrame() throws {
        let (host, stub, magic, frame) = try setup()
        stub.answer = MaskTintPicture(image: (RGBAImage(width: 2, height: 2, fill: .white), generation: 5))
        _ = frame()
        #expect(stub.asked.isEmpty && host.monitor.maskTint == nil)       // Selection tool, no mask selected
        host.monitor.maskToolNow = { .magic }
        let list = frame()
        #expect(stub.asked.last?.masks == [magic])
        #expect(stub.asked.last?.pts == 1)                                // source second 1 at the clip's start
        #expect(host.monitor.maskTint?.0 == MonitorHost.maskTintSlot && host.monitor.maskTint?.2 == 2_000_005)
        #expect(host.monitor.panel.overlay.maskTintSlot == MonitorHost.maskTintSlot)
        #expect(tintQuads(list) >= 1)
    }

    /// A read still running keeps the last tint (no flicker while scrubbing); none in and none coming clears it.
    @Test func aPendingReadKeepsTheLastTint() throws {
        let (host, stub, _, frame) = try setup()
        host.monitor.maskToolNow = { .magic }
        stub.answer = MaskTintPicture(image: (RGBAImage(width: 2, height: 2, fill: .white), generation: 1))
        _ = frame()
        stub.answer = MaskTintPicture(waiting: true)
        _ = frame()
        #expect(host.monitor.maskTint?.2 == 2_000_001)
        stub.answer = MaskTintPicture()
        let list = frame()
        #expect(host.monitor.maskTint == nil && host.monitor.panel.overlay.maskTintSlot == nil)
        #expect(tintQuads(list) == 0)
    }

    /// Program monitor menu > Mask Tint (checked by default) turns it off and on.
    @Test func theProgramMenuRowSwitchesTheTint() throws {
        let (host, stub, _, frame) = try setup()
        host.monitor.maskToolNow = { .magic }
        stub.answer = MaskTintPicture(image: (RGBAImage(width: 2, height: 2, fill: .white), generation: 1))
        let row = { host.monitor.programMenuItems().first { $0.title == "Mask Tint" } }
        #expect(row()?.isChecked == true)
        row()?.action?()
        #expect(!host.monitor.showsMaskTint && row()?.isChecked == false)
        _ = frame()
        #expect(host.monitor.maskTint == nil)
        row()?.action?()
        _ = frame()
        #expect(host.monitor.maskTint != nil)
    }

    /// The pointer over the picture with the Magic tool reaches the segmenter with the clip; a hover highlight asks for
    /// the tint picture even when no Magic mask is stored yet.
    @Test func theMagicHoverReachesTheSegmenterAndAsksForTheTint() throws {
        let (host, stub, _, frame) = try setup()
        stub.answer = MaskTintPicture(image: (RGBAImage(width: 2, height: 2, fill: .white), generation: 1))
        host.monitor.maskToolNow = { .magic }
        _ = frame()
        let o = host.monitor.panel.overlay
        o.onMaskToolHover?(Vec2(0.4, 0.6))
        #expect(stub.hovers.count == 1 && stub.hovers[0].0 == Vec2(0.4, 0.6) && stub.hovers[0].1 != nil)
        // No Magic mask in the clip, but a highlight: the tint is asked for.
        var clip = host.monitor.effects?.clip
        clip?.masks = []
        host.monitor.effects?.setClip(clip)
        stub.asked = []
        stub.hasHover = true
        _ = frame()
        #expect(!stub.asked.isEmpty && stub.asked.last?.masks.isEmpty == true)
        stub.asked = []
        stub.hasHover = false
        _ = frame()
        #expect(stub.asked.isEmpty)
    }
}
