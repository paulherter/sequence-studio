import Foundation
import Testing
import SSCore
@testable import SSEditorUI

private func media(_ name: String, video: Bool = true, audio: Bool = true, path: String? = nil) -> MediaRef {
    let v = video ? VideoTrackInfo(width: 3840, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                                   nominalFrameDuration: Time(1001, 30000), isVariableFrameRate: false) : nil
    let a = audio ? AudioTrackInfo(sampleRate: 48000, channels: 2, codec: "aac") : nil
    return MediaRef(name: name, path: path ?? "/nonexistent/\(name)", fingerprint: MediaFingerprint(size: 1),
                    duration: Time(10, 1), info: MediaInfo(duration: Time(10, 1), video: v, audio: a))
}

@MainActor private final class Edits { var list: [(Project, String)] = [] }

@MainActor private func model(_ p: Project) -> (ProjectPanelModel, Edits) {
    let e = Edits()
    return (ProjectPanelModel(project: p, probe: { _ in throw CancellationError() }, onEdit: { e.list.append(($0, $1)) }), e)
}

@MainActor @Suite struct ProjectPanelLabelColumnTests {
    // MARK: Labels

    @Test func labelChangeIsOneUndoStepForWholeSelection() {
        let a = media("a"), b = media("b", video: false)
        var p = Project(name: "P"); p.add(a); p.add(b)
        let (m, e) = model(p)
        #expect(m.label(of: .media(a.id)) == .blue)
        #expect(m.label(of: .media(b.id)) == .green)
        #expect(m.setLabel(.rose, for: [.media(a.id), .media(b.id)]))
        #expect(e.list.count == 1 && e.list[0].1 == "Change Label")
        #expect(m.label(of: .media(a.id)) == .rose && m.label(of: .media(b.id)) == .rose)
        #expect(!m.setLabel(.rose, for: [.media(a.id)]))        // nothing changed: no undo step
        #expect(e.list.count == 1)
        #expect(m.setLabel(nil, for: [.media(b.id)]))
        #expect(m.label(of: .media(b.id)) == .green)
    }

    // MARK: Icons

    @Test func iconsPerKind() {
        #expect(ProjectItemIcon.icon(for: .video).badge == nil)
        #expect(ProjectItemIcon.icon(for: .videoAudio).badge == "speaker.wave.2.fill")
        #expect(ProjectItemIcon.icon(for: .videoAudio).symbol == ProjectItemIcon.icon(for: .video).symbol)
        let all: [ProjectItemKind] = [.bin, .video, .audio, .videoAudio, .image, .sequence, .nestedSequence, .text, .generator]
        #expect(Set(all.map { ProjectItemIcon.icon(for: $0).symbol }).count >= 8)
        #expect(ProjectItemIcon.icon(for: .audio, offline: true) != ProjectItemIcon.icon(for: .audio))
    }

    @Test func itemKindsFromProject() {
        let av = media("av"), v = media("v", audio: false), au = media("au", video: false)
        let img = MediaRef(name: "p", path: "/x/p.jpg", fingerprint: MediaFingerprint(size: 1))
        let inner = Timeline(name: "Inner", frameDuration: Time(1001, 30000))
        let nest = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                        start: .zero, sequence: inner.id)
        let outer = Timeline(name: "Outer", frameDuration: Time(1001, 30000), tracks: [Track(kind: .video, clips: [nest])])
        var p = Project(name: "P", timelines: [outer, inner])
        [av, v, au, img].forEach { p.add($0) }
        let (m, _) = model(p)
        #expect(m.itemKind(of: .media(av.id)) == .videoAudio)
        #expect(m.itemKind(of: .media(v.id)) == .video)
        #expect(m.itemKind(of: .media(au.id)) == .audio)
        #expect(m.itemKind(of: .media(img.id)) == .image)
        #expect(m.itemKind(of: .sequence(outer.id)) == .sequence)
        #expect(m.itemKind(of: .sequence(inner.id)) == .nestedSequence)
        #expect(m.itemKind(of: .bin(p.rootBin.id)) == .bin)
    }

    // MARK: Columns

    @Test func cellTexts() {
        let a = media("a")
        var p = Project(name: "P", timelines: [Timeline(name: "S", frameDuration: Time(1, 25))])
        p.add(a)
        let (m, _) = model(p)
        #expect(m.cellText(.frameRate, .media(a.id)) == "29.97 fps")
        #expect(m.cellText(.resolution, .media(a.id)) == "3840×2160")
        #expect(m.cellText(.codec, .media(a.id)) == "H.264")
        #expect(m.cellText(.audio, .media(a.id)) == "48 kHz 2 ch")
        #expect(m.cellText(.filePath, .media(a.id)) == "/nonexistent/a")
        #expect(m.cellText(.label, .media(a.id)) == "Blue")
        #expect(m.cellText(.frameRate, .sequence(p.timelines[0].id)) == "25 fps")
        #expect(m.cellText(.frameRate, .bin(p.rootBin.id)) == "")
    }

    @Test func defaultLayoutIsNameAndFrameRate() {
        #expect(ProjectColumnLayout.defaults.visible == [.name, .frameRate])
    }

    @Test func layoutToggleOrderAndNameAlwaysFirst() {
        var l = ProjectColumnLayout.defaults
        l.toggle(.name)
        #expect(l.visible == [.name, .frameRate])
        l.toggle(.codec); l.toggle(.duration)
        #expect(l.visible == [.name, .frameRate, .codec, .duration])
        l.toggle(.frameRate)
        #expect(!l.isVisible(.frameRate))
        l.move(.duration, toIndex: 1)
        #expect(l.visible == [.name, .duration, .codec])
        l.move(.codec, toIndex: 0)                               // nothing goes before Name
        #expect(l.visible == [.name, .codec, .duration])
        #expect(ProjectColumnLayout(visible: [.codec, .name, .codec]).visible == [.name, .codec])
    }

    @Test func layoutSavedPerUserAndSurvivesUnknownColumns() throws {
        let suite = "ProjectColumnLayoutTests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(ProjectColumnLayout.load(from: d) == .defaults)
        var l = ProjectColumnLayout.defaults
        l.toggle(.resolution); l.setWidth(123, for: .resolution)
        l.save(to: d)
        let back = ProjectColumnLayout.load(from: d)
        #expect(back == l && back.width(of: .resolution) == 123 && back.width(of: .codec) == ProjectPanelModel.Column.codec.defaultWidth)
        d.set(Data(#"{"visible":["name","bogus","codec"],"widths":{}}"#.utf8), forKey: ProjectColumnLayout.defaultsKey)
        #expect(ProjectColumnLayout.load(from: d).visible == [.name, .codec])
    }

    // MARK: B3: drags

    @Test func internalIDsBeatFileURLs() {
        let a = media("a")
        let url = URL(fileURLWithPath: a.path)
        var p = Project(name: "P"); p.add(a)
        let (m, _) = model(p)
        // A dragged-out item carries both its ID and its file URL: it is a move, never an import.
        #expect(m.classifyDrop(items: [.media(a.id)], files: [url]) == .move([.media(a.id)]))
        // A plain file drop of media already in the project imports nothing.
        #expect(m.classifyDrop(items: [], files: [url]) == .none)
        let other = URL(fileURLWithPath: "/nonexistent/new.mov")
        #expect(m.classifyDrop(items: [], files: [url, other]) == .importFiles([other]))
    }

    @Test func droppingBackOnItsOwnBinIsNoOp() {
        let a = media("a"), b = media("b")
        var p = Project(name: "P"); p.add(a); p.add(b)
        let (m, e) = model(p)
        let root = m.project.rootBin.id
        #expect(!m.move([.media(a.id)], to: root))              // already there, no position
        #expect(e.list.isEmpty)
        #expect(m.project.rootBin.mediaIDs == [a.id, b.id])
        #expect(!m.move([.media(a.id)], to: root, at: 0))       // same position: nothing changes
        #expect(e.list.isEmpty)
        #expect(m.move([.media(a.id)], to: root, at: 1))        // real reorder within the bin
        #expect(m.project.rootBin.mediaIDs == [b.id, a.id])
        #expect(m.project.media.count == 2)
    }
}
