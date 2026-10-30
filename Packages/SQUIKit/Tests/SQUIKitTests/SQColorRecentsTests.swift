import Foundation
import Testing
@testable import SQUIKit

@Suite struct SQColorRecentsTests {
    @Test func addsToFrontAndDedupes() {
        let l = SQColorRecents.adding("ff0000", to: ["00FF00", "FF0000", "0000FF"])
        #expect(l == ["FF0000", "00FF00", "0000FF"])
    }

    @Test func capsAtSix() {
        var l: [String] = []
        for h in ["111111", "222222", "333333", "444444", "555555", "666666", "777777"] { l = SQColorRecents.adding(h, to: l) }
        #expect(l.count == SQColorRecents.maxCount)
        #expect(l.first == "777777")
        #expect(!l.contains("111111"))
    }

    @Test func ignoresInvalidAndKeepsAlpha() {
        #expect(SQColorRecents.adding("zzz", to: ["FFFFFF"]) == ["FFFFFF"])
        #expect(SQColorRecents.normalized("#f00") == "FF0000")
        #expect(SQColorRecents.key(for: SQColorValue(r: 1, g: 0, b: 0, a: 0.5)) == "FF000080")
    }

    @Test func persistsInDefaults() throws {
        let d = try #require(UserDefaults(suiteName: "sq.test.color.recents"))
        d.removePersistentDomain(forName: "sq.test.color.recents")
        SQColorRecents.remember(SQColorValue(r: 1, g: 0, b: 0), in: d)
        SQColorRecents.remember(SQColorValue(r: 0, g: 0, b: 1), in: d)
        #expect(SQColorRecents.load(d) == ["0000FF", "FF0000"])
        #expect(d.stringArray(forKey: "sq.color.recents") == ["0000FF", "FF0000"])
        d.removePersistentDomain(forName: "sq.test.color.recents")
    }
}
