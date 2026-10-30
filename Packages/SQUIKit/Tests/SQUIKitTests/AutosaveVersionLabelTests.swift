import Foundation
import Testing
@testable import SQUIKit

@Suite struct AutosaveVersionLabelTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let en = Locale(identifier: "en_US")

    @Test func showsHowLongAgoAndMarksTheNewest() {
        let old = AutosaveVersionLabel.title(date: now.addingTimeInterval(-720), now: now, isNewest: false, locale: en)
        #expect(old.contains("12 min. ago"))
        #expect(!old.contains("Latest"))
        let newest = AutosaveVersionLabel.title(date: now.addingTimeInterval(-30), now: now, isNewest: true, locale: en)
        #expect(newest.hasSuffix("Latest"))
        #expect(newest.contains("30 sec. ago"))
    }

    @Test func differentVersionsGetDifferentTitles() {
        let a = AutosaveVersionLabel.title(date: now.addingTimeInterval(-300), now: now, isNewest: false, locale: en)
        let b = AutosaveVersionLabel.title(date: now.addingTimeInterval(-900), now: now, isNewest: false, locale: en)
        #expect(a != b)
    }
}
