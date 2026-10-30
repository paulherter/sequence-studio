import Foundation
import Testing
@testable import SQCore

@Suite struct SmartBinTests {
    func media(_ name: String, label: LabelColor? = nil, path: String? = nil) -> MediaRef {
        MediaRef(name: name, path: path ?? "/x/\(name).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1), label: label)
    }

    @Test func rulesMatch() {
        let m = media("Interview A")
        #expect(SmartBin(name: "s", text: "interview").matches(m, isUsed: false, isOffline: false))
        #expect(!SmartBin(name: "s", text: "broll").matches(m, isUsed: false, isOffline: false))
        #expect(SmartBin(name: "s", usage: .unused).matches(m, isUsed: false, isOffline: false))
        #expect(!SmartBin(name: "s", usage: .unused).matches(m, isUsed: true, isOffline: false))
        #expect(SmartBin(name: "s", usage: .used).matches(m, isUsed: true, isOffline: false))
        #expect(!SmartBin(name: "s", offlineOnly: true).matches(m, isUsed: false, isOffline: false))
        #expect(SmartBin(name: "s", offlineOnly: true).matches(m, isUsed: false, isOffline: true))
        #expect(!SmartBin(name: "s", label: .rose).matches(m, isUsed: false, isOffline: false))
        #expect(SmartBin(name: "s", kind: .image).matches(media("p", path: "/x/p.png"), isUsed: false, isOffline: false))
        #expect(!SmartBin(name: "s", kind: .image).matches(m, isUsed: false, isOffline: false))
    }

    @Test func addUpdateRemoveRoundTrip() throws {
        var p = Project(name: "P")
        let r0 = p.addSmartBin(SmartBin(name: " ")); #expect(!r0)
        var b = SmartBin(name: "Unused", usage: .unused)
        let r1 = p.addSmartBin(b); #expect(r1)
        b.name = "Spare"
        let r2 = p.updateSmartBin(b); #expect(r2)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.smartBinList == [b])
        let r3 = p.removeSmartBin(b.id); #expect(r3)
        #expect(p.smartBins == nil)
        let r4 = p.removeSmartBin(b.id); #expect(!r4)
    }

    @Test func projectWithoutSmartBinsWritesNoKey() throws {
        let data = try JSONEncoder().encode(Project(name: "P"))
        #expect(!String(decoding: data, as: UTF8.self).contains("smartBins"))
    }

    @Test func usedFractionMergesRanges() {
        let m = media("a")
        func clip(_ s: Int64, _ d: Int64) -> Clip {
            Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: Time(s, 1), duration: Time(d, 1)), start: .zero)
        }
        var p = Project(name: "P", media: [m])
        #expect(p.usedFraction(of: m.id) == 0)
        p.timelines = [Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip(0, 4), clip(2, 4), clip(8, 1)])])]
        #expect(p.usedFraction(of: m.id) == 0.7)
    }
}
