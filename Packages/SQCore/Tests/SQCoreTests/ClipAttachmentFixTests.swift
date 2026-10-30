import Foundation
import Testing
@testable import SQCore

// Phase 1A review fixes (Fast Cut model): attachment points survive crops, splits and head trims; joins see through
// attachments; ungroup maps hosts back; templates gate attachments; the main track never carries one; id remaps.

private func s(_ x: Double) -> Time { Time(Int64(x * 10), 10) }

private func clip(_ kind: TrackKind, _ start: Double, _ len: Double, src: Double = 0, id: UUID = UUID(),
                  link: UUID? = nil, media: UUID = UUID(), generator: GeneratorRef? = nil) -> Clip {
    Clip(id: id, name: "x", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(len)), start: s(start),
         link: link, mediaDuration: s(100), generator: generator)
}

private func attached(_ c: Clip, to host: UUID, point: Double) -> Clip {
    var c = c; c.attachment = ClipAttachment(host: host, point: s(point)); return c
}

private func text() -> GeneratorRef { GeneratorRef(kind: GeneratorRef.text, payload: Data("t".utf8)) }

@Suite struct ClipAttachmentFixTests {
    // MARK: 1. Points keep their attach time

    @Test func croppedKeepsTheAttachTime() throws {
        let c = attached(clip(.video, 2, 4), to: UUID(), point: 1)            // attach time 3
        let r = try #require(c.cropped(to: TimeRange(start: s(2.5), end: s(6))))
        #expect(r.start == s(2.5))
        #expect(r.attachment?.point == s(0.5))
        #expect(r.start + r.attachment!.point == s(3))
    }

    @Test func splitKeepsTheAttachTimeOnBothHalves() throws {
        let host = UUID()
        var t = Track(kind: .video)
        try t.overwrite(attached(clip(.video, 2, 4), to: host, point: 1))
        try t.split(at: s(4))
        #expect(t.clips.count == 2)
        for c in t.clips { #expect(c.start + c.attachment!.point == s(3)) }
    }

    @Test func headTrimKeepsTheAttachTime() throws {
        let v1 = clip(.video, 0, 10)
        let title = attached(clip(.video, 2, 4, src: 5), to: v1.id, point: 1)
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [v1]), Track(kind: .video, clips: [title])])
        _ = try tl.trim(title.id, edge: .head, by: s(0.5))                    // start 2.5, shorter
        var c = tl.find(title.id)!.clip
        #expect(c.start == s(2.5))
        #expect(c.start + c.attachment!.point == s(3))
        _ = try tl.trim(title.id, edge: .head, by: s(-1))                     // start 1.5, longer
        c = tl.find(title.id)!.clip
        #expect(c.start + c.attachment!.point == s(3))
    }

    // MARK: 2. Join sees through attachments

    @Test func joinRefusesNothingBecauseOfAttachments() throws {
        let v1 = clip(.video, 0, 10)
        let title = attached(clip(.video, 2, 4), to: v1.id, point: 1)
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [v1]), Track(kind: .video, clips: [title])])
        tl.setEditMode(.magnetic)
        _ = try tl.addEdit(at: s(5), tracks: [tl.tracks[1].id])
        tl.deriveAttachments()                                                  // right half re-derived: different point
        #expect(tl.tracks[1].clips.count == 2)
        #expect(try tl.joinThroughEdits() == 1)
        #expect(tl.tracks[1].clips.count == 1)
        #expect(tl.find(title.id)!.clip.attachment == ClipAttachment(host: v1.id, point: s(1)))
    }

    // MARK: 3. Ungroup maps hosts back

    @Test func ungroupMapsHostsBack() throws {
        let c1 = clip(.video, 0, 4), c2 = clip(.video, 4, 4)
        let title = attached(clip(.video, 5, 1), to: c2.id, point: 0)
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c1, c2]),
                                                                       Track(kind: .video, clips: [title])])
        tl.setEditMode(.magnetic)
        var p = Project(name: "P", timelines: [tl])
        _ = try p.group(clips: [c2.id], in: tl.id)
        let grouped = try #require(p.timeline(tl.id))
        let g = try #require(grouped.tracks[0].clips.first { $0.sequence != nil })
        #expect(grouped.find(title.id)!.clip.attachment?.host == g.id)
        try p.ungroup(clip: g.id, in: tl.id)
        let back = try #require(p.timeline(tl.id))
        #expect(back.find(title.id)!.clip.attachment?.host == c2.id)
        #expect(back.isAttachmentValid(title.id))
    }

    /// Ungrouping a copy of a group whose clips are already back gives fresh ids; attachments inside follow the copies.
    @Test func ungroupCopyRemapsHostsInsideTheGroup() throws {
        let c1 = clip(.video, 0, 4)
        let t = attached(clip(.video, 1, 1), to: c1.id, point: 0)
        let tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c1]), Track(kind: .video, clips: [t])])
        var p = Project(name: "P", timelines: [tl])
        let seq = try p.group(clips: [c1.id, t.id], in: tl.id)
        var outer = try #require(p.timeline(tl.id))
        let g = try #require(outer.tracks[0].clips.first { $0.sequence == seq })
        // A second copy of the group clip later on V1.
        var copy = g; copy.id = UUID(); copy.start = s(10)
        try outer.tracks[0].overwrite(copy)
        p.timelines[p.timelines.firstIndex { $0.id == tl.id }!] = outer
        try p.ungroup(clip: g.id, in: tl.id)
        let restored = try p.ungroup(clip: copy.id, in: tl.id)
        let back = try #require(p.timeline(tl.id))
        let fresh = restored.compactMap { back.find($0)?.clip }
        let freshTitle = try #require(fresh.first { $0.attachment != nil })
        #expect(!([c1.id, t.id].contains(freshTitle.id)))
        #expect(restored.contains(freshTitle.attachment!.host))
    }

    // MARK: 4. Templates

    @Test func projectTemplateDropsMissingHostsAndGatesAttachments() throws {
        let media = clip(.video, 0, 4)
        let onMedia = attached(clip(.video, 1, 1, generator: text()), to: media.id, point: 0)
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [media]),
                                                                       Track(kind: .video, clips: [onMedia])])
        tl.editMode = .magnetic
        let t1 = ProjectTemplate(capturing: tl, name: "T")
        let c1 = try #require(t1.content)
        #expect(c1.editMode == .normal)                                       // new sequences take the preference
        #expect(c1.tracks.flatMap(\.clips).allSatisfy { $0.attachment == nil })
        #expect(t1.writtenFormatVersion == 1)

        let g1 = clip(.video, 0, 4, generator: text())
        let g2 = attached(clip(.video, 1, 1, generator: text()), to: g1.id, point: 0)
        let tl2 = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [g1]),
                                                                        Track(kind: .video, clips: [g2])])
        let t2 = ProjectTemplate(capturing: tl2, name: "T")
        #expect(t2.writtenFormatVersion == 3)
        #expect(ProjectTemplate.formatVersion >= 3)
        let back = try JSONDecoder().decode(ProjectTemplate.self, from: try JSONEncoder().encode(t2))
        #expect(back.content?.find(g2.id)?.clip.attachment == g2.attachment)
    }

    @Test func titleTemplateGatesAttachments() throws {
        let g1 = clip(.video, 0, 4, generator: text())
        let g2 = attached(clip(.video, 1, 1, generator: text()), to: g1.id, point: 0)
        let content = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [g1]),
                                                                            Track(kind: .video, clips: [g2])])
        let t = TitleTemplate(name: "T", content: content)
        #expect(t.writtenFormatVersion == 4)
        #expect(TitleTemplate.formatVersion >= 4)
        let back = try JSONDecoder().decode(TitleTemplate.self, from: try JSONEncoder().encode(t))
        #expect(back.content.find(g2.id)?.clip.attachment == g2.attachment)
        var plain = content
        plain.tracks[1].mapClipsKeepingTiming { var c = $0; c.attachment = nil; return c }
        #expect(TitleTemplate(name: "T", content: plain).writtenFormatVersion == 1)
    }

    // MARK: 5. Main track never carries an attachment

    private func mainFixture() -> (Timeline, Clip, Clip) {
        let v1 = clip(.video, 0, 4)
        let title = attached(clip(.video, 6, 1), to: v1.id, point: 0)
        return (Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [v1]),
                                                                      Track(kind: .video, clips: [title])]), v1, title)
    }

    @Test func moveOntoTheMainTrackClearsTheAttachment() throws {
        var (tl, _, title) = mainFixture()
        _ = try tl.move(title.id, to: s(6), track: tl.tracks[0].id)
        #expect(tl.tracks[0].clip(title.id)?.attachment == nil)
    }

    @Test func moveToLaneOntoTheMainTrackClearsTheAttachment() throws {
        var (tl, _, title) = mainFixture()
        #expect(try tl.moveToLane([title.id], up: false))
        #expect(tl.tracks[0].clip(title.id)?.attachment == nil)
    }

    @Test func insertMoveOntoTheMainTrackClearsTheAttachment() throws {
        var (tl, _, title) = mainFixture()
        try tl.insertMove(title.id, to: s(4), track: tl.tracks[0].id)
        #expect(tl.tracks[0].clip(title.id)?.attachment == nil)
    }

    @Test func pasteOntoTheMainTrackClearsTheAttachment() throws {
        var (tl, v1, title) = mainFixture()
        let cb = try #require(tl.clipboard(copying: [v1.id, title.id]))
        let made = try tl.paste(cb, at: s(10), lanes: [.video: 0])
        let copies = made.compactMap { tl.find($0) }
        let onMain = try #require(copies.first { $0.track == 0 })
        #expect(onMain.clip.attachment == nil)
        let up = try #require(copies.first { $0.track == 1 })
        #expect(up.clip.attachment?.host == onMain.clip.id)
        // Only the copied title, pasted onto V1: it is a main-track clip now.
        let cb2 = try #require(tl.clipboard(copying: [title.id]))
        let one = try tl.paste(cb2, at: s(20), lanes: [.video: 0])
        #expect(tl.find(one[0])!.clip.attachment == nil)
    }

    // MARK: 6. Remaps

    @Test func titleBlockRemapsHostsWithinTheBlock() throws {
        let g1 = clip(.video, 0, 4, generator: text())
        let g2 = attached(clip(.video, 1, 1, generator: text()), to: g1.id, point: 0)
        let src = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [g1]),
                                                                        Track(kind: .video, clips: [g2])])
        let cb = try #require(src.clipboard(copying: [g1.id, g2.id]))
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip(.video, 0, 20)])])
        let ids = try t.placeBlock(cb, at: s(2))
        let placed = ids.compactMap { t.find($0)?.clip }
        let up = try #require(placed.first { $0.attachment != nil })
        #expect(ids.contains(up.attachment!.host))
        #expect(!([g1.id, g2.id].contains(up.attachment!.host)))
    }

    @Test func formatChangeAndConformedDuplicateKeepAttachments() throws {
        let c1 = clip(.video, 0, 4)
        let title = attached(clip(.video, 1, 1), to: c1.id, point: 0.5)
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c1]),
                                                                       Track(kind: .video, clips: [title])])
        tl.setEditMode(.magnetic)
        var p = Project(name: "P", timelines: [tl])
        var f = tl.format; f.width = 1080; f.height = 1920
        let copyID = try p.duplicateSequence(tl.id, as: f, mode: .fill, overrides: [title.id: .fit])
        let copy = try #require(p.timeline(copyID))
        let cTitle = try #require(copy.tracks[1].clips.first)
        #expect(cTitle.attachment?.host == copy.tracks[0].clips.first?.id)
        #expect(cTitle.attachment?.point == s(0.5))
        try p.changeFormat(of: tl.id, to: f, mode: .fill, overrides: [title.id: .fit])
        #expect(p.timeline(tl.id)!.find(title.id)!.clip.attachment == title.attachment)
    }

    @Test func writtenVersionFollowsFastCutContent() {
        var p = v67FixtureProject()
        #expect(ProjectFile.writtenVersion(for: p) < ProjectFile.v67Version)
        p.timelines[0].setEditMode(.magnetic)
        #expect(ProjectFile.writtenVersion(for: p) == 67)
        p.timelines[0].editMode = .normal                                      // attachments alone still gate
        #expect(p.timelines[0].tracks.contains { $0.clips.contains { $0.attachment != nil } })
        #expect(ProjectFile.writtenVersion(for: p) == 67)
    }
}
