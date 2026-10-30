import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

// F7.11 Anonymize on a synthesized movie (a checker patch moving right over gray stands in for a person): finding the
// person, following it with the Magic tracker, the face matte per frame and the frames listed for a manual check.

/// The patch's extent on a frame of the test movie (`PatchSegmenter`'s rule), in frame fractions.
private func patch(_ pb: CVPixelBuffer) -> AnonymizeBox? {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(pb)
    var x0 = w, x1 = -1, y0 = h, y1 = -1
    for y in 0..<h {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let g = Int(row[x * 4 + 1])
            if g < 40 || g > 215 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
        }
    }
    guard x1 >= 0 else { return nil }
    return AnonymizeBox(x: Double(x0) / Double(w), y: Double(y0) / Double(h), width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h))
}

/// The patch is the body; its top half's middle is the face. `faceUntil`: no face once the patch's left edge passed this.
private struct PatchDetector: PersonDetecting {
    var faceUntil = 2.0
    func detect(_ pb: CVPixelBuffer, bodies: Bool) throws -> (bodies: [AnonymizeBox], faces: [AnonymizeFace]) {
        guard let b = patch(pb) else { return ([], []) }
        let face = AnonymizeBox(x: b.x + b.width * 0.3, y: b.y + b.height * 0.1, width: b.width * 0.4, height: b.height * 0.3)
        return (bodies ? [b] : [], b.x < faceUntil ? [AnonymizeFace(box: face, confidence: 0.9)] : [])
    }
}

/// Serialized: every test writes and reads a movie; in parallel with the other movie suites they starve the media engine.
@Suite(.serialized) struct AnonymizerTests {
    private func anonymizer(_ url: URL, _ d: PatchDetector = PatchDetector()) -> Anonymizer {
        Anonymizer(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter(), detector: d)
    }

    @Test func findsThePersonOnTheShownFrame() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let found = try #require(try await anonymizer(url).findPeople(at: 0.52))
        #expect(abs(found.pts - 0.5) < 1e-3)
        #expect(found.people.count == 1)
        let p = try #require(found.people.first)
        #expect(p.face != nil)
        // Frame 12: the patch spans x 108...148 of 320.
        #expect(p.point.x * 320 > 108 && p.point.x * 320 < 148 && p.point.y * 180 > 70 && p.point.y * 180 < 110)
        let pick = Anonymizer.selection(p, pts: found.pts, target: .face)
        #expect(pick.part == .face && pick.points.count == 1)
        // A whole person is marked too: every mask Anonymize makes must cover.
        let whole = Anonymizer.selection(p, pts: found.pts, target: .person)
        #expect(whole.part == .person && whole.mustCover && whole.cacheKey(media: UUID()) != "")
    }

    @Test func followsTheFaceOverTheWholeClipFromAFrameInTheMiddle() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = anonymizer(url)
        let found = try #require(try await a.findPeople(at: 0.5))
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .face)
        let media = UUID(), store = MagicMatteStore(directory: nil)
        let out = try await a.run([pick], media: media, first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        #expect(out.checks.isEmpty)
        let key = try #require(pick.partKey(media: media)), personKey = pick.cacheKey(media: media)
        // Nothing lands under the mask's keys before the result is taken over.
        #expect(store.times(key: key).isEmpty && store.times(key: personKey).isEmpty)
        #expect(Set(out.staged.map(\.key)) == [key, personKey])
        Anonymizer.commit(out.staged, store: store)
        #expect(out.staged.allSatisfy { store.times(key: $0.temp).isEmpty })
        #expect(store.times(key: key).count == 24)
        #expect(store.times(key: personKey).count == 24)
        for i in [0, 12, 23] {
            let face = try #require(store.matte(key: key, pts: Double(i) / 24))
            let person = try #require(store.matte(key: personKey, pts: Double(i) / 24))
            let fc = try #require(face.centroid), pc = try #require(person.centroid)
            // The face cover moves with the patch and sits in its upper part; the person matte is the whole patch.
            #expect(abs(fc.x / Double(face.width) * 320 - Double(80 + 4 * i)) < 6, "frame \(i)")
            #expect(abs(pc.x / Double(person.width) * 320 - Double(80 + 4 * i)) < 6, "frame \(i)")
            #expect(fc.y / Double(face.height) < pc.y / Double(person.height) - 0.03, "frame \(i)")
            #expect(face.area < person.area)
        }
    }

    @Test func wholePersonStoresThePersonMatteAndNeedsNoDetection() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = anonymizer(url, PatchDetector(faceUntil: -1))
        let found = try #require(try await a.findPeople(at: 0))      // no face anywhere: found through the body box
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .person)
        let media = UUID(), store = MagicMatteStore(directory: nil)
        let out = try await a.run([pick], media: media, first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        #expect(out.checks.isEmpty && out.frames == 24)
        #expect(pick.partKey(media: media) == nil)
        #expect(out.staged.map(\.key) == [pick.cacheKey(media: media)])
        Anonymizer.commit(out.staged, store: store)
        #expect(store.times(key: pick.cacheKey(media: media)).count == 24)
    }

    @Test func framesWithoutAFaceAreListedAndStillCovered() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        // The face is gone once the patch's left edge passed x = 130 px: frames 18...23.
        let a = anonymizer(url, PatchDetector(faceUntil: 130.5 / 320))
        let found = try #require(try await a.findPeople(at: 0))
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .face)
        let media = UUID(), store = MagicMatteStore(directory: nil)
        let out = try await a.run([pick], media: media, first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        #expect(out.checks.count == 1)
        let c = try #require(out.checks.first)
        #expect(c.reason == .noFace && c.person == 0)
        #expect(abs(c.from - 18.0 / 24) < 1e-3 && abs(c.to - 23.0 / 24) < 1e-3)
        // Covered by estimate: the cover keeps its place on the person.
        Anonymizer.commit(out.staged, store: store)
        let faceKey = try #require(pick.partKey(media: media))
        let m = try #require(store.matte(key: faceKey, pts: 22.0 / 24))
        let x = try #require(m.centroid).x / Double(m.width) * 320
        #expect(abs(x - Double(80 + 4 * 22)) < 6)
    }

    /// A pick on the same frame with the same target has the applied mask's keys (also on a duplicated clip): a second
    /// run that is canceled or not applied must leave that mask's mattes alone.
    @Test func aSecondRunLeavesTheAppliedCoverAloneUntilItIsTakenOver() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = anonymizer(url)
        let found = try #require(try await a.findPeople(at: 0.5))
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .face)
        let media = UUID(), store = MagicMatteStore(directory: nil)
        let key = try #require(pick.partKey(media: media)), personKey = pick.cacheKey(media: media)
        let first = try await a.run([pick], media: media, first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        Anonymizer.commit(first.staged, store: store)
        let before = try #require(store.matte(key: key, pts: 2.0 / 24))
        func staged() -> [String] { store.writtenKeys.filter { $0.hasPrefix(MagicMatteStore.stagedPrefix) && !store.times(key: $0).isEmpty } }
        #expect(staged().isEmpty)

        // Canceled: it throws, its staged mattes are gone, the cover is as it was.
        let task = Task { try await a.run([pick], media: media, first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(staged().isEmpty)
        #expect(store.times(key: key).count == 24 && store.times(key: personKey).count == 24)
        #expect(store.matte(key: key, pts: 2.0 / 24) == before)

        // Finished but refused (the clip changed meanwhile): discarded, the cover is as it was.
        let second = try await a.run([pick], media: media, first: 0.5, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        #expect(store.times(key: key).count == 24)
        Anonymizer.discard(second.staged, store: store)
        #expect(staged().isEmpty && store.times(key: key).count == 24)

        // Taken over on a shorter clip: the frames it did not follow stay covered.
        let third = try await a.run([pick], media: media, first: 0.5, last: 23.0 / 24, frameGap: 1.0 / 24, store: store)
        #expect(third.frames == 12)
        Anonymizer.commit(third.staged, store: store)
        #expect(staged().isEmpty)
        #expect(store.times(key: key).count == 24 && store.times(key: personKey).count == 24)
        #expect(store.matte(key: key, pts: 2.0 / 24) == before)
    }

    /// Track on a Face mask from a frame in the middle: the pass continues from the stored whole person and starts with
    /// the face place stored there; flags are reported.
    @Test func trackOnAFaceMaskContinuesFromTheStoredPerson() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = anonymizer(url)
        let found = try #require(try await a.findPeople(at: 0))
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .face)
        let media = UUID(), store = MagicMatteStore(directory: nil)
        let key = try #require(pick.partKey(media: media)), personKey = pick.cacheKey(media: media)
        let out = try await a.run([pick], media: media, first: 0, last: 12.0 / 24, frameGap: 1.0 / 24, store: store)
        Anonymizer.commit(out.staged, store: store)
        #expect(store.times(key: key).count == 13)
        // From frame 12 on with a detector that sees no face: every frame is flagged and covered where the face was.
        let from = 12.0 / 24
        let seed = (person: try #require(store.matte(key: personKey, pts: from)), narrowed: try #require(store.matte(key: key, pts: from)))
        let refiner = AnonymizeFrameRefiner(part: .face, detector: PatchDetector(faceUntil: -1), seed: seed)
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let r = try await tracker.track(key: personKey, points: pick.points, from: from, to: 23.0 / 24, store: store, refinedKey: key,
                                        refine: { pb, pts, m in try refiner.apply(pb, pts, m) })
        #expect(r.frames == 12 && !r.lost)
        #expect(store.times(key: key).count == 24 && store.times(key: personKey).count == 24)
        #expect(refiner.flags.count == 12 && refiner.flags.allSatisfy { $0.reason == .noFace })
        let face = try #require(store.matte(key: key, pts: 20.0 / 24)), person = try #require(store.matte(key: personKey, pts: 20.0 / 24))
        let fc = try #require(face.centroid), pc = try #require(person.centroid)
        #expect(abs(fc.x / Double(face.width) * 320 - Double(80 + 4 * 20)) < 8)
        #expect(fc.y / Double(face.height) < pc.y / Double(person.height) - 0.03 && face.area < person.area)
    }

    @Test func aCanceledRunThrows() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = anonymizer(url)
        let found = try #require(try await a.findPeople(at: 0))
        let pick = Anonymizer.selection(try #require(found.people.first), pts: found.pts, target: .face)
        let store = MagicMatteStore(directory: nil)
        let task = Task { try await a.run([pick], media: UUID(), first: 0, last: 23.0 / 24, frameGap: 1.0 / 24, store: store) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // Nothing stays behind.
        #expect(store.writtenKeys.allSatisfy { store.times(key: $0).isEmpty })
    }
}

/// A mask made by Anonymize always covers: when in doubt more, never nothing.
@Suite struct AnonymizeFallbackMatteTests {
    private func box(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> SubjectMatte {
        var v = [Float](repeating: 0, count: 100 * 100)
        for y in y0..<y1 { for x in x0..<x1 { v[y * 100 + x] = 1 } }
        return SubjectMatte(width: 100, height: 100, values: v)
    }

    /// A clip with one Face mask and its cover; `tracked`: frames 0...11 at 24 fps are stored (person x 30..<70, face 40..<60).
    private func scene(tracked: Bool = true) throws -> (store: MagicMatteStore, clip: Clip, mask: UUID, base: String, part: String) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let pick = MagicSelection(points: [MagicPoint(position: Vec2(0.5, 0.3), subtract: false, sourceTime: .zero)], part: .face)
        let ids = c.addAnonymize([pick], target: .face, cover: .mosaic, subjectWidth: 20, frameWidth: 100, frameHeight: 100)
        let sel = try #require(c.masks.first?.magic)
        let base = sel.cacheKey(media: c.media), part = try #require(sel.partKey(media: c.media))
        let store = MagicMatteStore(directory: nil)
        if tracked {
            for i in 0..<12 {
                store.put(box(30, 70, 10, 100), key: base, pts: Double(i) / 24)
                store.put(box(40, 60, 10, 40), key: part, pts: Double(i) / 24)
            }
        }
        return (store, c, try #require(ids.first), base, part)
    }

    private func covered(_ m: SubjectMatte, _ x: Double, _ y: Double) -> Bool {
        m.values[min(Int(y * Double(m.height)), m.height - 1) * m.width + min(Int(x * Double(m.width)), m.width - 1)] > 0.5
    }

    @Test func aTrackedFrameDrawsItsOwnMatte() throws {
        let s = try scene()
        let m = try #require(s.store.mattes(for: s.clip.effects(at: .zero), pts: 5.0 / 24, frameWidth: 100)[s.mask])
        #expect(covered(m, 0.5, 0.2) && !covered(m, 0.35, 0.2) && !covered(m, 0.5, 0.8))
    }

    /// The narrowed matte of a frame is gone (deleted from the keyframe lane, file lost): the whole person of that frame.
    @Test func aFrameWithoutItsFaceMatteCoversTheWholePerson() throws {
        let s = try scene()
        s.store.removeFrames(key: s.part, times: [5.0 / 24])
        let m = try #require(s.store.mattes(for: s.clip.effects(at: .zero), pts: 5.0 / 24, frameWidth: 100)[s.mask])
        #expect(covered(m, 0.5, 0.2) && covered(m, 0.35, 0.2) && covered(m, 0.5, 0.8) && !covered(m, 0.1, 0.5))
    }

    /// The person was lost, or a trim / slip revealed frames after the run: the nearest tracked matte, grown, the more the
    /// further away it is.
    @Test func aFrameOutsideTheTrackedRangeCoversTheNearestMatteGrown() throws {
        let s = try scene()
        let fx = s.clip.effects(at: .zero)
        let near = try #require(s.store.mattes(for: fx, pts: 0.6, frameWidth: 100)[s.mask])      // 0.14 s after the last frame
        let far = try #require(s.store.mattes(for: fx, pts: 5, frameWidth: 100)[s.mask])
        let person = box(30, 70, 10, 100)
        // The whole person (not only the face) and a margin around it.
        #expect(covered(near, 0.35, 0.8) && covered(near, 0.27, 0.5) && covered(near, 0.72, 0.5) && !covered(near, 0.1, 0.5))
        #expect(near.area > person.area && far.area > near.area)
        #expect(covered(far, 0.18, 0.5) && covered(far, 0.82, 0.5))
        // Before the first tracked frame too.
        var early = s.clip
        early.source = TimeRange(start: Time(2, 1), duration: Time(2, 1))
        let again = try #require(s.store.mattes(for: early.effects(at: .zero), pts: 2, frameWidth: 100)[s.mask])
        #expect(again.area > near.area)
        // Made once per tracked frame and step, then reused.
        let n = s.store.decodes
        _ = s.store.mattes(for: fx, pts: 5.04, frameWidth: 100)
        #expect(s.store.decodes == n)
    }

    @Test func noMatteAtAllCoversTheWholeFrame() throws {
        let s = try scene(tracked: false)
        let m = try #require(s.store.mattes(for: s.clip.effects(at: .zero), pts: 1, frameWidth: 100)[s.mask])
        #expect(m.values.allSatisfy { $0 == 1 })
        // Only the narrowed mattes exist (an old cache): the nearest of them, grown.
        s.store.put(box(40, 60, 10, 40), key: s.part, pts: 0)
        let g = try #require(s.store.mattes(for: s.clip.effects(at: .zero), pts: 1, frameWidth: 100)[s.mask])
        #expect(covered(g, 0.33, 0.2) && covered(g, 0.5, 0.48) && g.area > box(40, 60, 10, 40).area)
    }

    /// The Gyroflow Stabilizer warps the source frame before the effects: mattes tracked on the file do not fit.
    @Test func aWarpedSourceCoversTheWholeFrame() throws {
        let s = try scene()
        let m = try #require(s.store.mattes(for: s.clip.effects(at: .zero), pts: 5.0 / 24, frameWidth: 100, warped: true)[s.mask])
        #expect(m.values.allSatisfy { $0 == 1 })
    }

    @Test func anOrdinaryMagicMaskStillCoversNothingWhereItIsNotTracked() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        var m = ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.3), subtract: false, sourceTime: .zero)])
        m.usedByOpacity = true
        c.masks = [m]
        let store = MagicMatteStore(directory: nil)
        let key = try #require(m.magic?.cacheKey(media: c.media))
        store.put(box(30, 70, 10, 100), key: key, pts: 0)
        let fx = c.effects(at: .zero)
        #expect(store.mattes(for: fx, pts: 0, frameWidth: 100)[m.id] != nil)
        #expect(store.mattes(for: fx, pts: 1, frameWidth: 100).isEmpty)
        #expect(store.mattes(for: fx, pts: 0, frameWidth: 100, warped: true)[m.id] != nil)
        // An old build wrote the file without `part`: the same key, the whole person.
        var face = m.magic!
        face.part = .face
        #expect(face.cacheKey(media: c.media) == key)
    }

    @Test func stagedFilesOfARunThatNeverEndedAreRemovedOnStart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-staged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = MagicMatteStore(directory: dir)
        a.put(box(30, 70, 10, 100), key: MagicMatteStore.stagedPrefix + "ab-k", pts: 0)
        a.save(key: MagicMatteStore.stagedPrefix + "ab-k")
        a.put(box(30, 70, 10, 100), key: "k", pts: 0)
        a.save(key: "k")
        let b = MagicMatteStore(directory: dir)
        #expect(b.times(key: MagicMatteStore.stagedPrefix + "ab-k").isEmpty && b.times(key: "k") == [0])
    }
}
