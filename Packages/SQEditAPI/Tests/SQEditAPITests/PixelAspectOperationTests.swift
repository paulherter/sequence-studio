import Foundation
import Testing
import SQCore
@testable import SQEditAPI

@Suite struct SetPixelAspectOperationTests {
    private func fixtureWithPicture() -> (Fixture, MediaRef.ID) {
        var f = Fixture()
        let id = f.project.media[0].id
        f.project.media[0].info = MediaInfo(duration: Time(20, 1), video: VideoTrackInfo(
            width: 1440, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false))
        return (f, id)
    }

    @Test func decodesAndRoundTrips() throws {
        let id = UUID()
        let json = #"[{"op":"setPixelAspect","media":"\#(id)","aspect":{"num":4,"den":3}},{"op":"setPixelAspect","media":"\#(id)"}]"#
        let ops = try JSONDecoder().decode([EditOperation].self, from: Data(json.utf8))
        #expect(ops == [.setPixelAspect(media: id, aspect: PixelAspect(4, 3)), .setPixelAspect(media: id, aspect: nil)])
        #expect(try JSONDecoder().decode([EditOperation].self, from: JSONEncoder().encode(ops)) == ops)
        let bad = #"[{"op":"setPixelAspect","media":"\#(id)","aspect":{"num":9,"den":1}}]"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([EditOperation].self, from: Data(bad.utf8)) }
    }

    @Test func setsAndClearsTheChoice() throws {
        let (f, id) = fixtureWithPicture()
        var p = f.project
        try EditTransaction.apply([.setPixelAspect(media: id, aspect: PixelAspect(4, 3))], to: &p, sequence: f.seq)
        #expect(p.pixelAspect(of: id) == PixelAspect(4, 3))
        var diff = EditDiff(before: f.project.timelines[0], after: p.timelines[0])
        #expect(diff.isEmpty)
        diff.noteMedia(before: f.project, after: p)
        #expect(diff.pixelAspectChanges == 1 && !diff.isEmpty)
        try EditTransaction.apply([.setPixelAspect(media: id, aspect: nil)], to: &p, sequence: f.seq)
        #expect(p.pixelAspect(of: id) == .square)
    }

    @Test func refusalLeavesTheProjectUntouched() throws {
        let (f, id) = fixtureWithPicture()
        var p = f.project
        #expect(throws: TransactionError.self) {
            try EditTransaction.apply([.setPixelAspect(media: id, aspect: PixelAspect(2, 1)),
                                       .setPixelAspect(media: UUID(), aspect: nil)], to: &p, sequence: f.seq)
        }
        #expect(p.media == f.project.media)
        // A timeline failure after the media setting rolls it back too.
        #expect(throws: TransactionError.self) {
            try EditTransaction.apply([.setPixelAspect(media: id, aspect: PixelAspect(2, 1)), .rippleDelete(clips: [UUID()])],
                                      to: &p, sequence: f.seq)
        }
        #expect(p.media == f.project.media)
        // Media without a probed picture.
        var q = f.project
        q.media[0].info = nil
        do { try EditTransaction.apply([.setPixelAspect(media: id, aspect: nil)], to: &q, sequence: f.seq); Issue.record("no throw") }
        catch let e as TransactionError { #expect(e.kind == .noPicture && e.operationIndex == 0) }
    }
}
