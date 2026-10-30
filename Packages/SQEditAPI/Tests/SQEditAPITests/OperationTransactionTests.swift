import Foundation
import Testing
import SQCore
@testable import SQEditAPI

@Suite struct OperationSchemaTests {
    @Test func decodesEveryOperationFromJSON() throws {
        let id = UUID(), tr = UUID()
        let json = """
        [{"op":"razor","at":{"value":2,"timescale":1}},
         {"op":"razor","at":{"value":2,"timescale":1},"tracks":["\(tr)"]},
         {"op":"rippleDelete","clips":["\(id)"]},
         {"op":"lift","clips":["\(id)"]},
         {"op":"extract","range":{"start":{"value":1,"timescale":1},"duration":{"value":1,"timescale":2}}},
         {"op":"liftRange","range":{"start":{"value":1,"timescale":1},"duration":{"value":1,"timescale":2}},"tracks":["\(tr)"]},
         {"op":"trim","clip":"\(id)","edge":"head","by":{"value":1,"timescale":25}},
         {"op":"rippleTrim","clip":"\(id)","edge":"tail","by":{"value":-1,"timescale":25}},
         {"op":"move","clip":"\(id)","to":{"value":3,"timescale":1},"track":"\(tr)"},
         {"op":"slip","clip":"\(id)","by":{"value":1,"timescale":25}},
         {"op":"slide","clip":"\(id)","by":{"value":1,"timescale":25}},
         {"op":"roll","clip":"\(id)","by":{"value":1,"timescale":25}},
         {"op":"toggleEnabled","clips":["\(id)"]},
         {"op":"addMarker","at":{"value":1,"timescale":1},"name":"Hook"}]
        """
        let ops = try JSONDecoder().decode([EditOperation].self, from: Data(json.utf8))
        #expect(ops.count == 14)
        #expect(ops[0] == .razor(at: .s(2), tracks: nil))
        #expect(ops[6] == .trim(clip: id, edge: .head, by: Time(1, 25)))
        #expect(ops[13] == .addMarker(at: .s(1), name: "Hook"))
        // Round trip through our own encoder.
        let again = try JSONDecoder().decode([EditOperation].self, from: JSONEncoder().encode(ops))
        #expect(again == ops)
    }

    @Test func rejectsUnknownOpAndBadEdge() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditOperation.self, from: Data(#"{"op":"explode"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditOperation.self, from: Data(#"{"op":"trim","clip":"\#(UUID())","edge":"middle","by":{"value":1,"timescale":1}}"#.utf8))
        }
        #expect(throws: DecodingError.self) {   // a zero timescale never reaches Time's precondition
            try JSONDecoder().decode(EditOperation.self, from: Data(#"{"op":"razor","at":{"value":1,"timescale":0}}"#.utf8))
        }
    }
}

@Suite struct TransactionTests {
    @Test func appliesBatchInOrder() throws {
        let f = Fixture()
        var p = f.project
        try EditTransaction.apply([.razor(at: .s(2), tracks: nil), .rippleDelete(clips: [f.b])], to: &p, sequence: f.seq)
        let t = try #require(p.timeline(f.seq))
        #expect(t.tracks[0].clips.count == 2)          // a split in two, b gone
        #expect(t.tracks[1].clips.count == 2)          // a' split with it
        #expect(t.tracks[0].clips.map(\.start) == [.zero, .s(2)])
    }

    @Test func failingOperationRollsBackEverything() {
        let f = Fixture()
        var p = f.project
        let ghost = UUID()
        #expect {
            try EditTransaction.apply([.rippleDelete(clips: [f.b]), .lift(clips: [ghost])], to: &p, sequence: f.seq)
        } throws: { e in
            guard let te = e as? TransactionError else { return false }
            return te.operationIndex == 1 && te.underlying == .clipNotFound
        }
        #expect(p == f.project)
    }

    @Test func unknownSequenceThrows() {
        var p = Fixture().project
        #expect(throws: TransactionError.self) { try EditTransaction.apply([], to: &p, sequence: UUID()) }
    }

    /// `liftRange` on V1 only: the linked sound on the untargeted A1 is cut with its picture, nothing ripples.
    @Test func liftRangeWithExplicitTracksCutsTheLinkedPartner() throws {
        let f = Fixture()
        var p = f.project
        try EditTransaction.apply([.liftRange(range: TimeRange(start: .s(1), duration: .s(1)), tracks: [f.v1])], to: &p, sequence: f.seq)
        let t = try #require(p.timeline(f.seq))
        let v = try #require(t.track(f.v1)).clips, a = try #require(t.track(f.a1)).clips
        #expect(v.map(\.start) == [.s(0), .s(2), .s(4)])
        #expect(a.map(\.start) == [.s(0), .s(2)])
        #expect(a.map(\.duration) == [.s(1), .s(2)])
        #expect(a[0].id == f.aAudio && a[0].link == v[0].link)
        #expect(a[1].link != nil && a[1].link == v[1].link && a[1].link != a[0].link)
    }

    @Test func emptyRangeTracksMeansUnlockedTracks() throws {
        let f = Fixture()
        var p = f.project
        try EditTransaction.apply([.extract(range: TimeRange(start: .s(1), duration: .s(1)), tracks: nil)], to: &p, sequence: f.seq)
        let t = try #require(p.timeline(f.seq))
        #expect(t.duration == .s(7))
    }

    @Test func oneUndoStepThroughHistory() throws {
        let f = Fixture()
        var h = History(f.project)
        try h.commit("Agent: tighten") { p in
            try EditTransaction.apply([.razor(at: .s(1), tracks: nil), .razor(at: .s(3), tracks: nil),
                                       .rippleDelete(clips: [f.b])], to: &p, sequence: f.seq)
        }
        #expect(h.undoDepth == 1)
        #expect(h.undoName == "Agent: tighten")
        h.undo()
        #expect(h.current == f.project)
    }
}

@Suite struct DiffTests {
    @Test func reportsAddedRemovedChangedAndDuration() throws {
        let f = Fixture()
        var p = f.project
        try EditTransaction.apply([.razor(at: .s(2), tracks: [f.v1]), .rippleDelete(clips: [f.b])], to: &p, sequence: f.seq)
        let d = EditDiff(before: try #require(f.project.timeline(f.seq)), after: try #require(p.timeline(f.seq)))
        #expect(d.removed.map(\.id) == [f.b])
        #expect(d.added.count == 1)                                    // right half of a
        #expect(d.added[0].start == .s(2) && d.added[0].duration == .s(2))
        #expect(d.changed.map(\.id) == [f.a])                          // a got shorter
        #expect(d.changed[0].before.duration == .s(4) && d.changed[0].after.duration == .s(2))
        #expect(d.durationBefore == .s(8) && d.durationAfter == .s(4))
        #expect(!d.isEmpty)
    }

    @Test func noChangeIsEmpty() throws {
        let t = try #require(Fixture().project.timelines.first)
        #expect(EditDiff(before: t, after: t).isEmpty)
    }

    @Test func markerChangesCount() throws {
        let f = Fixture()
        var p = f.project
        try EditTransaction.apply([.addMarker(at: .s(1), name: "x")], to: &p, sequence: f.seq)
        let d = EditDiff(before: try #require(f.project.timeline(f.seq)), after: try #require(p.timeline(f.seq)))
        #expect(d.markersAdded == 1 && d.added.isEmpty && d.removed.isEmpty)
    }
}

@Suite struct StableIDTests {
    /// Agents drive by ids: a save + reopen must keep every sequence, track, clip and effect id.
    @Test func idsSurviveProjectFileRoundTrip() throws {
        let f = Fixture()
        var p = f.project
        try p.edit(f.seq) { t in _ = try t.addEdit(at: .s(1), tracks: nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqapi-\(UUID().uuidString).sqproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(ProjectState(p).sequences == ProjectState(back).sequences)
        let ids = { (q: Project) in q.timelines.flatMap { $0.tracks.flatMap { $0.clips.map(\.id) } } }
        #expect(ids(p) == ids(back) && ids(p).count == 5)
    }

    @Test func stateCarriesRationalTimesAndEffects() throws {
        let f = Fixture()
        let s = ProjectState(f.project)
        #expect(s.activeSequence == f.seq)
        let clip = try #require(s.sequences.first?.tracks.first?.clips.first)
        #expect(clip.id == f.a && clip.start == .zero && clip.duration == .s(4) && clip.source.start == .s(2))
        #expect(clip.link != nil && clip.media == f.project.media.first?.id)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(json.contains("\"timescale\""))
        #expect(!json.contains("/x/m.mov"))      // no file paths leave the app
    }
}
