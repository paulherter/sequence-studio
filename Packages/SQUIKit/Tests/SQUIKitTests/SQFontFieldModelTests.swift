import Foundation
import Testing
@testable import SQUIKit

@Suite struct SQFontFieldModelTests {
    let fams = ["Interstate Condensed", "Inter Tight", "Inter", "Bebas Neue", "Playfair Display", "Helvetica", "Inter Display", "Avenir Next"]

    @Test func matchingRanksPrefixWordThenSubstring() {
        let m = SQFontFieldModel.matches(query: "inter", in: fams + ["Winter Sans"])
        #expect(m == ["Inter", "Inter Display", "Inter Tight", "Interstate Condensed", "Winter Sans"])
        #expect(SQFontFieldModel.matches(query: "NEXT", in: fams) == ["Avenir Next"])      // word prefix, case-insensitive
        #expect(SQFontFieldModel.matches(query: "  ", in: fams).isEmpty)
        #expect(SQFontFieldModel.matches(query: "zzz", in: fams).isEmpty)
        #expect(SQFontFieldModel.matches(query: "e", in: fams, limit: 2).count == 2)
    }

    @Test func rowsListMatchesRecentAndShowAll() {
        var m = SQFontFieldModel(families: fams, recents: ["Bebas Neue", "Inter"])
        // Empty query: only recents and the full-list entry.
        #expect(m.rows == [.header("Recent"),
                           .font(name: "Bebas Neue", title: "Bebas Neue", indented: false), .font(name: "Inter", title: "Inter", indented: false),
                           .separator, .showAll])
        #expect(m.highlight == nil)
        m.setQuery("inter")
        let r = m.rows
        #expect(r.first == .header("Matches"))
        #expect(r.contains(.header("Recent")))
        // "Inter" is already a match: not repeated under Recent.
        #expect(r.filter { $0 == .font(name: "Inter", title: "Inter", indented: false) }.count == 1)
        #expect(r.last == .showAll)
        #expect(m.highlightedRow == .font(name: "Inter", title: "Inter", indented: false))
    }

    @Test func includedFontsListedWhenNothingTyped() {
        var m = SQFontFieldModel(families: fams, recents: ["Anton"], bundled: ["Inter", "Anton", "Bangers"])
        #expect(m.rows == [.header("Recent"), .font(name: "Anton", title: "Anton", indented: false),
                           .separator, .header("Included"),
                           .font(name: "Inter", title: "Inter", indented: false), .font(name: "Bangers", title: "Bangers", indented: false),
                           .separator, .showAll])
        m.moveHighlight(by: 1)
        m.moveHighlight(by: 1)
        #expect(m.highlightedRow == .font(name: "Inter", title: "Inter", indented: false))   // arrows preview the bundled fonts
        m.setQuery("inter")
        #expect(!m.rows.contains(.header("Included")))                                       // typing narrows to matches
    }

    @Test func arrowsClampAndSkipHeaders() {
        var m = SQFontFieldModel(families: fams, recents: ["Bebas Neue"])
        m.setQuery("bebas")                       // Matches: Bebas Neue; Recent is the same font, so only showAll follows
        #expect(m.highlightedRow == .font(name: "Bebas Neue", title: "Bebas Neue", indented: false))
        m.moveHighlight(by: -1)
        #expect(m.highlightedRow == .font(name: "Bebas Neue", title: "Bebas Neue", indented: false))
        m.moveHighlight(by: 1)
        #expect(m.highlightedRow == .showAll)
        m.moveHighlight(by: 1)
        #expect(m.highlightedRow == .showAll)
        m.moveHighlight(by: -1)
        #expect(m.highlightedRow == .font(name: "Bebas Neue", title: "Bebas Neue", indented: false))
    }

    @Test func returnTarget() {
        var m = SQFontFieldModel(families: fams)
        m.setQuery("play")
        #expect(m.returnTarget == "Playfair Display")
        m.setQuery("helvetica")
        m.setHighlight(nil)
        #expect(m.returnTarget == "Helvetica")    // exact family name even without highlight
        m.setQuery("nothing")
        #expect(m.returnTarget == nil)
    }

    @Test func showAllListStartsAtCurrentFont() {
        var m = SQFontFieldModel(families: fams)
        let rows: [SQFontFieldModel.Row] = [.font(name: "A", title: "A", indented: false), .font(name: "A-Bold", title: "Bold", indented: true),
                                            .font(name: "B", title: "B", indented: false)]
        m.showAll(rows: rows, current: "A-Bold")
        #expect(m.rows == rows)
        #expect(m.highlight == 1)
        m.setQuery("x")                            // typing leaves the full list
        #expect(m.allRows == nil)
    }

    @Test func recentsDedupeCapAndPersist() throws {
        var l: [String] = []
        for n in ["A", "B", "C", "D", "E", "F", "B"] { l = SQFontFieldModel.addingRecent(n, to: l) }
        #expect(l == ["B", "F", "E", "D", "C"])
        let d = try #require(UserDefaults(suiteName: "sq.test.font.recents"))
        d.removePersistentDomain(forName: "sq.test.font.recents")
        SQFontFieldModel.remember("Inter", in: d)
        SQFontFieldModel.remember("Bebas Neue", in: d)
        #expect(SQFontFieldModel.loadRecents(d) == ["Bebas Neue", "Inter"])
        #expect(d.stringArray(forKey: "sq.font.recents") == ["Bebas Neue", "Inter"])
        d.removePersistentDomain(forName: "sq.test.font.recents")
    }
}
