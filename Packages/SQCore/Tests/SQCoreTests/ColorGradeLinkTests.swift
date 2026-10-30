import Foundation
import Testing
@testable import SQCore

/// COLOR-GRADE-LINKS: linked grades (`Clip.gradeLink`), range grades (`ClipEffect.colorRange`), v45.
@Suite struct ColorGradeLinkTests {
    static let fd = Time(1, 25)

    static func clip(_ name: String, media: UUID = UUID(), start: Time = .zero, seconds: Int64 = 4) -> Clip {
        Clip(name: name, media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)),
             start: start, mediaDuration: Time(20, 1))
    }

    static func warm(_ t: Float = 20) -> ClipEffect {
        var e = ColorEffect(id: 1); e.basic.temperature = t
        return ClipEffect.colorGrade(e)
    }

    static func project(_ clips: [Clip], audio: [Clip] = []) -> Project {
        var tracks = [Track(kind: .video, clips: clips)]
        if !audio.isEmpty { tracks.append(Track(kind: .audio, clips: audio)) }
        return Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: tracks)])
    }

    static func find(_ p: Project, _ id: Clip.ID) -> Clip {
        p.timelines.lazy.flatMap(\.tracks).flatMap(\.clips).first { $0.id == id }!
    }

    static func temperature(_ c: Clip) -> Float { c.color.effects.first?.basic.temperature ?? 0 }

    static func writtenVersion(_ p: Project) throws -> Int {
        let obj = try JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any]
        return obj?["formatVersion"] as? Int ?? -1
    }

    /// Simulates one panel edit on `id` and runs the session's propagation step.
    static func edit(_ p: inout Project, _ id: Clip.ID, temperature t: Float) {
        let old = p
        p.forEachClipInPlace { c in
            guard c.id == id else { return }
            var col = c.color; col.effects[0].basic.temperature = t; c.color = col
        }
        p.propagateGradeLinks(from: old)
    }

    // MARK: Link

    @Test func linkingCopiesTheSourceGradeAndSharesOneID() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(30)]
        let b = Self.clip("B", start: Time(4, 1)), c = Self.clip("C", start: Time(8, 1))
        var p = Self.project([a, b, c])
        let linkOpt = p.linkGrades([a.id, b.id, c.id], source: a.id)
        let link = try #require(linkOpt)
        for id in [a.id, b.id, c.id] {
            #expect(Self.find(p, id).gradeLink == link)
            #expect(Self.temperature(Self.find(p, id)) == 30)
        }
        #expect(Set(p.gradeLinkMembers(of: b.id)) == [a.id, b.id, c.id])
    }

    @Test func linkingNeedsTwoPictureClips() {
        let a = Self.clip("A")
        let sound = Clip(name: "s", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var p = Self.project([a], audio: [sound])
        let none = p.linkGrades([a.id, sound.id], source: a.id)
        #expect(none == nil)
        #expect(Self.find(p, a.id).gradeLink == nil)
        #expect(Self.find(p, sound.id).gradeLink == nil)
    }

    @Test func editingOneMemberUpdatesAllAndLeavesOthers() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1)), loose = Self.clip("L", start: Time(8, 1))
        var p = Self.project([a, b, loose])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        Self.edit(&p, b.id, temperature: -25)
        #expect(Self.temperature(Self.find(p, a.id)) == -25)
        #expect(Self.temperature(Self.find(p, b.id)) == -25)
        #expect(Self.temperature(Self.find(p, loose.id)) == 0)
    }

    @Test func propagationKeepsTheTargetsEffectIDsAndFootageInterpretation() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        var b = Self.clip("B", start: Time(4, 1)); b.footageColor = ClipFootageColor(source: .sLog3SGamut3Cine)
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        let idBefore = Self.find(p, b.id).colorGradeEffects[0].id
        Self.edit(&p, a.id, temperature: 40)
        let nb = Self.find(p, b.id)
        #expect(nb.colorGradeEffects[0].id == idBefore)
        #expect(nb.footageColor.source == .sLog3SGamut3Cine)
        #expect(Self.temperature(nb) == 40)
    }

    @Test func propagationSharesKeysAndTheFxSwitch() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        let b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        let old = p
        p.forEachClipInPlace { c in
            guard c.id == a.id else { return }
            c.effects[0].enabled = false
            var prop = c.effects[0].parameters[ClipEffect.colorExposureKey] ?? AnimatedProperty(0)
            prop.track.insert(Keyframe(time: .zero, value: 0, interpolation: .linear))
            prop.track.insert(Keyframe(time: Time(1, 1), value: 2, interpolation: .linear))
            c.effects[0].parameters[ClipEffect.colorExposureKey] = prop
        }
        p.propagateGradeLinks(from: old)
        let nb = Self.find(p, b.id)
        #expect(nb.colorGradeEffects[0].enabled == false)
        #expect(nb.colorGradeEffects[0].parameters[ClipEffect.colorExposureKey]?.track.keys.count == 2)
    }

    @Test func embeddedLUTsAreAdaptedToEachMembersMedia() throws {
        let ma = UUID(), mb = UUID()
        var a = Self.clip("A", media: ma)
        var e = ColorEffect(id: 1); e.inputLUT = .embedded(ma)
        a.effects = [ClipEffect.colorGrade(e)]
        let b = Self.clip("B", media: mb, start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        #expect(Self.find(p, b.id).color.effects[0].inputLUT == .automatic)
        // An edit on the target does not push its adapted LUT back over the source's embedded one.
        Self.edit(&p, b.id, temperature: 5)
        #expect(Self.find(p, a.id).color.effects[0].inputLUT == .embedded(ma))
        #expect(Self.find(p, b.id).color.effects[0].inputLUT == .automatic)
        #expect(Self.temperature(Self.find(p, a.id)) == 5)
        Self.edit(&p, a.id, temperature: 7)
        #expect(Self.find(p, b.id).color.effects[0].inputLUT == .automatic)
        #expect(Self.temperature(Self.find(p, b.id)) == 7)
    }

    @Test func unlinkingLeavesTheGradeAndDissolvesAOneMemberGroup() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        Self.edit(&p, a.id, temperature: 12)
        let unlinked = p.unlinkGrades([b.id])
        #expect(unlinked)
        #expect(Self.find(p, b.id).gradeLink == nil)
        #expect(Self.find(p, a.id).gradeLink == nil)       // alone now: no group
        #expect(Self.temperature(Self.find(p, b.id)) == 12)
        Self.edit(&p, a.id, temperature: 50)
        #expect(Self.temperature(Self.find(p, b.id)) == 12)
    }

    @Test func aDeletedMemberDissolvesTheGroupInThePropagationPass() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        let old = p
        p.timelines[0].tracks[0].remove(b.id)
        p.propagateGradeLinks(from: old)
        #expect(Self.find(p, a.id).gradeLink == nil)
    }

    @Test func joiningALinkedClipReusesItsGroup() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1)), c = Self.clip("C", start: Time(8, 1))
        var p = Self.project([a, b, c])
        let linkOpt = p.linkGrades([a.id, b.id], source: a.id)
        let link = try #require(linkOpt)
        let joined = p.linkGrades([c.id, b.id], source: b.id)
        #expect(joined == link)
        #expect(Set(p.gradeLinkMembers(of: a.id)) == [a.id, b.id, c.id])
    }

    @Test func linkAllClipsOfTheSourceLinksEveryPictureClipOfThatMedia() throws {
        let m = UUID()
        var a = Self.clip("A", media: m); a.effects = [Self.warm(7)]
        let b = Self.clip("B", media: m, start: Time(4, 1)), other = Self.clip("O", start: Time(8, 1))
        var p = Self.project([a, b, other])
        p.timelines.append(Timeline(name: "T2", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [Self.clip("C", media: m)])]))
        let linkOpt = p.linkAllClipsOfSource(a.id)
        let link = try #require(linkOpt)
        #expect(p.gradeLinkMembers(of: a.id).count == 3)
        #expect(Self.find(p, other.id).gradeLink == nil)
        #expect(p.timelines[1].tracks[0].clips[0].gradeLink == link)
        #expect(Self.temperature(p.timelines[1].tracks[0].clips[0]) == 7)
    }

    @Test func membersInOtherSequencesFollowToo() throws {
        let a = Self.clip("A"), c = Self.clip("C")
        var p = Self.project([a])
        p.timelines.append(Timeline(name: "T2", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [c])]))
        let linked = p.linkGrades([a.id, c.id], source: a.id)
        #expect(linked != nil)
        Self.edit(&p, a.id, temperature: 33)
        #expect(Self.temperature(p.timelines[1].tracks[0].clips[0]) == 33)
    }

    @Test func removingTheGradeOfOneMemberRemovesItFromAll() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        let b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        let old = p
        p.forEachClipInPlace { c in if c.id == a.id { c.replaceColorGrade(with: []) } }
        p.propagateGradeLinks(from: old)
        #expect(Self.find(p, b.id).colorGradeEffects.isEmpty)
    }

    // MARK: Range grades

    @Test func aRangeGradeRendersOnlyInsideItsRange() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        let fxOpt = a.addRangeGrade(TimeRange(start: Time(1, 1), end: Time(2, 1)))
        let fx = try #require(fxOpt)
        var e = a.color; e.effects[1].basic.exposure = 1; a.color = e
        #expect(a.colorGradeEffects.last?.id == fx)
        #expect(a.renderColor(atLocal: Time(1, 2)).effects.count == 1)
        #expect(a.renderColor(atLocal: Time(3, 2)).effects.count == 2)
        #expect(a.renderColor(atLocal: Time(2, 1)).effects.count == 1)    // end is exclusive
    }

    @Test func aRangeGradeOnAClipWithoutGradeAddsANeutralFirstEffect() throws {
        var a = Self.clip("A")
        let added = a.addRangeGrade(TimeRange(start: Time(1, 1), end: Time(2, 1)))
        #expect(added != nil)
        #expect(a.colorGradeEffects.count == 2)
        #expect(a.colorGradeEffects[0].colorRange == nil)
        #expect(a.colorGradeEffects[1].colorRange != nil)
    }

    @Test func aRangeIsClippedToTheClipAndRefusedWhenEmpty() {
        var a = Self.clip("A")
        let missed = a.addRangeGrade(TimeRange(start: Time(5, 1), end: Time(6, 1)))
        #expect(missed == nil)
        let id = a.addRangeGrade(TimeRange(start: Time(3, 1), end: Time(9, 1)))
        #expect(id != nil)
        #expect(a.colorGradeEffects.last?.colorRange == TimeRange(start: Time(3, 1), end: Time(4, 1)))
    }

    @Test func theFirstColourEffectNeverTakesARange() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        let firstRefused = a.setColorRange(a.effects[0].id, TimeRange(start: .zero, end: Time(1, 1)))
        #expect(!firstRefused)
        let idOpt = a.addRangeGrade(TimeRange(start: .zero, end: Time(1, 1)))
        let id = try #require(idOpt)
        let moved = a.setColorRange(id, TimeRange(start: Time(2, 1), end: Time(3, 1)))
        #expect(moved)
        let cleared = a.setColorRange(id, nil)
        #expect(cleared)
        #expect(a.colorGradeEffects[1].colorRange == nil)
    }

    @Test func aRangeFollowsAHeadTrimLikeKeys() throws {
        var a = Self.clip("A", start: Time(10, 1))
        a.source = TimeRange(start: Time(2, 1), duration: Time(4, 1))
        let added = a.addRangeGrade(TimeRange(start: Time(2, 1), end: Time(3, 1)))
        #expect(added != nil)
        let shifted = a.effects.map { $0.shifted(by: Time(1, 1)) }
        #expect(shifted.last?.colorRange == TimeRange(start: Time(3, 1), end: Time(4, 1)))
        let mirrored = a.effects.last!.remapped { Time(4, 1) - $0 }
        #expect(mirrored.colorRange == TimeRange(start: Time(1, 1), end: Time(2, 1)))
    }

    @Test func rangeGradesAreNotSharedByALink() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        let old = p
        p.forEachClipInPlace { c in if c.id == a.id { _ = c.addRangeGrade(TimeRange(start: .zero, end: Time(1, 1))) } }
        p.propagateGradeLinks(from: old)
        #expect(Self.find(p, a.id).colorGradeEffects.count == 2)
        #expect(Self.find(p, b.id).colorGradeEffects.count == 1)    // the neutral base effect only
        // And a base edit keeps the target's own range grade.
        p.forEachClipInPlace { c in if c.id == b.id { _ = c.addRangeGrade(TimeRange(start: Time(2, 1), end: Time(3, 1))) } }
        Self.edit(&p, a.id, temperature: 9)
        let nb = Self.find(p, b.id)
        #expect(nb.colorGradeEffects.count == 2)
        #expect(nb.colorGradeEffects[1].colorRange == TimeRange(start: Time(2, 1), end: Time(3, 1)))
        #expect(Self.temperature(nb) == 9)
    }

    @Test func pasteClipsRangesToTheTarget() throws {
        var a = Self.clip("A", seconds: 8); a.effects = [Self.warm(10)]
        let added = a.addRangeGrade(TimeRange(start: Time(5, 1), end: Time(7, 1)))
        #expect(added != nil)
        let added2 = a.addRangeGrade(TimeRange(start: Time(2, 1), end: Time(6, 1)))
        #expect(added2 != nil)
        var b = Self.clip("B", seconds: 4)
        b.replaceColorGrade(with: a.colorGradeEffects)
        #expect(b.colorGradeEffects.count == 2)
        #expect(b.colorGradeEffects[1].colorRange == TimeRange(start: Time(2, 1), end: Time(4, 1)))
    }

    // MARK: File

    @Test func linksAndRangesAreWrittenAsV45AndRoundTrip() throws {
        let a = Self.clip("A"), b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let linked = p.linkGrades([a.id, b.id], source: a.id)
        #expect(linked != nil)
        #expect(p.containsGradeLinksOrRanges)
        #expect(try Self.writtenVersion(p) == 45)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)

        var c = Self.clip("C")
        let added = c.addRangeGrade(TimeRange(start: Time(1, 1), end: Time(2, 1)))
        #expect(added != nil)
        let q = Self.project([c])
        #expect(try Self.writtenVersion(q) == 45)
        let backQ = try ProjectFile.decode(ProjectFile.encode(q), migrations: ProjectFile.migrations)
        #expect(backQ == q)
    }

    @Test func withoutLinksOrRangesTheLowestVersionIsKept() throws {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        let p = Self.project([a])
        #expect(!p.containsGradeLinksOrRanges)
        #expect(try Self.writtenVersion(p) == 36)
        #expect(ProjectFile.currentVersion >= 45)
    }

    // MARK: Review fixes

    /// A clip with a keyed exposure on its base grade (keys at 0 s and 1 s), linked to a plain clip B.
    static func linkedKeyedPair() throws -> (Project, Clip.ID, Clip.ID) {
        var a = Self.clip("A"); a.effects = [Self.warm(10)]
        var prop = AnimatedProperty(0.0)
        prop.track.insert(Keyframe(time: .zero, value: 0, interpolation: .linear))
        prop.track.insert(Keyframe(time: Time(1, 1), value: 2, interpolation: .linear))
        a.effects[0].parameters[ClipEffect.colorExposureKey] = prop
        let b = Self.clip("B", start: Time(4, 1))
        var p = Self.project([a, b])
        let link = p.linkGrades([a.id, b.id], source: a.id); #expect(link != nil)
        return (p, a.id, b.id)
    }

    static func exposureKeyTimes(_ c: Clip) -> [Time] {
        c.colorGradeEffects[0].parameters[ClipEffect.colorExposureKey]?.track.keys.map(\.time) ?? []
    }

    static func timingEdit(_ p: inout Project, _ id: Clip.ID, _ f: (inout Clip) -> Void) {
        let old = p
        p.forEachClipInPlace { c in if c.id == id { f(&c) } }
        p.propagateGradeLinks(from: old)
    }

    @Test func headTrimRetimeAndCropOnAMemberDoNotMoveTheOthersKeys() throws {
        var (p, a, b) = try Self.linkedKeyedPair()
        Self.timingEdit(&p, a) { c in c.extendHead(by: Time(-1, 2)); c.start = c.start + Time(1, 2) }
        #expect(Self.exposureKeyTimes(Self.find(p, a)) == [Time(-1, 2), Time(1, 2)])
        #expect(Self.exposureKeyTimes(Self.find(p, b)) == [.zero, Time(1, 1)])
        Self.timingEdit(&p, a) { c in c.rescaleKeys(from: Time(7, 2), to: Time(7, 1), mirror: false); c.speed = ClipSpeed(percent: 50) }
        #expect(Self.exposureKeyTimes(Self.find(p, b)) == [.zero, Time(1, 1)])
        Self.timingEdit(&p, a) { c in c.rescaleKeys(from: Time(7, 1), to: Time(7, 1), mirror: true); c.reversed.toggle() }
        #expect(Self.exposureKeyTimes(Self.find(p, b)) == [.zero, Time(1, 1)])
        Self.timingEdit(&p, a) { c in c = c.cropped(to: TimeRange(start: c.start + Time(1, 1), duration: Time(2, 1)))! }
        #expect(Self.exposureKeyTimes(Self.find(p, b)) == [.zero, Time(1, 1)])
    }

    @Test func aRealKeyMoveStillPropagates() throws {
        var (p, a, b) = try Self.linkedKeyedPair()
        Self.timingEdit(&p, a) { c in
            var prop = c.effects[0].parameters[ClipEffect.colorExposureKey]!
            prop.track.keys[1].time = Time(2, 1)
            c.effects[0].parameters[ClipEffect.colorExposureKey] = prop
        }
        #expect(Self.exposureKeyTimes(Self.find(p, b)) == [.zero, Time(2, 1)])
    }

    @Test func aMemberWithItsOwnEmbeddedLUTKeepsItAndNeverPushesItBack() throws {
        let ma = UUID(), mb = UUID()
        var a = Self.clip("A", media: ma)
        var ea = ColorEffect(id: 1); ea.inputLUT = .embedded(ma)
        a.effects = [ClipEffect.colorGrade(ea)]
        var b = Self.clip("B", media: mb, start: Time(4, 1))
        var eb = ColorEffect(id: 1); eb.inputLUT = .embedded(mb)
        b.effects = [ClipEffect.colorGrade(eb)]
        var p = Self.project([a, b])
        let link = p.linkGrades([a.id, b.id], source: a.id); #expect(link != nil)
        #expect(Self.find(p, b.id).color.effects[0].inputLUT == .embedded(mb))
        Self.edit(&p, b.id, temperature: 9)
        #expect(Self.find(p, a.id).color.effects[0].inputLUT == .embedded(ma))
        #expect(Self.temperature(Self.find(p, a.id)) == 9)
        // A deliberate LUT change on one member is shared (a file LUT means the same everywhere).
        let old = p
        p.forEachClipInPlace { c in
            guard c.id == a.id else { return }
            var col = c.color; col.effects[0].inputLUT = .file("/x.cube"); c.color = col
        }
        p.propagateGradeLinks(from: old)
        #expect(Self.find(p, b.id).color.effects[0].inputLUT == .file("/x.cube"))
    }

    @Test func propagationKeepsEachMembersRangeGradeInItsPlace() throws {
        var a = Self.clip("A")
        var r = Self.warm(40); r.colorRange = TimeRange(start: Time(1, 1), duration: Time(1, 1))
        a.effects = [Self.warm(10), r, Self.warm(-5)]
        var b = a; b.id = UUID(); b.start = Time(4, 1)
        b.effects = b.effects.map { var e = $0; e.id = UUID(); return e }
        var p = Self.project([a, b])
        let link = p.linkGrades([a.id, b.id], source: a.id); #expect(link != nil)
        #expect(Self.find(p, b.id).colorGradeEffects.map(\.isRangeGrade) == [false, true, false])
        Self.edit(&p, a.id, temperature: 15)
        let nb = Self.find(p, b.id)
        #expect(nb.colorGradeEffects.map(\.isRangeGrade) == [false, true, false])
        #expect(nb.renderColor(atLocal: Time(3, 2)) == Self.find(p, a.id).renderColor(atLocal: Time(3, 2)))
    }

    @Test func aFrameHoldOfARangeGradeShowsTheHeldFramesColour() throws {
        var c = Self.clip("A")
        var r = Self.warm(40); r.colorRange = TimeRange(start: Time(1, 1), duration: Time(1, 1))
        c.effects = [Self.warm(10), r]
        for t in [Time(3, 2), Time(3, 1)] {
            var tl = Timeline(name: "T", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [c])])
            let id = try tl.insertFrameHold(of: c.id, at: t, duration: Time(2, 1))
            let hold = try #require(tl.tracks[0].clips.first { $0.id == id })
            let want = c.renderColor(atLocal: t)
            for l in [Time.zero, Time(1, 1), Time(19, 10)] { #expect(hold.renderColor(atLocal: l) == want) }
        }
    }
}
