import Foundation
import Testing
@testable import SQCore

@Suite struct RelinkScoringTests {
    private func ref(_ name: String, size: Int64 = 100, seconds: Int64? = 10, path: String = "/gone/Day1", modified: Date? = nil) -> MediaRef {
        var m = MediaRef(name: name, path: path + "/" + name, fingerprint: MediaFingerprint(size: size, modified: modified))
        m.duration = seconds.map { Time($0, 1) }
        return m
    }
    private func cand(_ path: String, size: Int64 = 100, seconds: Int64? = 10, modified: Date? = nil) -> RelinkCandidate {
        RelinkCandidate(path: path, size: size, modified: modified, duration: seconds.map { Time($0, 1) })
    }

    @Test func nameSizeAndLengthIsAStrongCheckedMatch() {
        let a = ref("C0101.MP4")
        let r = RelinkScorer.propose(missing: [a], candidates: [cand("/new/c0101.mp4")])
        #expect(r.proposals.count == 1)
        let p = r.proposals[0]
        #expect(p.path == "/new/c0101.mp4" && p.tier == .strong && p.isChecked)
        #expect(p.signals.isSuperset(of: [.name, .size, .duration]))
        #expect(r.unmatched.isEmpty)
    }

    @Test func equalSizeTieIsDecidedByMoreSignalsNotByOrder() {
        let when = Date(timeIntervalSince1970: 1_000_000)
        let a = ref("A.mov", modified: when)
        let plain = cand("/x/A.mov"), better = cand("/y/A.mov", modified: when)
        for order in [[plain, better], [better, plain]] {
            let r = RelinkScorer.propose(missing: [a], candidates: order)
            #expect(r.proposals.first?.path == "/y/A.mov")
            #expect(r.proposals.first?.signals.contains(.modified) == true)
        }
    }

    @Test func fullTieStaysDeterministicButIsNotChecked() {
        let a = ref("A.mov", path: "/gone/Day1")
        let one = cand("/q/1/A.mov"), two = cand("/q/2/A.mov")
        let r1 = RelinkScorer.propose(missing: [a], candidates: [one, two])
        let r2 = RelinkScorer.propose(missing: [a], candidates: [two, one])
        #expect(r1.proposals.first?.path == "/q/1/A.mov" && r2.proposals.first?.path == "/q/1/A.mov")
        #expect(r1.proposals.first?.isAmbiguous == true && r1.proposals.first?.isChecked == false)
    }

    @Test func folderStructureBreaksTheTie() {
        let a = ref("A.mov", path: "/Volumes/Old/Shoot/Day2")
        let r = RelinkScorer.propose(missing: [a], candidates: [cand("/n/Other/A.mov"), cand("/n/Shoot/Day2/A.mov")])
        #expect(r.proposals.first?.path == "/n/Shoot/Day2/A.mov")
        #expect(r.proposals.first?.isChecked == true)
    }

    @Test func renamedCopyWithSameLengthIsWeakAndUnchecked() {
        let a = ref("intro.mov", size: 500)
        let r = RelinkScorer.propose(missing: [a], candidates: [cand("/n/intro (1).mov", size: 777)])
        let p = r.proposals.first
        #expect(p?.path == "/n/intro (1).mov")
        #expect(p?.tier == .weak && p?.isChecked == false)
        #expect(p?.signals.contains(.size) == false)
    }

    @Test func sameNameOtherSizeNeverStrong() {
        let a = ref("A.mov", size: 100)
        let r = RelinkScorer.propose(missing: [a], candidates: [cand("/n/A.mov", size: 999)])
        #expect(r.proposals.first?.tier == .weak)
    }

    @Test func unrelatedFileIsNotProposed() {
        let a = ref("A.mov")
        let r = RelinkScorer.propose(missing: [a], candidates: [cand("/n/Z.mov", size: 5, seconds: 99)])
        #expect(r.proposals.isEmpty && r.unmatched == [a.id])
    }

    @Test func oneFileServesOneMediaItem() {
        let a = ref("A.mov", path: "/gone/Day1"), b = ref("A.mov", path: "/gone/Day2")
        let r = RelinkScorer.propose(missing: [a, b], candidates: [cand("/n/Day2/A.mov")])
        #expect(r.proposals.count == 1 && r.unmatched.count == 1)
        #expect(r.proposals.first?.mediaID == b.id)
    }

    @Test func unknownRecordedSizeNameOnlyIsWeakButNameAndLengthIsStrong() {
        let a = ref("A.mov", size: 0)
        let nameOnly = RelinkScorer.propose(missing: [a], candidates: [cand("/n/A.mov", seconds: nil)])
        #expect(nameOnly.proposals.first?.tier == .weak)
        let withLength = RelinkScorer.propose(missing: [a], candidates: [cand("/n/A.mov")])
        #expect(withLength.proposals.first?.tier == .strong)
    }

    @Test func worthProbingOnlyForNameOrSizeHits() {
        let a = ref("A.mov", size: 100)
        #expect(RelinkScorer.worthProbing(cand("/n/A.mov", size: 5), for: [a]))
        #expect(RelinkScorer.worthProbing(cand("/n/zzz.mov", size: 100), for: [a]))
        #expect(!RelinkScorer.worthProbing(cand("/n/zzz.mov", size: 5), for: [a]))
    }

    @Test func healthCountsFolderOutsideAndMissing() {
        let url = URL(fileURLWithPath: "/P/Show/Show.sqproj")
        let inside = ref("a.mov", path: "/P/Show/Files"), outside = ref("b.mov", path: "/Users/x"), gone = ref("c.mov", path: "/Users/y")
        let h = ProjectHealth.make(media: [inside, outside, outside, gone], offline: [gone.id], projectURL: url)
        #expect(h.inFolder == 1 && h.outside == 1 && h.missing == 1 && !h.isHealthy)
        #expect(ProjectHealth.make(media: [inside], offline: [], projectURL: url).isHealthy)
        let loose = ProjectHealth.make(media: [outside], offline: [], projectURL: nil)
        #expect(loose.outside == 0 && loose.isHealthy)
    }
}
