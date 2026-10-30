import Testing
@testable import SQCore

@Suite struct SupportersListTests {
    @Test func emptyAndOnlyCommentsGiveNoNames() {
        #expect(SupportersList.parse("").isEmpty)
        #expect(SupportersList.parse("# header\n\n   \n# more\n").isEmpty)
    }

    @Test func trimsWhitespaceAndKeepsOrder() {
        #expect(SupportersList.parse("  Zoe \n# skip\n\nAdam\r\n\tMia  \n") == ["Zoe", "Adam", "Mia"])
    }

    @Test func removesDuplicatesKeepingFirst() {
        #expect(SupportersList.parse("Ann\nBob\nann\nBob \nCy") == ["Ann", "Bob", "Cy"])
    }
}
